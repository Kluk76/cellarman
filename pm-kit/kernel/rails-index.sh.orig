#!/usr/bin/env bash
# rails-index.sh — mines the PM's always-read index for rails whose violation
# surface can be NAMED (a table, a file, a column, a symbol) and keys them by
# that name in a TSV a pre-flight can grep. Portable kernel: carries no
# project nouns — see profiles/*.conf for those, and the profile-discovery
# block below (copied verbatim from pm-preflight.sh so the two tools resolve
# the SAME profile, deterministically, from the same cwd).
#
# WHY THIS EXISTS
#   The PM's always-read index recalls a rail ASSOCIATIVELY: it re-reads ~34 Kb
#   of arc prose hoping to recognise that a rail applies to whatever a build is
#   about to touch. That is fragile, and it is what saturates the index. This
#   tool replaces recall-by-association with recall-by-ADDRESS: a rail keyed
#   on the artefact it protects is found because the build touched that
#   artefact, not because someone read far enough to remember it.
#
# WHAT IT DOES (two phases)
#   1. EXTRACTION — reads the PM index's arc bullet lines (lines starting
#      "- "), splits each on its severity markers (one arc line usually names
#      SEVERAL distinct rails), and for each resulting fragment records every
#      backtick-quoted artefact it names: a table, a table.column, a file, or
#      a function().
#   2. EXPANSION — a rail posed on a TABLE must also fire for every VIEW that
#      reads it, directly or transitively (a view-of-a-view is still in
#      scope). This is the condition that makes the tool worth shipping: miss
#      it and a fast recall becomes a MISSED recall. The dependency graph is a
#      profile-owned, cached SSH probe (kernel does not know MySQL or
#      information_schema) — --refresh-graph regenerates it; without a cache
#      AND without --refresh-graph, expansion is visibly UNMEASURED, never a
#      silent green.
#
# OUTPUT
#   PF_RAILS_OUTPUT (state/RAILS-BY-ARTEFACT.tsv), 5 tab-separated columns:
#     artefact <TAB> severite <TAB> rail (<=~300c) <TAB> source (file#line) <TAB> origine (direct|via:<parent>)
#   Generated + gitignored — every clone rebuilds it; never a merge surface.
#
# EXIT CODES
#   0  generated, expansion measured (cache used or freshly refreshed)
#   1  generated, but expansion UNMEASURED (no cache, --refresh-graph not
#      given, or the refresh probe failed) — direct rails are still correct,
#      transitive (via:) rows are simply absent; said loudly, not silently
#   2  STOP — could not generate at all (no profile, no PM index, bad state)
#
# USAGE
#   rails-index.sh                    # (re)generate from the cached graph, or
#                                      # UNMEASURED-expansion if no cache exists
#   rails-index.sh --refresh-graph    # + re-pull the view-dependency graph first
#   rails-index.sh --conf <path>      # explicit profile (see discovery below)
#
# DESIGN CONSTRAINTS (same as pm-preflight.sh, see its header)
#   - bash 3.2 (macOS) as well as bash 5 (Linux). No associative arrays, no
#     mapfile, no ${x,,}, no grep -P. (awk's arrays ARE fine — that limitation
#     is bash's, not awk's, and the closure/BFS step below leans on awk for
#     exactly this reason.)
#   - MUST NOT write outside $TMPDIR and the declared output/cache paths.
#   - MUST distinguish "measured and clean" from "could not measure" — see the
#     UNMEASURED banner in the expansion phase.
set -u

# ── locate (verbatim copy of pm-preflight.sh's discovery block — the two
#    tools MUST resolve the same repo root and the same profile from the same
#    cwd, or a rail extracted under one profile could be graded under another) ──
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=""

if [ -n "${PM_REPO_ROOT:-}" ]; then
  REPO_ROOT="$PM_REPO_ROOT"
elif REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO_ROOT" ]; then
  :
else
  REPO_ROOT="$(cd "$KIT_DIR/../../.." && pwd)"
  echo "rails-index: WARNING no \$PM_REPO_ROOT and cwd is not inside a git repo — falling back to the kernel's grandparent-of-grandparent ($REPO_ROOT). This is only correct if the kernel still lives at <repo>/claude-brain/pm-kit/kernel/." >&2
fi

REFRESH_GRAPH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --conf)           CONF="$2"; shift 2 ;;
    --refresh-graph)  REFRESH_GRAPH=1; shift ;;
    -h|--help)        sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "rails-index: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

# ── profile discovery (identical order to pm-preflight.sh) ─────────────────
if [ -z "$CONF" ] && [ -n "${PM_PROFILE:-}" ]; then
  if [ -f "$PM_PROFILE" ]; then
    CONF="$PM_PROFILE"
  elif [ -f "$REPO_ROOT/claude-brain/pm-kit/profiles/$PM_PROFILE.conf" ]; then
    CONF="$REPO_ROOT/claude-brain/pm-kit/profiles/$PM_PROFILE.conf"
  fi
fi
if [ -z "$CONF" ] && [ -d "$REPO_ROOT/claude-brain/pm-kit/profiles" ]; then
  N=$(find "$REPO_ROOT/claude-brain/pm-kit/profiles" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && CONF=$(find "$REPO_ROOT/claude-brain/pm-kit/profiles" -maxdepth 1 -name '*.conf')
fi
if [ -z "$CONF" ]; then
  N=$(find "$KIT_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && CONF=$(find "$KIT_DIR" -maxdepth 1 -name '*.conf')
fi

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "rails-index: STOP — no profile found (--conf, \$PM_PROFILE, a single claude-brain/pm-kit/profiles/*.conf, or a single kernel/*.conf). This kernel carries no project nouns of its own and cannot run without one." >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$CONF"

: "${PM_INDEX_REL:=${PF_PM_INDEX:-}}"
: "${EXTRA_CORPUS:=${PF_RAILS_EXTRA_CORPUS:-}}"
: "${TABLE_RE:=${PF_ARTEFACT_TABLE_RE:-}}"
# File-extension classifier. UNLIKE TABLE_RE this carries a DEFAULT — the list
# below is exactly what was hardcoded in classify() until 2026-08-10, so a
# profile that says nothing keeps its previous output to the byte. A project
# whose artefacts include other families (here: `*.cron`) widens it in ITS
# profile; the portable kernel stays free of house conventions.
# ⚠️ Anchored with $ and matched against the whole candidate — keep it that way,
# an unanchored variant would classify `foo.php.bak` as a file.
# 🔴 `[.]`, PAS `\.` — cette valeur transite par `awk -v`, qui interprète les
# séquences d'échappement de son argument : `\.` n'est pas un échappement awk
# défini et se ferait manger en `.` (= n'importe quel caractère) selon
# l'implémentation. `[.]` est strictement équivalent et immunisé.
: "${FILE_RE:=${PF_ARTEFACT_FILE_RE:-[.](php|js|sh|css|sql|ts|py|md|json|yml|yaml)$}}"
: "${SEVERITY_MARKERS:=${PF_SEVERITY_MARKERS:-}}"
: "${TRUNC:=${PF_RAILS_TRUNCATE:-300}}"
: "${OUTPUT_REL:=${PF_RAILS_OUTPUT:-}}"
: "${GRAPH_CACHE_REL:=${PF_ARTEFACT_GRAPH_CACHE:-}}"
: "${EXPAND_CMD:=${PF_ARTEFACT_EXPAND:-}}"
: "${MAX_ITER:=${PF_ARTEFACT_EXPAND_MAX_ITER:-25}}"

if [ -z "$PM_INDEX_REL" ]; then
  echo "rails-index: STOP — profile '$CONF' does not define PF_PM_INDEX — nothing names the corpus to mine." >&2
  exit 2
fi
if [ -z "$TABLE_RE" ]; then
  echo "rails-index: STOP — profile '$CONF' does not define PF_ARTEFACT_TABLE_RE." >&2
  exit 2
fi
if [ -z "$SEVERITY_MARKERS" ]; then
  echo "rails-index: STOP — profile '$CONF' does not define PF_SEVERITY_MARKERS." >&2
  exit 2
fi
if [ -z "$OUTPUT_REL" ]; then
  echo "rails-index: STOP — profile '$CONF' does not define PF_RAILS_OUTPUT." >&2
  exit 2
fi

cd "$REPO_ROOT" || { echo "rails-index: cannot cd $REPO_ROOT" >&2; exit 64; }

PM_INDEX="$REPO_ROOT/$PM_INDEX_REL"
OUTPUT="$REPO_ROOT/$OUTPUT_REL"
GRAPH_CACHE="$REPO_ROOT/$GRAPH_CACHE_REL"

if [ ! -f "$PM_INDEX" ]; then
  echo "rails-index: STOP — PF_PM_INDEX names '$PM_INDEX_REL', which does not exist at $PM_INDEX." >&2
  exit 2
fi

TMP="${TMPDIR:-/tmp}/rails-index.$$"
mkdir -p "$TMP" || exit 64
trap 'rm -rf "$TMP"' EXIT INT TERM

# ── corpus list: the index, THEN every file PF_RAILS_EXTRA_CORPUS declares ───
#    WHY THIS EXISTS (measured 2026-08-10). The miner read the index and ONLY
#    the index, while the index itself routes by domain into register files
#    that carry the bulk of the rails. On this profile that left 105 KB of
#    rails unreachable BY ARTEFACT — and the failure mode is the worst one
#    available: a grep of the TSV that finds nothing is indistinguishable from
#    a true zero, so the tool built to enforce rails returned a PERMANENT
#    GREEN for every artefact documented only in a register. Caught live: a
#    consult grepped `customers`, got zero rows, and the rail on that exact
#    column was sitting in the register the whole time. It was surfaced only
#    because the index happened to carry a duplicate — luck, not routing.
#    A declared corpus that resolves to NOTHING is a STOP, never a skip: the
#    entire point is that silence must not read as coverage.
CORPUS_LIST="$TMP/corpora.txt"
: > "$CORPUS_LIST"
printf '%s\n' "$PM_INDEX_REL" >> "$CORPUS_LIST"

if [ -n "$EXTRA_CORPUS" ]; then
  printf '%s\n' "$EXTRA_CORPUS" | while IFS= read -r CL; do
    # strip comments + surrounding blanks; blank lines are documentary
    CL="${CL%%#*}"
    CL=$(printf '%s' "$CL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$CL" ] && continue
    # glob expansion is deliberate (a profile may name a directory of
    # registers); set -- keeps bash 3.2 happy, no arrays.
    MATCHED=0
    for P in $CL; do
      if [ -f "$REPO_ROOT/$P" ]; then
        printf '%s\n' "$P" >> "$CORPUS_LIST"
        MATCHED=1
      fi
    done
    if [ "$MATCHED" = 0 ]; then
      printf 'rails-index: STOP — PF_RAILS_EXTRA_CORPUS names "%s", which matches no file under %s. A declared corpus that cannot be read must not silently shrink the index.\n' \
        "$CL" "$REPO_ROOT" >> "$TMP/corpus.err"
    fi
  done
fi

if [ -s "$TMP/corpus.err" ]; then
  cat "$TMP/corpus.err" >&2
  exit 2
fi

# ── markers file: profile order is documentary; re-sort longest-byte-first so
#    a 🔴🔴🔴 fragment is never mis-split by an earlier, shorter 🔴 pass ────────
: > "$TMP/markers-raw.tsv"
printf '%s\n' "$SEVERITY_MARKERS" | while IFS= read -r ML; do
  [ -z "$ML" ] && continue
  MK="${ML%%|*}"; LV="${ML#*|}"
  [ -z "$MK" ] && continue
  BYTES=$(printf '%s' "$MK" | wc -c | tr -d ' ')
  printf '%s\t%s\t%s\n' "$BYTES" "$MK" "$LV" >> "$TMP/markers-raw.tsv"
done
sort -t "$(printf '\t')" -k1,1nr "$TMP/markers-raw.tsv" | cut -f2,3 > "$TMP/markers.tsv"

if [ ! -s "$TMP/markers.tsv" ]; then
  echo "rails-index: STOP — PF_SEVERITY_MARKERS produced zero usable marker(s)." >&2
  exit 2
fi

# ══ PHASE 1 — EXTRACTION ════════════════════════════════════════════════════
cat > "$TMP/extract.awk" << 'AWK_EOF'
function classify(c) {
  if (c ~ FILE_RE)                               return "file"
  if (c ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)$/)        return "symbol"
  if (c ~ TABLE_RE)                              return "table"
  if (c ~ /^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$/)      return "column"
  return ""
}

BEGIN {
  nmarkers = 0
  while ((getline mline < MARKFILE) > 0) {
    if (mline == "") continue
    split(mline, mp, "\t")
    nmarkers++
    marker[nmarkers] = mp[1]
    mlevel[nmarkers] = mp[2]
  }
  close(MARKFILE)
  total_lines = 0
  total_frags = 0
  frags_no_artefact = 0
  total_rows = 0
  parent_rows = 0
}

substr($0, 1, 2) == "- " {
  total_lines++
  line = $0
  for (m = 1; m <= nmarkers; m++) {
    gsub(marker[m], "\001" mlevel[m] "\002", line)
  }
  n = split(line, frags, "\001")
  for (i = 1; i <= n; i++) {
    if (i == 1) {
      lvl = "INFO"; txt = frags[1]
    } else {
      p = index(frags[i], "\002")
      if (p == 0) { lvl = "INFO"; txt = frags[i] }
      else { lvl = substr(frags[i], 1, p - 1); txt = substr(frags[i], p + 1) }
    }
    if (txt == "") continue
    total_frags++

    s = txt
    nart = 0
    while ((p1 = index(s, "`")) > 0) {
      rest = substr(s, p1 + 1)
      p2 = index(rest, "`")
      if (p2 == 0) break
      content = substr(rest, 1, p2 - 1)
      s = substr(rest, p2 + 1)
      if (content == "") continue
      cls = classify(content)
      if (cls != "") {
        nart++
        rtext = txt
        gsub(/\t/, " ", rtext)
        if (length(rtext) > TRUNC) rtext = substr(rtext, 1, TRUNC) "…"
        printf "%s\t%s\t%s\t%s#%d\tdirect\n", content, lvl, rtext, SRC, FNR
        total_rows++

        # A rail keyed on a COLUMN must ALSO be reachable from its TABLE, and
        # must inherit to the views that read that table. Both consumers key on
        # the TABLE name: the pre-flight matches artefacts EXACTLY ($1==cand),
        # and the expansion graph's edges are table→view. So a column-only key
        # is invisible from both sides. MEASURED: a build touching `customers`
        # printed "no rail keyed to any touched artefact" — a GREEN — while a
        # STOP rail on `customers.customer_no` sat in the same file, unreached.
        # 8 rails were in that state, 4 of them on
        # tables carrying no direct rail of their own, i.e. silently reachable
        # from nowhere. Emitting the parent row fixes lookup AND inheritance in
        # one place, because this row then enters the closure as a root.
        if (cls == "column") {
          dot = index(content, ".")
          parent = substr(content, 1, dot - 1)
          if (parent ~ TABLE_RE) {
            printf "%s\t%s\t%s\t%s#%d\tcolonne:%s\n", parent, lvl, rtext, SRC, FNR, content
            total_rows++
            parent_rows++
          }
        }
      }
    }
    if (nart == 0) frags_no_artefact++
  }
}

END {
  printf "EXTRACT-STATS\tarc_lines=%d\tfragments=%d\tfragments_no_artefact=%d\tbase_rows=%d\tcolumn_parent_rows=%d\n", \
    total_lines, total_frags, frags_no_artefact, total_rows, parent_rows > "/dev/stderr"
}
AWK_EOF

# One awk pass PER corpus, so column 4 (source) keeps naming the file#line a
# human can open — a merged pass would collapse FNR across files and every
# citation would point at the wrong line.
: > "$TMP/base.tsv"
: > "$TMP/extract.stats"
while IFS= read -r CORPUS_REL; do
  [ -z "$CORPUS_REL" ] && continue
  awk -v MARKFILE="$TMP/markers.tsv" -v TABLE_RE="$TABLE_RE" -v FILE_RE="$FILE_RE" -v TRUNC="$TRUNC" -v SRC="$CORPUS_REL" \
      -f "$TMP/extract.awk" "$REPO_ROOT/$CORPUS_REL" >> "$TMP/base.tsv" 2>> "$TMP/extract.stats"
  # Per-corpus row count: a corpus contributing ZERO rows is reported, never
  # inferred from a total. A register that stops matching (its bullets
  # reformatted, say) would otherwise vanish behind the index's own rows.
  CORPUS_ROWS=$(awk -F '\t' -v s="$CORPUS_REL" '$4 ~ ("^" s "#") {n++} END {print n+0}' "$TMP/base.tsv")
  printf 'CORPUS\t%s\trows=%d\n' "$CORPUS_REL" "$CORPUS_ROWS" >> "$TMP/extract.stats"
done < "$CORPUS_LIST"

cat "$TMP/extract.stats" >&2
BASE_ROWS=$(wc -l < "$TMP/base.tsv" | tr -d ' ')

# ══ PHASE 2 — EXPANSION (transitive view closure) ══════════════════════════
EXPANSION_MEASURED=0
INHERITED_ROWS=0
: > "$TMP/inherited.tsv"

if [ "$REFRESH_GRAPH" = 1 ]; then
  if [ -z "$EXPAND_CMD" ]; then
    echo "rails-index: WARN — --refresh-graph given but profile defines no PF_ARTEFACT_EXPAND. Expansion UNMEASURED." >&2
  else
    mkdir -p "$(dirname "$GRAPH_CACHE")" || exit 64
    if GRAPH_OUT=$(eval "$EXPAND_CMD" 2>"$TMP/graph.err") && [ -n "$GRAPH_OUT" ]; then
      printf '%s\n' "$GRAPH_OUT" > "$GRAPH_CACHE"
      echo "rails-index: refreshed graph cache — $(wc -l < "$GRAPH_CACHE" | tr -d ' ') edge(s) → $GRAPH_CACHE_REL" >&2
    else
      echo "rails-index: WARN — --refresh-graph probe failed or returned nothing:" >&2
      sed 's/^/         /' "$TMP/graph.err" >&2
      echo "rails-index: falling back to any existing cache at $GRAPH_CACHE_REL, if present." >&2
    fi
  fi
fi

if [ -s "$GRAPH_CACHE" ]; then
  cat > "$TMP/expand.awk" << 'AWK_EOF'
BEGIN {
  FS = "\t"
  nedges = 0
  while ((getline gline < GRAPHFILE) > 0) {
    if (gline == "") continue
    split(gline, gp, "\t")
    if (gp[1] == "" || gp[2] == "") continue
    nedges++
    efrom[nedges] = gp[1]
    eto[nedges] = gp[2]
  }
  close(GRAPHFILE)
  rowid = 0
  bound_hits = 0
  inherited = 0
}

{
  rowid++
  root = $1; sev = $2; rail = $3; source = $4
  fn = 1
  frontier[1] = root
  depth = 0
  while (fn > 0 && depth < MAXITER) {
    newfn = 0
    for (i = 1; i <= fn; i++) {
      cur = frontier[i]
      for (e = 1; e <= nedges; e++) {
        if (efrom[e] == cur) {
          v = eto[e]
          key = rowid SUBSEP v
          if (!(key in visited)) {
            visited[key] = 1
            printf "%s\t%s\t%s\t%s\tvia:%s\n", v, sev, rail, source, cur
            inherited++
            newfn++
            newfrontier[newfn] = v
          }
        }
      }
    }
    fn = newfn
    for (i = 1; i <= fn; i++) frontier[i] = newfrontier[i]
    depth++
  }
  if (fn > 0 && depth >= MAXITER) {
    bound_hits++
    printf "rails-index: WARN — expansion depth bound (%d) reached for root '%s' — closure may be INCOMPLETE, raise PF_ARTEFACT_EXPAND_MAX_ITER\n", MAXITER, root > "/dev/stderr"
  }
}

END {
  printf "EXPAND-STATS\tedges=%d\tinherited_rows=%d\tbound_hits=%d\n", nedges, inherited, bound_hits > "/dev/stderr"
}
AWK_EOF
  awk -v GRAPHFILE="$GRAPH_CACHE" -v MAXITER="$MAX_ITER" -f "$TMP/expand.awk" "$TMP/base.tsv" \
      > "$TMP/inherited.tsv" 2> "$TMP/expand.stats"
  cat "$TMP/expand.stats" >&2
  EXPANSION_MEASURED=1
  INHERITED_ROWS=$(wc -l < "$TMP/inherited.tsv" | tr -d ' ')
else
  printf '\n'
  printf '\033[33m● UNMEASURED — no artefact-graph cache at %s and --refresh-graph not given.\033[0m\n' "$GRAPH_CACHE_REL" >&2
  printf '  Writing DIRECT rails only. A rail posed on a TABLE will NOT propagate to the\n' >&2
  printf '  views that read it — transitive (via:) rows are absent, not zero-by-fact.\n' >&2
  printf '  Re-run with --refresh-graph to compute them.\n' >&2
  printf '\n' >&2
fi

# ══ WRITE OUTPUT (atomic) ═══════════════════════════════════════════════════
mkdir -p "$(dirname "$OUTPUT")" || exit 64
sort -t "$(printf '\t')" -k1,1 -k2,2 "$TMP/base.tsv" "$TMP/inherited.tsv" > "$TMP/final.tsv"
mv "$TMP/final.tsv" "$OUTPUT"

DISTINCT_ARTEFACTS=$(cut -f1 "$OUTPUT" | sort -u | wc -l | tr -d ' ')
TOTAL_ROWS=$(wc -l < "$OUTPUT" | tr -d ' ')

printf '\n\033[1mrails-index\033[0m  → %s\n' "$OUTPUT_REL"
printf '  base (direct) rows   : %s\n' "$BASE_ROWS"
printf '  inherited (via:) rows: %s\n' "$INHERITED_ROWS"
printf '  total rows           : %s\n' "$TOTAL_ROWS"
printf '  distinct artefacts   : %s\n' "$DISTINCT_ARTEFACTS"
if [ "$EXPANSION_MEASURED" = 1 ]; then
  printf '  expansion            : MEASURED (graph cache %s)\n' "$GRAPH_CACHE_REL"
  exit 0
else
  printf '  expansion            : \033[33mUNMEASURED\033[0m (no cache — run --refresh-graph)\n'
  exit 1
fi
