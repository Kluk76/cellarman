#!/usr/bin/env bash
# tests/graph-smoke.sh - regression suite for pm-kit/kernel/graph.sh and the two
# example extractors in pm-kit/profiles/extractors/. Builds its own fixture
# repositories under $TMPDIR (mktemp -d), copies the kernel scripts, a throwaway
# profile and the extractors into them, and never touches the repository it lives
# in. Prints "N passed, M failed"; exits non-zero on any failure.
#
# Usage:  bash tests/graph-smoke.sh   (GSMOKE_KEEP=1 keeps the fixtures)
# Mutation checks (by hand - each must make the suite FAIL, and shows the answer):
#   GSMOKE_MUTATE=a  delete one edge from the built edge file
#   GSMOKE_MUTATE=b  turn a literal include of the fixture into a variable one
#   GSMOKE_MUTATE=c  make the extractor drop unresolved (AMBIGUOUS) includes
#   GSMOKE_MUTATE=d  SQL extractor: remove the known-tables filter (accept every name)
#   GSMOKE_MUTATE=e  SQL extractor: drop interpolated-table (AMBIGUOUS) edges
#   GSMOKE_MUTATE=f  SQL extractor: swap read/write for UPDATE ... JOIN
# The SQL cases run in a second fixture repository (fx2) with a fixture table list.
# Needs: bash, git, awk, sed, grep, find, sort, xargs, mktemp, touch, tr, cut.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../pm-kit" && pwd)"
[ -f "$KIT/kernel/graph.sh" ] || { echo "graph-smoke: no kernel/graph.sh under $KIT" >&2; exit 64; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/graph-smoke.XXXXXX")" || exit 64
SB="$(cd "$SB" && pwd)"
cleanup() { [ "${GSMOKE_KEEP:-0}" = 1 ] && echo "graph-smoke: fixture kept at $SB" || rm -rf "$SB"; }
trap cleanup EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$SB/home"; mkdir -p "$HOME"
unset PM_REPO_ROOT PM_PROFILE

N_PASS=0; N_FAIL=0
pass() { N_PASS=$((N_PASS+1)); printf 'PASS  %s\n' "$1"; }
fail() { N_FAIL=$((N_FAIL+1)); printf 'FAIL  %s\n' "$1"; }
# ok <desc> <0|1...>  (0 = holds)
ok() { if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; fi; }
TAB="$(printf '\t')"

F="$SB/fx"; mkdir -p "$F" && cd "$F" || exit 64
git init -q . 2>/dev/null
mkdir -p lib/one lib/two pages/sub claude-brain/pm-kit/kernel claude-brain/pm-kit/profiles/extractors
cp "$KIT/kernel/graph.sh" "$KIT/kernel/profile-lib.sh" claude-brain/pm-kit/kernel/
cp "$KIT/profiles/extractors/php-include-edges.sh" claude-brain/pm-kit/profiles/extractors/php-include-edges.sh
cat > claude-brain/pm-kit/profiles/fx.conf <<'EOF'
PF_EDGE_INPUTS="lib/*.php pages/*.php"
PF_EDGE_OUTPUT="claude-brain/pm-kit/state/artefact-edges.tsv"
PF_EDGE_EXTRACTORS="include"
PF_EDGE_CMD_include='bash "$GRAPH_KIT_DIR/profiles/extractors/php-include-edges.sh"'
EOF
w() { printf '%s\n' "<?php" "$2" > "$1"; }
w lib/base.php  "function base() {}"
w lib/a.php     "require_once 'base.php';"
w lib/inf.php   "function inf() {}"
w lib/solo.php  "function solo() {}"
w lib/maybe.php "function maybe() {}"
w lib/one/dup.php "function dup1() {}"
w lib/two/dup.php "function dup2() {}"
w pages/p1.php  "require __DIR__ . '/../lib/base.php';"
w pages/sub/p2.php "require dirname(__DIR__) . '/../lib/base.php';"
w pages/sub/p3.php "include_once dirname(__DIR__, 2) . '/lib/base.php';"
w pages/p4.php  "\$root = '/x'; include \$root . '/lib/inf.php';"
w pages/p5.php  "include \$path;"
printf '%s\n' "<?php" "// require 'lib/base.php';" "# include 'lib/base.php';" "/* include 'lib/base.php';" "   require 'lib/base.php'; */" "echo 'we require_once nothing and include nothing';" "/* one */ \$x = 1; // include 'lib/base.php'" > pages/p6.php
w pages/p7.php  "require __DIR__ . '/gone.php';"
w pages/p8.php  "require __DIR__ . '/../lib/one/dup.php';"
w pages/p9.php  "require __DIR__ . '/../lib/two/dup.php';"
w pages/p10.php "include \$d . '/dup.php';"
w pages/p11.php "require __DIR__ . '/' . \$name . 'maybe.php';"
w pages/top.php "require __DIR__ . '/../lib/a.php';"
w pages/s.php   "require_once __DIR__ . '/../lib/solo.php';"
git add -A >/dev/null 2>&1

case "${GSMOKE_MUTATE:-}" in
  b) w pages/s.php "require_once \$dir . '/' . \$x . '/solo.php';"; git add -A >/dev/null 2>&1; echo "MUTATION b: pages/s.php now includes solo.php through a variable" ;;
  c) sed -E 's/edge\(raw, "AMBIGUOUS", ln\)/NEDGE += 0/' claude-brain/pm-kit/profiles/extractors/php-include-edges.sh > h.tmp && mv h.tmp claude-brain/pm-kit/profiles/extractors/php-include-edges.sh
     echo "MUTATION c: extractor no longer writes AMBIGUOUS edges" ;;
esac

G="bash claude-brain/pm-kit/kernel/graph.sh"
EDGES=claude-brain/pm-kit/state/artefact-edges.tsv
# g <args...>: stdout -> $OUT, stderr -> $ERR, exit code -> $RC (never through a pipe)
g() { $G "$@" > "$SB/out" 2> "$SB/err"; RC=$?; }
hasl() { grep -qE -- "$1" "${2:-$SB/out}"; }

# ── build ────────────────────────────────────────────────────────────────────
g build; ok "build exits 0" "$RC"
[ -f "$EDGES" ]; ok "edge file written" "$?"
[ ! -e "$EDGES".tmp ] && [ -z "$(find claude-brain/pm-kit/state -name '.edges.*' 2>/dev/null)" ]; ok "no temp file left behind" "$?"
hasl 'kind include +' && hasl 'provenance EXTRACTED' && hasl 'provenance INFERRED' && hasl 'provenance AMBIGUOUS'; ok "build prints counts per kind and provenance" "$?"
if [ "${GSMOKE_MUTATE:-}" = a ]; then
  grep -v "^pages/p1.php${TAB}" "$EDGES" > "$SB/e.tmp"; mv "$SB/e.tmp" "$EDGES"; echo "MUTATION a: edge pages/p1.php -> lib/base.php deleted from the edge file"
fi
has_edge() { awk -F'\t' -v a="$1" -v b="$2" -v p="$3" '$1==a && $2==b && $4==p {f=1} END{exit f?0:1}' "$EDGES"; }
has_edge pages/p1.php lib/base.php EXTRACTED; ok "extract: __DIR__ . '/../x' -> EXTRACTED" "$?"
has_edge lib/a.php lib/base.php EXTRACTED; ok "extract: plain literal relative to the including file -> EXTRACTED" "$?"
has_edge pages/sub/p2.php lib/base.php EXTRACTED; ok "extract: dirname(__DIR__) . '/../x' -> EXTRACTED" "$?"
has_edge pages/sub/p3.php lib/base.php EXTRACTED; ok "extract: include_once dirname(__DIR__, 2) -> EXTRACTED" "$?"
has_edge pages/p4.php lib/inf.php INFERRED; ok "extract: variable . '/lib/inf.php' (one match) -> INFERRED" "$?"
has_edge pages/p5.php '$path' AMBIGUOUS; ok "extract: include \$path -> AMBIGUOUS with the raw expression as target" "$?"
has_edge pages/p7.php "__DIR__ . '/gone.php'" AMBIGUOUS; ok "extract: target that does not exist -> AMBIGUOUS, not dropped" "$?"
has_edge pages/p10.php "\$d . '/dup.php'" AMBIGUOUS; ok "extract: suffix matching two files -> AMBIGUOUS" "$?"
! grep -q "^pages/p6.php${TAB}" "$EDGES"; ok "extract: includes inside // # /* */ comments and a prose string -> no edge" "$?"
[ "$(awk -F'\t' 'NF!=5' "$EDGES" | wc -l | tr -d ' ')" = 0 ]; ok "every edge line has five columns" "$?"

# ── affected: the four exit codes ────────────────────────────────────────────
g affected lib/base.php
ok "affected base.php -> exit 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)"
[ "$(wc -l < "$SB/out" | tr -d ' ')" = 4 ] && hasl "^pages/p1.php${TAB}include${TAB}EXTRACTED${TAB}1\$" && hasl "^lib/a.php${TAB}include${TAB}EXTRACTED${TAB}1\$"; ok "affected base.php depth 1 = 4 results, tab format path/kind/provenance/depth" "$?"
hasl 'verdict 0' "$SB/err"; ok "exit 0 carries a verdict line on stderr" "$?"
g affected lib/base.php --depth 2
[ "$RC" = 0 ] && hasl "^pages/top.php${TAB}include${TAB}EXTRACTED${TAB}2\$" && [ "$(wc -l < "$SB/out" | tr -d ' ')" = 5 ]; ok "depth walk: --depth 2 adds pages/top.php at depth 2" "$?"
g affected lib/base.php --depth 2 --budget 2
[ "$(wc -l < "$SB/out" | tr -d ' ')" = 3 ] && hasl '^## cut: 3 more result' ; ok "budget: 2 lines kept plus a '## cut: 3 more' line" "$?"
g affected lib/inf.php
[ "$RC" = 0 ] && hasl "^pages/p4.php${TAB}include${TAB}INFERRED${TAB}1\$"; ok "affected via an INFERRED edge -> exit 0, weakest hop INFERRED" "$?"
g affected solo.php
[ "$RC" = 0 ] && hasl "^pages/s.php${TAB}include${TAB}EXTRACTED${TAB}1\$"; ok "affected by unambiguous basename (solo.php) -> exit 0 and the includer" "$?"
g affected pages/top.php
[ "$RC" = 4 ] && [ ! -s "$SB/out" ]; ok "nothing depends on it, nothing ambiguous -> exit 4" "$?"
g affected dup.php
[ "$RC" = 3 ] && hasl '^## AMBIGUOUS' && hasl 'lib/one/dup.php' && hasl 'lib/two/dup.php'; ok "two files with the same basename -> exit 3 listing both" "$?"
g affected lib/one/dup.php
[ "$RC" = 3 ] && hasl "^pages/p8.php${TAB}include${TAB}EXTRACTED${TAB}1\$" && hasl "^## AMBIGUOUS candidates" && hasl "pages/p10.php${TAB}\\\$d \. '/dup.php'"; ok "certain result AND ambiguous candidate printed, separated -> exit 3" "$?"
g affected lib/maybe.php
[ "$RC" = 3 ] && hasl "pages/p11.php${TAB}" && hasl '^## AMBIGUOUS candidates'; ok "no certain result but an ambiguous include names it -> exit 3 (never 4)" "$?"
g affected lib/nothere.php
[ "$RC" = 5 ]; ok "unknown node -> exit 5 (not measured), never 4" "$?"
g affected base.php --kind nokind
[ "$RC" = 4 ]; ok "--kind filter with no such kind -> exit 4" "$?"

# ── rank ─────────────────────────────────────────────────────────────────────
g rank --top 3
[ "$RC" = 0 ] && [ "$(sed -n 1p "$SB/out")" = "4${TAB}lib/base.php" ]; ok "rank: lib/base.php first with in-degree 4" "$?"
[ "$(grep -vc '^#' "$SB/out" | tr -d ' ')" = 3 ]; ok "rank: --top 3 prints three ranked lines" "$?"
hasl '^# AMBIGUOUS edges \(not counted above\): [1-9]'; ok "rank: AMBIGUOUS edges counted separately" "$?"
hasl "^1${TAB}lib/a.php\$" && ! grep -q 'p5.php\|gone.php' "$SB/out"; ok "rank: ties by path, AMBIGUOUS raw targets never ranked" "$?"

# ── path ─────────────────────────────────────────────────────────────────────
g path pages/top.php lib/base.php
[ "$RC" = 0 ] && [ "$(wc -l < "$SB/out" | tr -d ' ')" = 2 ] && [ "$(sed -n 1p "$SB/out")" = "pages/top.php${TAB}lib/a.php${TAB}EXTRACTED" ]; ok "path found: top -> a -> base in 2 hops, exit 0" "$?"
g path lib/base.php pages/top.php
[ "$RC" = 4 ]; ok "path not found, nothing ambiguous -> exit 4" "$?"
g path pages/p1.php lib/maybe.php
[ "$RC" = 3 ] && hasl '^## AMBIGUOUS'; ok "path not found but an ambiguous include names the target -> exit 3" "$?"
g path pages/top.php lib/base.php --depth 1
[ "$RC" = 4 ]; ok "path bounded by --depth (1 hop is not enough) -> exit 4" "$?"

# ── stale / missing edge file: --no-rebuild is strict, --allow-stale is old, default rebuilds ──
touch -t 203501010000 lib/base.php
g affected lib/base.php --no-rebuild
[ "$RC" = 2 ] && hasl 'older than its inputs' "$SB/err" && [ ! -s "$SB/out" ]; ok "stale edge file + --no-rebuild -> 'not measured' exit 2, no answer" "$?"
g rank --no-rebuild; [ "$RC" = 2 ]; ok "stale edge file + --no-rebuild: rank -> exit 2" "$?"
g path pages/top.php lib/base.php --no-rebuild; [ "$RC" = 2 ]; ok "stale edge file + --no-rebuild: path -> exit 2" "$?"
g summary lib/base.php --no-rebuild; [ "$RC" = 2 ] && [ ! -s "$SB/out" ]; ok "stale edge file + --no-rebuild: summary -> exit 2, no answer" "$?"
# an edge that exists only in the OLD file proves --allow-stale answers from it without rebuilding
printf 'pages/ghost.php\tlib/base.php\tinclude\tEXTRACTED\tpages/ghost.php#1\n' >> "$EDGES"; touch -t 203412312359 "$EDGES"; touch -t 203501010000 lib/base.php
cp "$EDGES" "$SB/old.edges"
g affected lib/base.php --allow-stale
[ "$RC" = 0 ] && hasl "^pages/ghost.php${TAB}include" && ! hasl 'rebuilt' "$SB/err" && cmp -s "$EDGES" "$SB/old.edges"; ok "--allow-stale answers from the OLD file (ghost edge visible), no rebuild, file untouched" "$?"
g affected lib/base.php
[ "$RC" = 0 ] && [ "$(grep -c 'edge file was stale — rebuilt in [0-9]*s' "$SB/err")" = 1 ] && [ "$(grep -c 'rebuilt' "$SB/err")" = 1 ] && ! hasl 'ghost' && hasl "^pages/p1.php${TAB}include"; ok "stale edge file, default -> ONE stderr line 'rebuilt in Ns', then the correct fresh answer" "$?"
touch -t 200001010000 lib/base.php
touch "$EDGES"
g affected lib/base.php; [ "$RC" = 0 ] && ! hasl 'rebuilt' "$SB/err"; ok "fresh edge file -> answers without rebuilding or any extra stderr line" "$?"
mv "$EDGES" "$EDGES.hold"
g affected lib/base.php --no-rebuild
[ "$RC" = 2 ] && hasl 'edge file absent' "$SB/err"; ok "missing edge file + --no-rebuild -> 'not measured' exit 2 (never 4)" "$?"
g rank --no-rebuild; [ "$RC" = 2 ]; ok "missing edge file + --no-rebuild: rank -> exit 2" "$?"
g affected lib/base.php --allow-stale; [ "$RC" = 2 ] && [ ! -e "$EDGES" ]; ok "missing edge file + --allow-stale -> exit 2, nothing built" "$?"
g affected lib/base.php
[ "$RC" = 0 ] && [ -f "$EDGES" ] && hasl 'edge file was absent — rebuilt in' "$SB/err"; ok "missing edge file, default -> rebuilt, one stderr line, correct answer" "$?"
rm -f "$EDGES"; mv "$EDGES.hold" "$EDGES"
# failed rebuild: stale file + a broken extractor -> exit 2, previous file intact
touch -t 203501010000 lib/base.php
cp claude-brain/pm-kit/profiles/fx.conf "$SB/fx.conf.keep"
echo "PF_EDGE_CMD_include='exit 7'" >> claude-brain/pm-kit/profiles/fx.conf
cp "$EDGES" "$SB/prev"
g affected lib/base.php
[ "$RC" = 2 ] && [ ! -s "$SB/out" ] && hasl 'automatic rebuild failed' "$SB/err" && cmp -s "$EDGES" "$SB/prev" && [ -z "$(find claude-brain/pm-kit/state -name '.edges.*' 2>/dev/null)" ]; ok "failed rebuild -> exit 2, previous edge file byte-identical, no temp left" "$?"
cp "$SB/fx.conf.keep" claude-brain/pm-kit/profiles/fx.conf
touch -t 200001010000 lib/base.php
touch "$EDGES"; touch -t 200001010000 claude-brain/pm-kit/profiles/fx.conf

# ── affected: kind column, comma list; summary ───────────────────────────────
g affected lib/base.php
[ "$(awk -F'\t' 'NF!=4' "$SB/out" | wc -l | tr -d ' ')" = 0 ] && [ "$(cut -f2 "$SB/out" | sort -u)" = include ]; ok "affected: every result line carries a kind column (4 fields)" "$?"
g affected lib/base.php --kind include,nokind; [ "$RC" = 0 ] && [ "$(wc -l < "$SB/out" | tr -d ' ')" = 4 ]; ok "--kind comma list: one known + one unknown kind -> the known one answers" "$?"
g affected lib/base.php --kind nokind,other; [ "$RC" = 4 ]; ok "--kind comma list with no matching kind -> exit 4" "$?"
g summary lib/base.php
[ "$RC" = 0 ] && [ "$(cat "$SB/out")" = "lib/base.php: 4 include" ] && [ "$(wc -l < "$SB/out" | tr -d ' ')" = 1 ]; ok "summary: one line 'X: 4 include', exit 0" "$?"
g summary lib/one/dup.php
[ "$RC" = 3 ] && [ "$(cat "$SB/out")" = "lib/one/dup.php: 1 include, 1 ambiguous" ]; ok "summary: certain + ambiguous counts, exit 3" "$?"
g summary lib/maybe.php
[ "$RC" = 3 ] && [ "$(cat "$SB/out")" = "lib/maybe.php: 1 ambiguous" ]; ok "summary: only the ambiguous count when nothing certain, exit 3" "$?"
g summary pages/top.php
[ "$RC" = 4 ] && [ "$(cat "$SB/out")" = "pages/top.php: no dependents" ]; ok "summary: nothing depends on it -> 'no dependents', exit 4" "$?"
g summary lib/nothere.php
[ "$RC" = 5 ] && [ ! -s "$SB/out" ]; ok "summary: unknown node -> exit 5, no stdout" "$?"
g summary dup.php
[ "$RC" = 3 ] && [ "$(wc -l < "$SB/out" | tr -d ' ')" = 1 ] && hasl 'ambiguous name, matches 2 nodes'; ok "summary: name matching two nodes -> ONE line, exit 3" "$?"
g summary
[ "$RC" = 64 ]; ok "summary without an argument -> exit 64" "$?"

# ── build failure leaves the previous file alone ─────────────────────────────
cp "$EDGES" "$SB/before"
cat >> claude-brain/pm-kit/profiles/fx.conf <<'EOF'
PF_EDGE_CMD_include='printf "a\tb\n"'
EOF
g build; RCB=$RC
[ "$RCB" = 2 ] && cmp -s "$EDGES" "$SB/before"; ok "malformed extractor output -> build exit 2 and edge file untouched" "$?"

# ── help and usage ───────────────────────────────────────────────────────────
g --help; [ "$RC" = 0 ] && hasl 'EXIT CODES'; ok "--help exits 0 and documents the exit codes" "$?"
g frobnicate; [ "$RC" = 64 ]; ok "unknown command -> exit 64" "$?"

# ══ SQL extractor (file -> table): second fixture repository ══════════════════
F2="$SB/fx2"; mkdir -p "$F2" && cd "$F2" || exit 64
git init -q . 2>/dev/null
mkdir -p app scripts db claude-brain/pm-kit/kernel claude-brain/pm-kit/profiles/extractors
cp "$KIT/kernel/graph.sh" "$KIT/kernel/profile-lib.sh" claude-brain/pm-kit/kernel/
cp "$KIT/profiles/extractors/sql-table-edges.sh" claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh
cat > claude-brain/pm-kit/profiles/fx.conf <<'EOF'
PF_EDGE_INPUTS="app/*.php scripts/*.py scripts/*.js db/known-tables.txt db/table-writers.tsv"
PF_EDGE_OUTPUT="claude-brain/pm-kit/state/artefact-edges.tsv"
PF_EDGE_EXTRACTORS="sql"
PF_EDGE_CMD_sql='bash "$GRAPH_KIT_DIR/profiles/extractors/sql-table-edges.sh" --tables db/known-tables.txt --writers db/table-writers.tsv'
EOF
# the known-tables list (comments, blanks and mixed case are tolerated) and the declared writers
cat > db/known-tables.txt <<'EOF'
# fixture list of tables and views, one per line
items
Customers
orders
order_lines

monthly_report   # a derived table
ledger_x
v_summary
EOF
printf '%s\t%s\n' items app/a_alias.php customers "" orders manual-only order_lines "scripts/*.js or nowhere/zzz.php" monthly_report "app/builder.php (compile)" ledger_x scripts/gone.py v_summary "" > db/table-writers.tsv
x() { printf '%s\n' "<?php" "$@" > "$F2/$FILE_"; }
FILE_=app/a_alias.php; x "\$q = \"SELECT * FROM items customers JOIN orders o ON o.sku = customers.id WHERE 1\";"
FILE_=app/b_cte.php;   x "\$q = \"WITH cte_x AS (SELECT id FROM orders) SELECT * FROM cte_x JOIN items k ON k.id = cte_x.id JOIN ledger_x z ON z.id = k.id\";"
FILE_=app/c_comment.php; x "// SELECT * FROM customers" "# UPDATE customers SET a=1" "-- DELETE FROM customers" "/* INSERT INTO customers" "   (a) VALUES (1) */" "\$x = 1; // FROM customers" "<!-- FROM customers -->" "/** @see UPDATE customers" " *  and FROM customers */"
FILE_=app/d_prose.php; x "echo \"Refreshed since last week\"; // from the list" "\$m = \"update the page\"; \$n = \"Copy from page to page\";"
FILE_=app/e_insel.php; x "\$q = \"INSERT INTO order_lines (a,b) SELECT a,b FROM orders WHERE 1\";"
FILE_=app/f_updjoin.php; x "\$q = \"UPDATE orders o JOIN customers c ON c.id = o.cid SET o.x = 1\";"
FILE_=app/g_delmulti.php; x "\$a = \"DELETE order_lines FROM order_lines JOIN customers c ON c.id = 1\";" "\$b = \"DELETE o FROM orders o JOIN items l ON l.id = o.id\";"
FILE_=app/h_ticks.php; x "\$a = \"SELECT * FROM \`customers\` WHERE 1\";" "\$b = \"UPDATE \`acme\`.\`order_lines\` SET a = 1\";" "\$c = \"SELECT 1 FROM information_schema.tables\";"
FILE_=app/i_amb.php; x "\$a = \"SELECT * FROM \$table\";" "\$b = 'SELECT x FROM ' . \$t;" "\$c = \"UPDATE {\$prefix}_x SET a=1\";" "\$d = \"UPDATE orders_{\$y} SET a=1\";"
FILE_=app/j_multi.php; x "\$a = \"INSERT INTO" "   customers (a) VALUES (1)\";" "\$b = \"SELECT *" "   FROM" "     order_lines" "   WHERE 1\";" "\$c = 'SELECT x FROM ' . 'orders';"
FILE_=app/k_unknown.php; x "\$q = \"SELECT * FROM unknown_tbl\";"
FILE_=app/n_dup.php; x "\$a = 1;" "\$q = \"SELECT * FROM customers\";" "\$b = 2;" "\$r = \"SELECT id FROM customers WHERE 1\";"
FILE_=app/o_dupkey.php; x "\$a = \"INSERT INTO customers (a) VALUES (1) ON DUPLICATE KEY UPDATE a = 2\";" "\$b = \"SELECT * FROM order_lines WHERE 1 FOR UPDATE\";"
FILE_=app/builder.php; x "\$q = \"INSERT INTO monthly_report (a) VALUES (1)\";"
printf '%s\n' "from os import path" "cur.execute(\"SELECT * FROM order_lines\")" "# UPDATE orders SET a=1" "x = 1  # FROM customers" > scripts/l_ext.py
printf '%s\n' "// FROM customers" "db.query(\`SELECT * FROM orders\`);" "db.query(\"UPDATE customers SET a=1\");" > scripts/m_ext.js
git add -A >/dev/null 2>&1

case "${GSMOKE_MUTATE:-}" in
  d) sed -E 's/if \(nm in S\) addedge\(/if (1) addedge(/' claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh > h.tmp && mv h.tmp claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh
     echo "MUTATION d: SQL extractor accepts every name (no known-tables filter)" ;;
  e) sed -E 's/^  addedge\(\(cls == "W"\) \? "sql-write" : "sql-read", squash/  return; addedge((cls == "W") ? "sql-write" : "sql-read", squash/' claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh > h.tmp && mv h.tmp claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh
     echo "MUTATION e: SQL extractor drops interpolated-table (AMBIGUOUS) edges" ;;
  f) sed -E -e 's/\{ cls = "R"; kw = kwtxt \}/{ cls = (kwtxt == "join") ? "W" : "R"; kw = kwtxt }/' -e 's/cls = "W"; kw = kwtxt; DM = ""/cls = (kwtxt == "update") ? "R" : "W"; kw = kwtxt; DM = ""/' claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh > h.tmp && mv h.tmp claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh
     echo "MUTATION f: SQL extractor reads the UPDATE target and writes the JOIN source" ;;
esac

g build; ok "sql: build exits 0" "$RC"
cp "$SB/err" "$SB/build2.err"
hasl 'kind sql-read +' && hasl 'kind sql-write +' && hasl 'kind declared-writer +'; ok "sql: build prints counts for the three SQL kinds" "$?"
[ "$(awk -F'\t' 'NF!=5' "$EDGES" | wc -l | tr -d ' ')" = 0 ]; ok "sql: every edge line has five columns" "$?"
hasl 'REJECTED' "$SB/build2.err" && hasl 'sql-table-edges: 4 candidate name' "$SB/build2.err" && hasl '[[:space:]]cte_x$' "$SB/build2.err" && hasl '[[:space:]]unknown_tbl$' "$SB/build2.err" && hasl '[[:space:]]the$' "$SB/build2.err"; ok "sql: names outside the known list are counted (4) and the top list is printed on stderr" "$?"
no_to() { ! awk -F'\t' -v t="$1" '$2==t{f=1} END{exit f?0:1}' "$EDGES"; }
no_to cte_x && no_to unknown_tbl && no_to the && no_to page && no_to s && no_to o; ok "sql: CTE name, unknown table, prose words and aliases never become edges" "$?"
! grep -q "^app/c_comment.php${TAB}" "$EDGES"; ok "sql: SQL inside // # -- /* */ <!-- --> and doc comments -> no edge" "$?"
! grep -q "^app/d_prose.php${TAB}" "$EDGES"; ok "sql: prose ('depuis', 'from the list', 'update the page') -> no edge" "$?"
kind_edge() { awk -F'\t' -v a="$1" -v b="$2" -v k="$3" -v p="$4" '$1==a && $2==b && $3==k && $4==p {f=1} END{exit f?0:1}' "$EDGES"; }
! kind_edge app/a_alias.php customers sql-read EXTRACTED && kind_edge app/a_alias.php items sql-read EXTRACTED && kind_edge app/a_alias.php orders sql-read EXTRACTED; ok "sql: alias (even one spelled like a table) is not a table; FROM a x JOIN b -> a and b read" "$?"
kind_edge app/e_insel.php order_lines sql-write EXTRACTED && kind_edge app/e_insel.php orders sql-read EXTRACTED; ok "sql: INSERT ... SELECT -> write on the target, read on the source" "$?"
kind_edge app/f_updjoin.php orders sql-write EXTRACTED && kind_edge app/f_updjoin.php customers sql-read EXTRACTED && ! kind_edge app/f_updjoin.php orders sql-read EXTRACTED && ! kind_edge app/f_updjoin.php customers sql-write EXTRACTED; ok "sql: UPDATE a JOIN b SET -> a written (not read), b read (not written)" "$?"
kind_edge app/g_delmulti.php order_lines sql-write EXTRACTED && kind_edge app/g_delmulti.php customers sql-read EXTRACTED && kind_edge app/g_delmulti.php orders sql-write EXTRACTED && kind_edge app/g_delmulti.php items sql-read EXTRACTED && ! kind_edge app/g_delmulti.php order_lines sql-read EXTRACTED && ! kind_edge app/g_delmulti.php orders sql-read EXTRACTED; ok "sql: DELETE a FROM a JOIN b (also through an alias) -> a written only, b read" "$?"
kind_edge app/h_ticks.php customers sql-read EXTRACTED && kind_edge app/h_ticks.php order_lines sql-write EXTRACTED && [ "$(awk -F'\t' '$1=="app/h_ticks.php"' "$EDGES" | wc -l | tr -d ' ')" = 2 ]; ok "sql: backticks, schema.table (schema stripped), information_schema ignored" "$?"
kind_edge app/i_amb.php 'FROM $table' sql-read AMBIGUOUS && kind_edge app/i_amb.php "FROM ' . \$t" sql-read AMBIGUOUS && kind_edge app/i_amb.php 'UPDATE {$prefix}_x' sql-write AMBIGUOUS && kind_edge app/i_amb.php 'UPDATE orders_{$y}' sql-write AMBIGUOUS; ok "sql: interpolated / concatenated table -> AMBIGUOUS with the raw expression, never dropped" "$?"
kind_edge app/j_multi.php customers sql-write INFERRED && kind_edge app/j_multi.php order_lines sql-read INFERRED && kind_edge app/j_multi.php orders sql-read INFERRED; ok "sql: keyword/name split over lines, or two literals concatenated -> INFERRED" "$?"
kind_edge app/o_dupkey.php customers sql-write EXTRACTED && kind_edge app/o_dupkey.php order_lines sql-read EXTRACTED && ! kind_edge app/o_dupkey.php order_lines sql-write EXTRACTED && ! kind_edge app/o_dupkey.php customers sql-read EXTRACTED; ok "sql: ON DUPLICATE KEY UPDATE and FOR UPDATE are not table writes" "$?"
[ "$(awk -F'\t' '$1=="app/n_dup.php" && $2=="customers" && $3=="sql-read"' "$EDGES" | wc -l | tr -d ' ')" = 1 ] && grep -q "app/n_dup.php#3\$" "$EDGES"; ok "sql: one edge per (file, table, kind), source = the FIRST line" "$?"
kind_edge scripts/l_ext.py order_lines sql-read EXTRACTED && [ "$(awk -F'\t' '$1=="scripts/l_ext.py"' "$EDGES" | wc -l | tr -d ' ')" = 1 ]; ok "sql: .py file — SQL string read; '# ...' comments and 'from os import' ignored" "$?"
kind_edge scripts/m_ext.js customers sql-write EXTRACTED && kind_edge scripts/m_ext.js orders sql-read EXTRACTED && ! kind_edge scripts/m_ext.js customers sql-read EXTRACTED; ok "sql: .js file — template-literal SQL read, '//' comment ignored" "$?"
grep -q "^app/builder.php${TAB}monthly_report${TAB}declared-writer${TAB}EXTRACTED${TAB}db/table-writers.tsv#[0-9]" "$EDGES"; ok "sql: declared writer from the writers file -> EXTRACTED, source = the writers file#line" "$?"
kind_edge scripts/m_ext.js order_lines declared-writer INFERRED && kind_edge scripts/gone.py ledger_x declared-writer AMBIGUOUS && kind_edge nowhere/zzz.php order_lines declared-writer AMBIGUOUS; ok "sql: declared writer by glob -> INFERRED; one that matches no tracked file -> AMBIGUOUS (kept)" "$?"
! awk -F'\t' '$3=="declared-writer"{print $2}' "$EDGES" | grep -qE '^(orders|customers|v_summary)$'; ok "sql: free text / null / empty writer_script -> no declared-writer edge" "$?"

# affected, per kind
set_of() { awk -F'\t' '$0 !~ /^##/ {print $1}' "$SB/out" | sort | tr '\n' ' '; }
g affected customers --kind sql-write
[ "$RC" = 0 ] && [ "$(set_of)" = "app/j_multi.php app/o_dupkey.php scripts/m_ext.js " ]; ok "affected customers --kind sql-write -> exactly 3 writers, exit 0" "$?"
g affected customers --kind sql-read
[ "$RC" = 0 ] && [ "$(set_of)" = "app/f_updjoin.php app/g_delmulti.php app/h_ticks.php app/n_dup.php " ]; ok "affected customers --kind sql-read -> exactly 4 readers, exit 0" "$?"
g affected orders --kind sql-write
[ "$RC" = 3 ] && hasl '^app/f_updjoin.php' && hasl '^app/g_delmulti.php' && hasl '^## AMBIGUOUS candidates' && hasl 'UPDATE orders_\{\$y\}'; ok "affected orders --kind sql-write -> exit 3: certain writers + the interpolated orders_{\$y}" "$?"
g affected orders --kind sql-read
[ "$RC" = 0 ] && [ "$(set_of)" = "app/a_alias.php app/b_cte.php app/e_insel.php app/j_multi.php scripts/m_ext.js " ]; ok "affected orders --kind sql-read -> 5 readers, exit 0" "$?"
g affected order_lines --kind sql-write
[ "$RC" = 0 ] && [ "$(set_of)" = "app/e_insel.php app/g_delmulti.php app/h_ticks.php " ]; ok "affected order_lines --kind sql-write -> 3 writers (not the FOR UPDATE reader), exit 0" "$?"
g affected order_lines --kind sql-read
[ "$RC" = 0 ] && [ "$(set_of)" = "app/j_multi.php app/o_dupkey.php scripts/l_ext.py " ]; ok "affected order_lines --kind sql-read -> 3 readers" "$?"
g affected monthly_report --kind sql-write
[ "$RC" = 0 ] && [ "$(set_of)" = "app/builder.php " ]; ok "affected monthly_report --kind sql-write -> the pattern writer" "$?"
g affected monthly_report --kind declared-writer
[ "$RC" = 0 ] && [ "$(set_of)" = "app/builder.php " ]; ok "affected monthly_report --kind declared-writer -> the declared writer, exit 0" "$?"
g affected ledger_x --kind declared-writer
[ "$RC" = 3 ] && hasl 'scripts/gone.py'; ok "declared writer that matches no tracked file -> exit 3, never 4" "$?"
g affected order_lines --kind declared-writer
[ "$RC" = 3 ] && hasl "^scripts/m_ext.js${TAB}declared-writer${TAB}INFERRED${TAB}1\$" && hasl 'nowhere/zzz.php'; ok "declared writer by glob -> INFERRED result plus the unresolved one, exit 3" "$?"
g affected customers --kind declared-writer
[ "$RC" = 4 ]; ok "table with no declared writer -> exit 4" "$?"
g affected no_such_table --kind sql-read
[ "$RC" = 5 ]; ok "a name that is not a node -> exit 5" "$?"

# kind column and summary on the SQL fixture
g affected order_lines
[ "$RC" = 3 ] && hasl "^app/e_insel.php${TAB}sql-write${TAB}EXTRACTED${TAB}1\$" && hasl "^app/j_multi.php${TAB}sql-read${TAB}INFERRED${TAB}1\$" && hasl "^scripts/m_ext.js${TAB}declared-writer${TAB}INFERRED${TAB}1\$"; ok "affected without --kind: kinds are told apart by the column" "$?"
g affected order_lines --kind sql-write,declared-writer
[ "$RC" = 3 ] && ! hasl "${TAB}sql-read${TAB}" && hasl "${TAB}sql-write${TAB}" && hasl "${TAB}declared-writer${TAB}"; ok "--kind sql-write,declared-writer -> both kinds, no sql-read" "$?"
g summary order_lines
[ "$RC" = 3 ] && [ "$(cat "$SB/out")" = "order_lines: 1 declared-writer, 3 sql-read, 3 sql-write, 1 ambiguous" ]; ok "summary order_lines: non-zero kinds sorted by name, ambiguous last, exit 3" "$?"
g summary customers
[ "$RC" = 0 ] && [ "$(cat "$SB/out")" = "customers: 4 sql-read, 3 sql-write" ]; ok "summary customers: zero kinds omitted, exit 0" "$?"
g summary order_lines --kind sql-write
[ "$RC" = 0 ] && [ "$(cat "$SB/out")" = "order_lines: 3 sql-write" ]; ok "summary honours --kind" "$?"

# failing loudly: an extractor that cannot do its job exits non-zero with a message and prints no edge
ls app/*.php scripts/*.py scripts/*.js > "$SB/gf.txt"; git ls-files > "$SB/gt.txt"
SQLX=claude-brain/pm-kit/profiles/extractors/sql-table-edges.sh
sx() { GRAPH_FILES="$SB/gf.txt" GRAPH_TRACKED="$SB/gt.txt" bash $SQLX "$@" > "$SB/out" 2> "$SB/err"; RC=$?; }
sx --tables db/missing.txt
[ "$RC" != 0 ] && [ ! -s "$SB/out" ] && hasl 'known-tables list .* not found' "$SB/err"; ok "sql: known-tables list missing -> non-zero exit, loud message, no edge" "$?"
sx
[ "$RC" != 0 ] && [ ! -s "$SB/out" ] && hasl 'no --tables' "$SB/err"; ok "sql: no --tables argument -> non-zero exit and a clear message, not zero edges" "$?"
: > "$SB/empty.txt"
sx --tables "$SB/empty.txt"
[ "$RC" != 0 ] && [ ! -s "$SB/out" ] && hasl 'lists 0 tables' "$SB/err"; ok "sql: empty known-tables list -> non-zero exit, no edge" "$?"
printf '%s\n' '# only a comment' '   ' > "$SB/comment.txt"
sx --tables "$SB/comment.txt"
[ "$RC" != 0 ] && [ ! -s "$SB/out" ] && hasl 'lists 0 tables' "$SB/err"; ok "sql: a list holding only comments and blanks counts as empty -> non-zero exit" "$?"
sx --tables db/known-tables.txt --writers db/missing.tsv
[ "$RC" != 0 ] && [ ! -s "$SB/out" ] && hasl 'writers file .* not found' "$SB/err"; ok "sql: --writers names an absent file -> non-zero exit, no edge" "$?"
sx --tables db/known-tables.txt --bogus
[ "$RC" = 64 ] && hasl "unknown argument" "$SB/err"; ok "sql: unknown argument -> exit 64" "$?"
sx --tables db/known-tables.txt
[ "$RC" = 0 ] && ! grep -q "${TAB}declared-writer${TAB}" "$SB/out" && grep -q "${TAB}sql-read${TAB}" "$SB/out"; ok "sql: --writers is optional: without it no declared-writer edge, scan edges still printed" "$?"
sx --tables db/known-tables.txt --files-re '[.]py$'
[ "$RC" = 0 ] && [ "$(cut -f1 "$SB/out" | sort -u)" = "scripts/l_ext.py" ]; ok "sql: --files-re narrows the scanned files (only the .py file produces edges)" "$?"
# a build whose extractor fails must not leave a zero-edge file behind
cp claude-brain/pm-kit/state/artefact-edges.tsv "$SB/fx2.keep"
echo "PF_EDGE_CMD_sql='bash \"\$GRAPH_KIT_DIR/profiles/extractors/sql-table-edges.sh\" --tables db/nope.txt'" >> claude-brain/pm-kit/profiles/fx.conf
g build
[ "$RC" = 2 ] && hasl 'build FAILED' "$SB/err" && cmp -s claude-brain/pm-kit/state/artefact-edges.tsv "$SB/fx2.keep"; ok "build with an extractor that fails loudly -> exit 2, previous edge file untouched" "$?"

echo "$N_PASS passed, $N_FAIL failed"
[ "$N_FAIL" = 0 ]
