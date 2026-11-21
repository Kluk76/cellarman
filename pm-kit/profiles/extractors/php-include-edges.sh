#!/usr/bin/env bash
# php-include-edges.sh - EXAMPLE extractor: PHP require/include edges (kind `include`)
# for kernel/graph.sh. Not kit core: a profile opts in by naming it in
# PF_EDGE_EXTRACTORS and giving it a PF_EDGE_CMD_<name> (see profiles/example.conf).
# It shows the extractor contract on a language with real indirection; copy and
# adapt it for another language's imports (the kit never reads this file).
#
# USAGE (as a PF_EDGE_CMD_<name> command, cwd = repo root)
#   bash "$GRAPH_KIT_DIR/profiles/extractors/php-include-edges.sh" [--files-re ERE]
#   --files-re ERE   which of the tracked input files to scan (grep -E against the
#                    path). Default: [.]php$. PF_EDGE_INPUTS (the scanned
#                    directories and globs) stays the single place that names
#                    WHERE to look; this only narrows it by extension.
#
# CONTRACT (kernel side): cwd = repo root; env GRAPH_FILES = file listing the
# tracked input files (one path per line), GRAPH_TRACKED = file listing EVERY
# tracked path. stdout = edges, five TAB-separated columns:
#   from  to  kind  provenance  path#line
# Diagnostics go to stderr. Exit 0 = the extraction ran; anything else makes the
# build fail loudly (the previous edge file is kept).
#
# WHAT IT HANDLES  require / require_once / include / include_once whose
# argument is, after comment stripping:
#   'lit.php'                      relative to the including file      EXTRACTED
#   __DIR__ . '/x.php'             and dirname(__DIR__[, n]) / dirname(__FILE__)
#                                  (nested dirname too), normalised     EXTRACTED
#   <var-or-const> . '/x.php'      suffix matched against tracked files:
#                                  exactly one match                    INFERRED
#   everything else, any target that is not a tracked file, a suffix that
#   matches 0 or several files, a statement never terminated            AMBIGUOUS
#   (to = the raw expression - never dropped).
# COMMENTS  `//`, `#` (not `#[`), `/* */` and HTML `<!-- -->` are stripped outside string
# literals. String interiors are masked, so a keyword inside a one-line string
# is not a hit. A hit whose argument does not look like an expression (prose in
# a heredoc or an HTML block) is skipped and COUNTED on stderr.
# KNOWN BLIND SPOTS  multi-line strings / heredocs are not tracked across
# lines (a `//` or an apostrophe inside one can mislead the scanner); `#` inside
# inline HTML cuts the rest of that line; `\include` (namespaced call) is not
# seen; autoloaders (spl_autoload_register, PSR-4) and include_path lookups are
# not edges at all; a string built by sprintf/implode/ternary is AMBIGUOUS.
set -u
: "${GRAPH_FILES:?GRAPH_FILES not set}"
: "${GRAPH_TRACKED:?GRAPH_TRACKED not set}"
FILES_RE='[.]php$'
while [ $# -gt 0 ]; do
  case "$1" in
    --files-re) [ $# -ge 2 ] && [ -n "$2" ] || { echo "php-include-edges: --files-re needs a value" >&2; exit 64; }; FILES_RE="$2"; shift 2 ;;
    *) echo "php-include-edges: unknown argument '$1'" >&2; exit 64 ;;
  esac
done
[ -s "$GRAPH_FILES" ] || exit 0
SCAN_LIST="$(mktemp "${TMPDIR:-/tmp}/php-include-edges.XXXXXX")" || exit 64
trap 'rm -f "$SCAN_LIST"' EXIT INT TERM
grep -E -- "$FILES_RE" "$GRAPH_FILES" > "$SCAN_LIST" || true
[ -s "$SCAN_LIST" ] || { echo "php-include-edges: 0 input file(s) match $FILES_RE" >&2; exit 0; }

tr '\n' '\0' < "$SCAN_LIST" | xargs -0 awk -v tracked="$GRAPH_TRACKED" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function dirnm(p,   i) { i = match(p, "/[^/]*$"); if (i) return substr(p, 1, i - 1); return "" }
# normalise a/b/../c ; returns "?" when it climbs above the repo root
function normpath(p,   n, a, i, k, out, o) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k == 0) return "?"; k--; continue }
    k++; o[k] = a[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") o[i]
  return out
}
function stripn(p, n,   i) { for (i = 0; i < n; i++) { if (p == "") return "?"; p = dirnm(p) } return p }
# split E on top-level "." (outside quotes and parens) into PART[1..NP]
function splitconcat(e,   i, n, ch, q, d, cur) {
  NP = 0; n = length(e); q = ""; d = 0; cur = ""
  for (i = 1; i <= n; i++) {
    ch = substr(e, i, 1)
    if (q != "") {
      cur = cur ch
      if (ch == "\\" && i < n) { i++; cur = cur substr(e, i, 1) }
      else if (ch == q) q = ""
      continue
    }
    if (ch == "\047" || ch == "\"") { q = ch; cur = cur ch; continue }
    if (ch == "(") d++
    if (ch == ")") d--
    if (ch == "." && d == 0) { NP++; PART[NP] = trim(cur); cur = ""; continue }
    cur = cur ch
  }
  NP++; PART[NP] = trim(cur)
}
# evaluate one concatenation part. Sets PT = L (literal) | D (path value) | U ; PV = value
function evalpart(p, f,   inner, k, depth, i, ch, a1, a2, nlev, save_t, save_v) {
  PT = "U"; PV = ""
  if (p ~ /^\047[^\047]*\047$/) { PT = "L"; PV = substr(p, 2, length(p) - 2); return }
  if (p ~ /^"[^"$]*"$/ && p !~ /[{]/) { PT = "L"; PV = substr(p, 2, length(p) - 2); return }
  if (p == "__DIR__") { PT = "D"; PV = dirnm(f); return }
  if (p == "__FILE__") { PT = "D"; PV = f; return }
  if (p ~ /^dirname[ \t]*\(/ && p ~ /\)$/) {
    inner = substr(p, index(p, "(") + 1); inner = substr(inner, 1, length(inner) - 1)
    # split inner on top-level comma
    depth = 0; k = 0
    for (i = 1; i <= length(inner); i++) {
      ch = substr(inner, i, 1)
      if (ch == "(") depth++
      else if (ch == ")") depth--
      else if (ch == "," && depth == 0) { k = i; break }
    }
    if (k) { a1 = trim(substr(inner, 1, k - 1)); a2 = trim(substr(inner, k + 1)) } else { a1 = trim(inner); a2 = "1" }
    if (a2 !~ /^[0-9]+$/) return
    nlev = a2 + 0
    evalpart(a1, f)
    if (PT != "D") { PT = "U"; return }
    if (PV == "?") return
    PV = stripn(PV, nlev); if (PV == "?") { PT = "U"; PV = "" }
    return
  }
}
function squash(s) { gsub(/[\t\r\n]+/, " ", s); gsub(/  +/, " ", s); return trim(s) }
function edge(to, prov, ln) { print SRC "\t" to "\tinclude\t" prov "\t" SRC "#" ln; NEDGE++ }
function istracked(p) { return (p in T) }
function suffix_count(s,   k, n, tail) {
  if (s in SC) return SC[s]
  n = 0; tail = "/" s
  for (k in T) { if (k == s || (length(k) > length(tail) && substr(k, length(k) - length(tail) + 1) == tail)) { n++; SFX[s] = k } }
  SC[s] = n; return n
}
function emit(e, ln,   raw, x, i, d, ch, n, t, j, prov, path, hasU, suffix, ok) {
  raw = squash(e)
  x = raw
  # peel one or more fully wrapping paren pairs
  while (x ~ /^\(.*\)$/) {
    d = 0; ok = 1; n = length(x)
    for (i = 1; i <= n; i++) {
      ch = substr(x, i, 1)
      if (ch == "(") d++
      else if (ch == ")") { d--; if (d == 0 && i < n) { ok = 0; break } }
    }
    if (!ok || d != 0) break
    x = trim(substr(x, 2, n - 2))
  }
  if (x !~ /^(\047|"|\$|__DIR__|__FILE__|dirname|[A-Z_][A-Z0-9_]*[ \t]*([.]|$)|\(|[A-Za-z_]+[ \t]*\()/) { NPROSE++; return }
  splitconcat(x)
  # classify the parts
  path = ""; prov = ""; hasU = 0
  for (j = 1; j <= NP; j++) { evalpart(PART[j], SRC); TY[j] = PT; VA[j] = PV }
  if (TY[1] == "D") {
    ok = (VA[1] != "?")
    for (j = 2; j <= NP; j++) if (TY[j] != "L") ok = 0
    if (ok) {
      t = VA[1]; for (j = 2; j <= NP; j++) t = t VA[j]
      path = normpath(t)
      if (path != "?" && path != "" && istracked(path)) { edge(path, "EXTRACTED", ln); return }
    }
    edge(raw, "AMBIGUOUS", ln); return
  }
  if (TY[1] == "L") {
    ok = 1
    for (j = 2; j <= NP; j++) if (TY[j] != "L") ok = 0
    if (ok) {
      t = VA[1]; for (j = 2; j <= NP; j++) t = t VA[j]
      if (t !~ /^\//) {
        path = normpath(dirnm(SRC) == "" ? t : dirnm(SRC) "/" t)
        if (path != "?" && path != "" && istracked(path)) { edge(path, "EXTRACTED", ln); return }
      }
    }
    edge(raw, "AMBIGUOUS", ln); return
  }
  # leading unknown part(s) then literals only -> INFERRED by suffix
  j = 1; while (j <= NP && TY[j] == "U") j++
  if (j > 1 && j <= NP) {
    ok = 1; suffix = ""
    for (i = j; i <= NP; i++) { if (TY[i] != "L") ok = 0; else suffix = suffix VA[i] }
    sub(/^\/+/, "", suffix)
    if (ok && suffix ~ /[^\/]\.[A-Za-z0-9]+$/ && suffix !~ /(^|\/)\.\.?(\/|$)/) {
      if (suffix_count(suffix) == 1) { edge(SFX[suffix], "INFERRED", ln); return }
    }
  }
  edge(raw, "AMBIGUOUS", ln)
}
# comment/string-aware scan of one line -> M (strings masked) and C (clean text), same length
function scan(s,   n, i, ch, nx, q, mo, co, e) {
  n = length(s); i = 1; q = ""; mo = ""; co = ""
  if (INBLOCK) {
    e = index(s, ENDTOK)
    if (!e) { M = ""; C = ""; return }
    INBLOCK = 0; i = e + length(ENDTOK); mo = " "; co = " "
  }
  while (i <= n) {
    ch = substr(s, i, 1)
    if (q != "") {
      if (ch == "\\" && i < n) { mo = mo "\001\001"; co = co substr(s, i, 2); i += 2; continue }
      if (ch == q) { q = ""; mo = mo ch } else mo = mo "\001"
      co = co ch; i++; continue
    }
    nx = substr(s, i + 1, 1)
    if (ch == "/" && nx == "/") break
    if (ch == "#" && nx != "[") break
    if (ch == "/" && nx == "*") {
      e = index(substr(s, i + 2), "*/")
      if (!e) { INBLOCK = 1; ENDTOK = "*/"; break }
      i = i + 2 + e + 1; mo = mo " "; co = co " "; continue
    }
    if (ch == "<" && substr(s, i, 4) == "<!--") {
      e = index(substr(s, i + 4), "-->")
      if (!e) { INBLOCK = 1; ENDTOK = "-->"; break }
      i = i + 4 + e + 2; mo = mo " "; co = co " "; continue
    }
    if (ch == "\047" || ch == "\"") q = ch
    mo = mo ch; co = co ch; i++
  }
  M = mo; C = co
}
# look for statements starting at position sp of bm/bc. Sets PEND when unterminated.
function handle(bm, bc, sp, ln, final,   rest, s, ostart, kws, kwl, es, k, ch, d, cut, kstart, n) {
  n = length(bm)
  while (sp <= n) {
    rest = substr(bm, sp)
    if (!match(rest, KWRE)) break
    ostart = RSTART
    s = substr(rest, RSTART, RLENGTH)
    match(s, /(require_once|include_once|require|include)/)
    kws = sp + ostart - 1 + RSTART - 1
    kwl = RLENGTH
    kstart = kws
    es = kws + kwl
    d = 0; cut = 0
    for (k = es; k <= n; k++) {
      ch = substr(bm, k, 1)
      if (ch == "(") d++
      else if (ch == ")") { if (d == 0) { cut = k; break } d-- }
      else if (ch == ";") { cut = k; break }
      else if (ch == "," && d == 0) { cut = k; break }
      else if (ch == "?" && substr(bm, k + 1, 1) == ">") { cut = k; break }
    }
    if (!cut) {
      if (final) { emit(substr(bc, es), ln); return }
      PEND = 1; PBM = substr(bm, kstart); PBC = substr(bc, kstart); PLN = ln; PCNT = 1
      return
    }
    emit(substr(bc, es, cut - es), ln)
    sp = cut + 1
  }
  PEND = 0
}
BEGIN {
  while ((getline l < tracked) > 0) T[l] = 1
  close(tracked)
  KWRE = "(^|[^A-Za-z0-9_$>:])(require_once|include_once|require|include)([^A-Za-z0-9_]|$)"
}
FNR == 1 {
  if (PEND) { handle(PBM, PBC, 1, PLN, 1); PEND = 0 }
  INBLOCK = 0; PEND = 0; SRC = FILENAME
}
{
  line = $0
  if (!INBLOCK && !PEND && line !~ /require|include|\/\*|<!--/) next
  scan(line)
  if (PEND) {
    PCNT++
    handle(PBM " " M, PBC " " C, 1, PLN, (PCNT >= 8))
    if (PEND && PCNT >= 8) PEND = 0
  } else if (M ~ /require|include/) {
    handle(M, C, 1, FNR, 0)
  }
}
END {
  if (PEND) handle(PBM, PBC, 1, PLN, 1)
  print "include-edges: " NEDGE + 0 " edges; " NPROSE + 0 " keyword hit(s) skipped as not shaped like an include expression (prose in heredoc/HTML)" > "/dev/stderr"
}
'
