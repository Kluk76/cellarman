#!/usr/bin/env bash
# sql-table-edges.sh - EXAMPLE extractor: source file -> database table edges for
# kernel/graph.sh. Not kit core: a profile opts in by naming it in
# PF_EDGE_EXTRACTORS and giving it a PF_EDGE_CMD_<name> (see profiles/example.conf).
#
# USAGE (as a PF_EDGE_CMD_<name> command, cwd = repo root)
#   bash "$GRAPH_KIT_DIR/profiles/extractors/sql-table-edges.sh" \
#        --tables <known-tables.txt> [--writers <writers.tsv>] [--files-re ERE]
#   --tables FILE    REQUIRED. Plain text, one table or view name per line (case is
#                    ignored; blank lines and `#` comments are skipped). Only a name
#                    in this list can become an edge: any other word after FROM /
#                    JOIN / UPDATE ... (a CTE name, a column, prose) is rejected and
#                    counted. How a project produces the list is the project's
#                    business, for example
#                      mysql -N -e 'SELECT table_name FROM information_schema.tables
#                        WHERE table_schema = DATABASE()' > db/known-tables.txt
#                    or a psql / sqlite3 equivalent, or a grep over its migrations.
#                    Commit it, so every clone sees the same list.
#   --writers FILE   OPTIONAL. TAB-separated `table<TAB>writer`, one row per table.
#                    The writer column is free text; every file-like token in it
#                    (name.ext, with / and * allowed) is a declared writer of that
#                    table. Rows whose writer holds no token are ignored.
#   --files-re ERE   which of the tracked input files to scan (grep -E against the
#                    path). Default: [.](php|py|js|ts|mjs)$ ; *.min.js and
#                    node_modules/ are always skipped. PF_EDGE_INPUTS names WHERE
#                    to look; this only narrows it.
# Fails loudly (exit 3, message on stderr, no edge on stdout) when --tables is
# missing, unreadable or lists no name, when --writers names an absent file, or
# when the scan itself fails: an extractor that accepted every name, or silently
# produced zero edges, would be an invention.
#
# CONTRACT (kernel side): cwd = repo root; env GRAPH_FILES = file listing the
# tracked input files, GRAPH_TRACKED = file listing every tracked path. stdout =
# edges, five TAB-separated columns  from  to  kind  provenance  path#line .
# Diagnostics go to stderr. Exit 0 = the extraction ran; anything else makes the
# build fail loudly (the previous edge file is kept).
#
# KINDS
#   sql-read         file -> table  named after FROM or JOIN
#   sql-write        file -> table  named after INSERT [IGNORE] INTO, REPLACE INTO,
#                                   UPDATE, DELETE FROM, TRUNCATE [TABLE]
#                                   (`ON DUPLICATE KEY UPDATE` is not an UPDATE; neither
#                                   are `FOR UPDATE` / `ON UPDATE`)
#   declared-writer  writer file -> table, from the --writers file (EXTRACTED when
#                    the token is an exact tracked path, INFERRED when it is
#                    resolved by suffix / basename / `*` glob, AMBIGUOUS - from = the
#                    token as written - when it matches no tracked file or more
#                    than 10)
# One edge per (file, table, kind); the source line is the FIRST occurrence; the
# provenance is EXTRACTED if any occurrence was.
#
# PROVENANCE
#   EXTRACTED  literal identifier right after the keyword, on a non-comment line
#   INFERRED   the keyword ends a line and the name opens the next one, or
#              `'... FROM ' . 'name'` (two literals concatenated)
#   AMBIGUOUS  the table position is `$var`, `{$x}`, `${x}`, `{x}`, `%s`, `name{$x}`,
#              `' . $expr` : to = the raw expression (e.g. `FROM $table`), never
#              dropped
# ALIASES  `FROM items i` -> items; `FROM a x, b y` -> a and b (single-line
# comma lists); `DELETE a FROM a JOIN b` -> a written, b read; `UPDATE a JOIN b
# SET` -> a written, b read; `schema.table` -> table; `information_schema|mysql|
# performance_schema|sys.*` ignored; backticks stripped.
# COMMENTS  `//` (not in .py), `#` (php: not `#[`; py), `-- `, `/* */` and `<!-- -->`
# are stripped outside string literals; quote state is per line (multi-line
# strings / heredocs are not tracked across lines). `from x import y` lines of a
# .py file are skipped.
# WHAT IT CANNOT SEE  SQL assembled by helper functions or query builders; table
# names held in constants, arrays or config (`FROM self::T`, `FROM ' . TABLE` is
# AMBIGUOUS only when the expression is on the same or the next line); stored
# procedures and triggers; the views' own dependencies (a view body is SQL in a
# migration, not in these files); SQL in .sql, .sh, .html; a statement whose
# keyword and name are more than 6 non-blank lines apart.
set -u
: "${GRAPH_FILES:?GRAPH_FILES not set}"
: "${GRAPH_TRACKED:?GRAPH_TRACKED not set}"
fail() { echo "sql-table-edges: FAILED - $1" >&2; exit "${2:-3}"; }

TABLES=""; WRITERS=""; FILES_RE='[.](php|py|js|ts|mjs)$'
while [ $# -gt 0 ]; do
  case "$1" in
    --tables)   [ $# -ge 2 ] && [ -n "$2" ] || fail "--tables needs a file" 64; TABLES="$2"; shift 2 ;;
    --writers)  [ $# -ge 2 ] && [ -n "$2" ] || fail "--writers needs a file" 64; WRITERS="$2"; shift 2 ;;
    --files-re) [ $# -ge 2 ] && [ -n "$2" ] || fail "--files-re needs a value" 64; FILES_RE="$2"; shift 2 ;;
    *) fail "unknown argument '$1'" 64 ;;
  esac
done
[ -n "$TABLES" ] || fail "no --tables <file> given: the list of known table and view names is required (an extractor that accepted every name would be an invention; refusing to produce zero edges)"
[ -f "$TABLES" ] || fail "known-tables list $TABLES not found (refusing to produce zero edges)"
[ -z "$WRITERS" ] || [ -f "$WRITERS" ] || fail "writers file $WRITERS not found"
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sqledges.XXXXXX")" || exit 64
trap 'rm -rf "$TMPD"' EXIT INT TERM

# -- 1. the known names, ONCE: lower-cased, comments and blanks removed
sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$TABLES" | tr '[:upper:]' '[:lower:]' | grep -v '^$' | sort -u > "$TMPD/names.txt"
NSNAP=$(wc -l < "$TMPD/names.txt" | tr -d ' ')
[ "$NSNAP" -gt 0 ] || fail "$TABLES lists 0 tables (wrong file or format?); refusing to produce zero edges"
# the writers file as table <TAB> line <TAB> writer
: > "$TMPD/snap.tsv"
if [ -n "$WRITERS" ]; then
  awk -F'\t' 'NF >= 2 && $1 !~ /^[[:space:]]*#/ && $1 != "" { w = $2; gsub(/[\r]/, "", w); printf "%s\t%d\t%s\n", tolower($1), NR, w }' "$WRITERS" > "$TMPD/snap.tsv"
fi

# -- 2. the input files
grep -E -- "$FILES_RE" "$GRAPH_FILES" 2>/dev/null \
  | grep -vE '[.]min[.]js$|(^|/)node_modules/' > "$TMPD/files.txt"
NFILES=$(wc -l < "$TMPD/files.txt" | tr -d ' ')
: > "$TMPD/stats.tsv"

# -- 3. the SQL scan: one awk program, fed the whole file list
cat > "$TMPD/scan.awk" <<'AWKEOF'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function squash(s) { gsub(/[\t\r\n]+/, " ", s); gsub(/  +/, " ", s); return trim(s) }

function addedge(kind, to, prov, ln,   k) {
  k = kind SUBSEP to
  if (!(k in EL)) { EL[k] = ln; EP[k] = prov; EN++; EO[EN] = k }
  else if (prov == "EXTRACTED" && EP[k] != "EXTRACTED") EP[k] = prov
}
function flush(   i, a, k) {
  for (i = 1; i <= EN; i++) {
    k = EO[i]; split(k, a, SUBSEP)
    print PF "\t" a[2] "\t" a[1] "\t" EP[k] "\t" PF "#" EL[k]
    NK[a[1]]++; NPV[EP[k]]++
  }
  split("", EL); split("", EP); split("", EO); EN = 0; split("", RSEEN)
}
function reject(nm) {
  if (!(nm in RSEEN)) { RSEEN[nm] = 1; RC[nm]++; NREJ++ }
}
function emit_named(cls, nm, ln, inf) {
  if (nm in S) addedge((cls == "W") ? "sql-write" : "sql-read", nm, inf ? "INFERRED" : "EXTRACTED", ln)
  else reject(nm)
}
function amb(cls, kw, chunk, ln) {
  addedge((cls == "W") ? "sql-write" : "sql-read", squash(toupper(kw) " " chunk), "AMBIGUOUS", ln)
}

# take(cls, kw, s, ln, inf): parse the table position at the start of s.
# Returns the number of characters of s consumed (>= 0), or -1 when s holds nothing
# yet (the name is on a later line).
function take(cls, kw, s, ln, inf,    p, t, c1, tail, chunk, ml, len, id, id2, sch, after, alias, a, la, nm, kcls, rest, used, it, m2) {
  match(s, /^[ \t]*/); p = RLENGTH
  t = substr(s, p + 1)
  if (t == "") return -1
  c1 = substr(t, 1, 1)
  if (c1 == "'" || c1 == "\"") {
    if (match(t, /^['"][ \t]*[.][ \t]*['"]/)) {
      ml = RLENGTH; p += ml; t = substr(t, ml + 1)
      match(t, /^[ \t]*/); p += RLENGTH; t = substr(t, RLENGTH + 1)
      inf = 1; c1 = substr(t, 1, 1)
      if (t == "") return -1
    } else if (match(t, /^['"][ \t]*[.][ \t]*/)) {
      ml = RLENGTH; tail = substr(t, ml + 1)
      if (tail == "") return -1
      if (match(tail, /^[^ \t,;)'"]+/)) {
        chunk = substr(tail, 1, RLENGTH)
        amb(cls, kw, "' . " chunk, ln)
        return p + ml + RLENGTH
      }
      return 0
    } else return 0
  }
  if (c1 == "$" || c1 == "{") {
    if (match(t, /^([$][A-Za-z_{]|[{][$A-Za-z_])[^ \t,;)'"]*/)) {
      chunk = substr(t, 1, RLENGTH); amb(cls, kw, chunk, ln); return p + RLENGTH
    }
    return 0
  }
  if (c1 == "%") {
    if (match(t, /^%[sd]/)) { amb(cls, kw, "%s", ln); return p + 2 }
    return 0
  }
  if (!match(t, /^`?[A-Za-z_][A-Za-z0-9_]*`?/)) return 0
  len = RLENGTH; id = substr(t, 1, len); gsub(/`/, "", id); after = substr(t, len + 1)
  if (match(after, /^[.]`?[A-Za-z_][A-Za-z0-9_]*`?/)) {
    sch = tolower(id); id2 = substr(after, 2, RLENGTH - 1); gsub(/`/, "", id2)
    len += RLENGTH; after = substr(after, RLENGTH + 1)
    if (sch ~ /^(information_schema|performance_schema|mysql|sys)$/) return p + len
    id = id2
  }
  if (after ~ /^[{$]/) {
    match(after, /^[^ \t,;)'"]*/)
    amb(cls, kw, id substr(after, 1, RLENGTH), ln); return p + len + RLENGTH
  }
  if (cls == "R" && after ~ /^[(]/) return p + len      # a table function, not a table
  nm = tolower(id); used = p + len; rest = after
  if (kw != "from") { emit_named(cls, nm, ln, inf); return used }
  # FROM: alias, optional comma list, DELETE a FROM a JOIN b
  for (it = 0; it < 8; it++) {
    alias = ""
    if (match(rest, /^[ \t]+([Aa][Ss][ \t]+)?`?[A-Za-z_][A-Za-z0-9_]*`?/)) {
      a = substr(rest, 1, RLENGTH); m2 = RLENGTH
      sub(/^[ \t]+([Aa][Ss][ \t]+)?/, "", a); gsub(/`/, "", a); la = tolower(a)
      if (index(RESV, "|" la "|") == 0) { alias = la; rest = substr(rest, m2 + 1); used += m2 }
    }
    kcls = cls
    if (DM != "") {
      if (index(DM, "|" nm "|") > 0 || (alias != "" && index(DM, "|" alias "|") > 0)) kcls = "W"
      DM = ""
    }
    emit_named(kcls, nm, ln, inf)
    if (!match(rest, /^[ \t]*,[ \t]*`?[A-Za-z_][A-Za-z0-9_]*`?/)) break
    a = substr(rest, 1, RLENGTH); m2 = RLENGTH
    sub(/^[ \t]*,[ \t]*/, "", a); gsub(/`/, "", a); nm = tolower(a)
    rest = substr(rest, m2 + 1); used += m2
    if (rest ~ /^[.(]/) break
  }
  return used
}

# comment-aware scan of one line -> the line without comments (strings kept: the SQL lives in them)
function scan(s,   n, i, ch, nx, q, co, e) {
  n = length(s); i = 1; q = ""; co = ""
  if (INBLOCK) {
    e = index(s, ENDTOK)
    if (!e) return ""
    INBLOCK = 0; i = e + length(ENDTOK); co = " "
  }
  while (i <= n) {
    ch = substr(s, i, 1)
    if (q != "") {
      if (ch == "\\" && i < n) { co = co substr(s, i, 2); i += 2; continue }
      if (ch == q) q = ""
      co = co ch; i++; continue
    }
    nx = substr(s, i + 1, 1)
    if (ch == "/" && nx == "/" && !ISPY) break
    if (ch == "#" && ((ISPHP && nx != "[") || ISPY)) break
    if (ch == "-" && nx == "-" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/) && (i + 2 > n || substr(s, i + 2, 1) ~ /[ \t]/)) break
    if (ch == "/" && nx == "*") {
      e = index(substr(s, i + 2), "*/")
      if (!e) { INBLOCK = 1; ENDTOK = "*/"; break }
      i = i + 2 + e + 1; co = co " "; continue
    }
    if (ch == "<" && substr(s, i, 4) == "<!--") {
      e = index(substr(s, i + 4), "-->")
      if (!e) { INBLOCK = 1; ENDTOK = "-->"; break }
      i = i + 4 + e + 2; co = co " "; continue
    }
    if (ch == "'" || ch == "\"") q = ch
    co = co ch; i++
  }
  return co
}

function process(C, ln,   L, pos, rest, seg, ks, kl, kwabs, kwtxt, kwend, cls, kw, pre, k, n, rem, tk, hasc, base) {
  if (DM != "" && ln - DMLN > 8) DM = ""
  L = tolower(C); pos = 1
  if (PEND) {
    if (L ~ /^[ \t]*$/) { if (++PEMPTY > 6) PEND = 0; return }
    PEND = 0
    k = 0
    if (match(C, /^[ \t'".]+/)) k = RLENGTH
    n = take(PCLS, PKW, substr(C, k + 1), PLN, 1)
    if (n < 0) { PEND = 1; PEMPTY++; if (PEMPTY > 6) PEND = 0; return }
    pos = k + n + 1
  }
  while (pos <= length(L)) {
    rest = substr(L, pos)
    if (!match(rest, KWRE)) break
    seg = substr(rest, RSTART, RLENGTH); base = pos - 1 + RSTART - 1
    match(seg, KW2); ks = RSTART; kl = RLENGTH
    kwabs = base + ks; kwtxt = substr(L, kwabs, kl); kwend = kwabs + kl - 1
    gsub(/[ \t]+/, " ", kwtxt)
    pos = kwend + 1
    if (kwtxt == "delete") {
      rem = substr(C, kwend + 1); DM = ""
      while (match(rem, /^[ \t]*`?[A-Za-z_][A-Za-z0-9_]*`?[ \t]*,?/)) {
        tk = substr(rem, 1, RLENGTH); rem = substr(rem, RLENGTH + 1)
        hasc = (tk ~ /,[ \t]*$/); gsub(/[ \t`,]/, "", tk); tk = tolower(tk)
        if (tk == "from") break
        DM = DM "|" tk; DMLN = ln
        if (!hasc) break
      }
      if (DM != "") DM = DM "|"
      continue
    }
    if (kwtxt == "from" || kwtxt == "join") { cls = "R"; kw = kwtxt }
    else {
      cls = "W"; kw = kwtxt; DM = ""
      if (kwtxt == "update") {
        pre = PREV " " substr(L, 1, kwabs - 1)
        if (pre ~ /(key|for|on)[ \t]*$/) continue
      }
    }
    n = take(cls, kw, substr(C, kwend + 1), ln, 0)
    if (n < 0) { PEND = 1; PCLS = cls; PKW = kw; PLN = ln; PEMPTY = 0; break }
    pos = kwend + 1 + n
  }
}

BEGIN {
  while ((getline l < names) > 0) S[l] = 1
  close(names)
  KWRE = "(^|[^a-z0-9_$>:.])(insert[ \t]+(ignore[ \t]+)?into|replace[ \t]+into|delete[ \t]+from|delete|truncate([ \t]+table)?|update|from|join)([ \t`]|$)"
  KW2 = "(insert[ \t]+(ignore[ \t]+)?into|replace[ \t]+into|delete[ \t]+from|delete|truncate([ \t]+table)?|update|from|join)"
  PRE = "insert|replace|update|delete|truncate|from|join|/[*]|<!--"
  RESV = "|where|join|left|right|inner|outer|cross|natural|on|using|group|order|limit|having|union|set|values|select|for|lock|straight_join|partition|use|force|ignore|window|into|from|as|and|or|not|if|then|else|end|"
}
FNR == 1 {
  if (PF != "") flush()
  PF = FILENAME
  INBLOCK = 0; PEND = 0; DM = ""; PREV = ""
  ISPHP = (FILENAME ~ /[.]php$/); ISPY = (FILENAME ~ /[.]py$/)
}
{
  line = $0
  if (!INBLOCK && !PEND && tolower(line) !~ PRE) {
    PREV = substr(tolower(line), length(line) - 30)
    next
  }
  C = scan(line)
  if (ISPY && C ~ /^[ \t]*from[ \t]+[A-Za-z0-9_.]+[ \t]+import/) C = ""
  process(C, FNR)
  PREV = substr(tolower(C), length(C) - 30)
}
END {
  if (PF != "") flush()
  for (k in NK) print "#kind\t" k "\t" NK[k] >> rej
  for (k in NPV) print "#prov\t" k "\t" NPV[k] >> rej
  for (k in RC) print k "\t" RC[k] >> rej
  close(rej)
}
AWKEOF

: > "$TMPD/rej.tsv"
if [ -s "$TMPD/files.txt" ]; then
  tr '\n' '\0' < "$TMPD/files.txt" | xargs -0 awk -v names="$TMPD/names.txt" -v rej="$TMPD/rej.tsv" -f "$TMPD/scan.awk" \
    || fail "the SQL scan (awk) failed" 3
fi

# -- 4. declared writers (writers file -> table)
cat > "$TMPD/decl.awk" <<'AWKEOF'
function globre(tok,   i, ch, r) {
  r = ""
  for (i = 1; i <= length(tok); i++) {
    ch = substr(tok, i, 1)
    if (ch == "*") r = r ".*"
    else if (ch ~ /[A-Za-z0-9_\/-]/) r = r ch
    else r = r "[" ch "]"
  }
  return r
}
function declare(tbl, tok, ln,   n, i, re1, re2, m, hit1) {
  if (tok in T) { print tok "\t" tbl "\tdeclared-writer\tEXTRACTED\t" snaprel "#" ln; NEXACT++; return }
  re1 = "^" globre(tok) "$"; re2 = "/" globre(tok) "$"
  m = 0
  for (i = 1; i <= NT; i++) {
    if (TL[i] ~ re1 || TL[i] ~ re2) { m++; if (m <= 11) hit[m] = TL[i] }
  }
  if (m >= 1 && m <= 10) { for (i = 1; i <= m; i++) print hit[i] "\t" tbl "\tdeclared-writer\tINFERRED\t" snaprel "#" ln; NINF++; return }
  print tok "\t" tbl "\tdeclared-writer\tAMBIGUOUS\t" snaprel "#" ln
  if (m == 0) NUNRES++; else NMANY++
}
BEGIN {
  FS = "\t"
  while ((getline l < tracked) > 0) { T[l] = 1; TL[++NT] = l }
  close(tracked)
  while ((getline l < names) > 0) K[l] = 1
  close(names)
  TOKRE = "[A-Za-z0-9_./*-]+[.](php|py|ts|js|mjs|sh)"
}
{
  tbl = $1; ln = $2; w = $3
  if (w == "") next
  s = w; nt = 0
  if (!(tbl in K)) NUNK++
  while (match(s, TOKRE)) {
    tok = substr(s, RSTART, RLENGTH)
    nxt = substr(s, RSTART + RLENGTH, 1)
    s = substr(s, RSTART + RLENGTH)
    if (nxt ~ /[A-Za-z0-9_]/) continue
    declare(tbl, tok, ln); nt++
  }
  if (nt == 0) NOTOK++
}
END {
  print "#decl\texact\t" NEXACT + 0 >> st
  print "#decl\tsuffix-or-glob\t" NINF + 0 >> st
  print "#decl\tunresolved-token\t" NUNRES + 0 >> st
  print "#decl\tmany-matches\t" NMANY + 0 >> st
  print "#decl\trow-without-file-token\t" NOTOK + 0 >> st
  print "#decl\ttable-not-in-known-list\t" NUNK + 0 >> st
}
AWKEOF
if [ -n "$WRITERS" ]; then
  awk -v tracked="$GRAPH_TRACKED" -v snaprel="$WRITERS" -v names="$TMPD/names.txt" -v st="$TMPD/stats.tsv" -f "$TMPD/decl.awk" "$TMPD/snap.tsv" \
    || fail "the declared-writer pass (awk) failed" 3
fi

# -- 5. summary on stderr
awk -F'\t' -v nfiles="$NFILES" -v nsnap="$NSNAP" '
  $1 == "#kind" { k[$2] += $3; next }
  $1 == "#prov" { p[$2] += $3; next }
  /^#/ { next }
  { c[$1] += $2; tot += $2; nd++ }
  END {
    printf "sql-table-edges: %d file(s) scanned, %d known table(s)/view(s)\n", nfiles, nsnap > "/dev/stderr"
    printf "sql-table-edges: scanned-file edges  sql-read %d, sql-write %d (EXTRACTED %d, INFERRED %d, AMBIGUOUS %d)\n", k["sql-read"], k["sql-write"], p["EXTRACTED"], p["INFERRED"], p["AMBIGUOUS"] > "/dev/stderr"
    printf "sql-table-edges: %d candidate name(s) REJECTED (not in the known list; %d distinct), top 15 by number of files:\n", tot, nd > "/dev/stderr"
    for (n in c) printf "%d\t%s\n", c[n], n
  }' "$TMPD/rej.tsv" > "$TMPD/rej.summary" 2> "$TMPD/rej.head"
cat "$TMPD/rej.head" >&2
sort -t "$(printf '\t')" -k1,1nr -k2,2 "$TMPD/rej.summary" | head -n 15 | sed 's/^/  /' >&2
awk -F'\t' '$1 == "#decl" { printf "sql-table-edges: declared-writer %s: %s\n", $2, $3 > "/dev/stderr" }' "$TMPD/stats.tsv"
exit 0
