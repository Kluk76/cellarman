#!/usr/bin/env bash
# graph.sh — a small deterministic, LLM-free dependency graph for the PM kit.
# One `affected X` query replaces "grep the repository, then read N files".
# Portable kernel: carries no project nouns — extractors are profile settings
# (see profiles/example.conf, "DEPENDENCY GRAPH" section; ready-made examples in
# pm-kit/profiles/extractors/). The kit only knows: run command K, expect five
# TAB-separated columns on stdout.
#
# EDGE FILE  PF_EDGE_OUTPUT (default claude-brain/pm-kit/state/artefact-edges.tsv),
# generated and git-ignored (every clone rebuilds it):
#   from <TAB> to <TAB> kind <TAB> provenance <TAB> path#line
#   provenance, exactly one of
#     EXTRACTED  the target was read literally and is an existing tracked file
#     INFERRED   the target was reconstructed from an indirect-but-recognisable
#                form and resolves to exactly ONE existing file
#     AMBIGUOUS  variable, several candidates, or none. NEVER dropped silently:
#                `to` is then the raw expression, not a path.
#
# COMMANDS
#   graph.sh build                              run the extractors, write the edge
#                                               file atomically, print counts
#   graph.sh affected <X> [--kind K[,K...]] [--depth N] [--budget LINES]
#       who depends on X, transitively up to depth N (default 1, breadth-first,
#       visited set). stdout: `path <TAB> kind <TAB> provenance-of-weakest-hop <TAB> depth`,
#       sorted, at most --budget lines (default 60) then a `## cut:` line. A file that
#       reaches X through two kinds appears once per kind. --kind takes a comma list.
#       X = a repository path, a path suffix, or an unambiguous basename.
#   graph.sh summary <X> [--kind K[,K...]] [--depth N]
#       ONE stdout line for other tools: `X: <n> include, <n> sql-read, ... <n> ambiguous` (kinds are whatever the extractors emit)
#       (only the non-zero kinds, kinds read from the edge file, sorted by name,
#       `ambiguous` last; `X: no dependents` when none). Same exit codes as `affected`;
#       an X matching several nodes prints one line and exits 3.
#   graph.sh rank [--kind K] [--top N]          in-degree ranking, default 25:
#       `count <TAB> path` (EXTRACTED+INFERRED only; AMBIGUOUS edges counted apart)
#   graph.sh path <A> <B> [--kind K] [--depth N]  shortest chain A -> ... -> B
#       (A depends on ... B), default depth 6, one `from<TAB>to<TAB>provenance` per hop
#   Options: --conf <profile>  --allow-stale  --no-rebuild  -h|--help
#
# FRESHNESS  a query (affected / summary / rank / path) on an absent or stale edge
#   file REBUILDS it once (~5 s) and prints one stderr line (`graph: edge file was
#   stale — rebuilt in Ns`), then answers. A failed rebuild exits 2 and leaves the
#   previous file untouched. --no-rebuild keeps the strict behaviour (exit 2, no
#   build); --allow-stale answers from the old file and never builds (an absent file
#   is still exit 2). Concurrent builds are safe: each writes a per-process temp
#   file (mktemp) and renames it into place.
#
# EXIT CODES (affected / path; the verdict is also printed on stderr)
#   0  at least one result and every edge used is EXTRACTED or INFERRED
#   3  AMBIGUOUS: X (or A/B) matched several nodes, OR at least one AMBIGUOUS edge
#      could concern X (its raw expression contains X's basename). The certain
#      results are printed first, then a `## AMBIGUOUS` section.
#   4  no result and nothing ambiguous
#   2  NOT MEASURED: edge file unreadable, or absent / older than its inputs AND the
#      automatic rebuild failed or was refused (--no-rebuild / --allow-stale). Never
#      answered as 4.
#   5  NOT MEASURED: X (or A/B) is not a node of the graph (typo, untracked file)
#   64 usage error, no profile, or the profile declares nothing to run
#   rank: 0 = ranking printed, 4 = no edges, 2 = not measured (as above)
#   build: 0 = written, 2 = an extractor failed or emitted a malformed line
#      (the previous edge file is left untouched), 64 = cannot run
#   Honest limit of 3/0: an AMBIGUOUS edge that names NO file (a bare `$var`
#   reference) cannot be tied to any X. It is counted on stderr ("N unresolved
#   edges name no file") but does not turn 0 into 3 — otherwise no query on a
#   codebase with one dynamic reference could ever answer 0.
#
# PROFILE VARIABLES
#   PF_EDGE_INPUTS      git pathspecs (space-separated, globs allowed) naming the
#                       tracked files the extractors read; their mtimes drive the
#                       staleness check
#   PF_EDGE_OUTPUT      edge file path, repo-relative (default above)
#   PF_EDGE_EXTRACTORS  space-separated extractor NAMES ([A-Za-z0-9_])
#   PF_EDGE_CMD_<name>  shell command for one extractor. It runs with cwd = repo
#                       root and the env GRAPH_REPO_ROOT, GRAPH_KIT_DIR,
#                       GRAPH_FILES (file listing the tracked input files) and
#                       GRAPH_TRACKED (file listing every tracked path)
#
# STALENESS  chosen: the newest mtime among the tracked input files and the
#   profile versus the edge file's mtime (`find -newer`). Rationale: one cheap
#   `find` (no git-state parsing) that catches BOTH a checkout/pull (git rewrites
#   mtimes of what it changes) and a dirty edit, without a recorded HEAD that a
#   dirty tree would defeat. Blind spots: a file deleted since the build, and an
#   edit within the same filesystem-timestamp tick as the build.
#
# DESIGN CONSTRAINTS  bash 3.2 + BSD tools: no associative arrays / mapfile /
#   ${v,,}; awk without gensub/IGNORECASE; sed -E, no -i; grep -E; no readlink -f,
#   date -d or stat flags. LC_ALL=C is forced so results never depend on locale.
set -u
LC_ALL=C; export LC_ALL

# ── locate: repo root and profile come from profile-lib.sh, like claim.sh ───
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck disable=SC1091
. "$KIT_DIR/kernel/profile-lib.sh" || { echo "graph: cannot load profile-lib.sh" >&2; exit 64; }
CONF=""

CMD=""; P1=""; P2=""; KIND=""; DEPTH=""; BUDGET=60; TOP=25; ALLOW_STALE=0; NO_REBUILD=0; NODE_QUIET=0
die() { echo "graph: $1" >&2; exit 64; }
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

[ $# -ge 1 ] || { usage; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    --conf)         [ $# -ge 2 ] && [ -n "$2" ] || die "--conf needs a value"; CONF="$2"; shift 2 ;;
    --kind)         [ $# -ge 2 ] || die "--kind needs a value"; KIND="$2"; shift 2 ;;
    --depth)        [ $# -ge 2 ] && isnum "$2" || die "--depth needs a number"; DEPTH="$2"; shift 2 ;;
    --budget)       [ $# -ge 2 ] && isnum "$2" || die "--budget needs a number"; BUDGET="$2"; shift 2 ;;
    --top)          [ $# -ge 2 ] && isnum "$2" || die "--top needs a number"; TOP="$2"; shift 2 ;;
    --allow-stale)  ALLOW_STALE=1; shift ;;
    --no-rebuild)   NO_REBUILD=1; shift ;;
    -*)             die "unknown option '$1'" ;;
    *)  if [ -z "$CMD" ]; then CMD="$1"
        elif [ -z "$P1" ]; then P1="$1"
        elif [ -z "$P2" ]; then P2="$1"
        else die "unexpected argument '$1'"; fi
        shift ;;
  esac
done
case "$CMD" in build|affected|summary|rank|path) ;; *) die "unknown command '$CMD' (build|affected|summary|rank|path|--help)" ;; esac

# ── profile discovery (profile-lib.sh: --conf, $PM_PROFILE, the single profiles/*.conf) ──
pm_repo_root || die "NOT RUN — not inside a git repository and PM_REPO_ROOT is not set"
pm_find_profile "$CONF" || die "NOT RUN — no profile found (--conf, \$PM_PROFILE, or exactly one *.conf in $KIT_DIR/profiles/)"
# shellcheck disable=SC1090
. "$CONF"

: "${EDGE_OUT_REL:=${PF_EDGE_OUTPUT:-claude-brain/pm-kit/state/artefact-edges.tsv}}"
INPUTS="${PF_EDGE_INPUTS:-}"
EXTRACTORS="${PF_EDGE_EXTRACTORS:-}"
cd "$REPO_ROOT" || die "cannot cd $REPO_ROOT"
case "$EDGE_OUT_REL" in /*) EDGES="$EDGE_OUT_REL" ;; *) EDGES="$REPO_ROOT/$EDGE_OUT_REL" ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/graph.XXXXXX")" || exit 64
trap 'rm -rf "$TMP"' EXIT INT TERM

# list_inputs <outfile> <z|n> : tracked files matching PF_EDGE_INPUTS (z = NUL-separated)
list_inputs() {
  [ -n "$INPUTS" ] || { : > "$1"; return 0; }
  set -f
  # shellcheck disable=SC2086
  if [ "$2" = z ]; then git ls-files -z -- $INPUTS > "$1" 2>/dev/null; else git ls-files -- $INPUTS > "$1" 2>/dev/null; fi
  set +f
}

# ── build ────────────────────────────────────────────────────────────────────
cmd_build() {
  [ -n "$EXTRACTORS" ] || die "NOT RUN — profile declares no PF_EDGE_EXTRACTORS"
  [ -n "$INPUTS" ] || die "NOT RUN — profile declares no PF_EDGE_INPUTS"
  git rev-parse --git-dir >/dev/null 2>&1 || die "NOT RUN — $REPO_ROOT is not a git work tree"
  list_inputs "$TMP/files.txt" n
  git ls-files > "$TMP/tracked.txt" 2>/dev/null
  NIN=$(wc -l < "$TMP/files.txt" | tr -d ' ')
  : > "$TMP/all.tsv"
  for name in $EXTRACTORS; do
    case "$name" in *[!A-Za-z0-9_]*|'') die "bad extractor name '$name'" ;; esac
    eval "cmd=\${PF_EDGE_CMD_${name}:-}"
    [ -n "$cmd" ] || die "NOT RUN — extractor '$name' has no PF_EDGE_CMD_$name"
    GRAPH_REPO_ROOT="$REPO_ROOT" GRAPH_KIT_DIR="$KIT_DIR" GRAPH_FILES="$TMP/files.txt" GRAPH_TRACKED="$TMP/tracked.txt" \
      sh -c "$cmd" > "$TMP/ex.$name" 2> "$TMP/ex.$name.err"
    rc=$?
    cat "$TMP/ex.$name.err" >&2
    if [ "$rc" -ne 0 ]; then
      echo "graph: build FAILED — extractor '$name' exited $rc; edge file left untouched" >&2; exit 2
    fi
    bad=$(awk -F'\t' '!(NF==5 && $1!="" && $2!="" && $3!="" && ($4=="EXTRACTED"||$4=="INFERRED"||$4=="AMBIGUOUS") && $5!="")' "$TMP/ex.$name" | head -n 3)
    if [ -n "$bad" ]; then
      echo "graph: build FAILED — extractor '$name' emitted malformed line(s), first: $bad" >&2; exit 2
    fi
    cat "$TMP/ex.$name" >> "$TMP/all.tsv"
  done
  outdir="$(dirname "$EDGES")"
  mkdir -p "$outdir" 2>/dev/null || die "cannot create $outdir"
  NEW="$(mktemp "$outdir/.edges.XXXXXX")" || die "cannot write in $outdir"
  sort -u "$TMP/all.tsv" > "$NEW"
  chmod 644 "$NEW" 2>/dev/null
  mv "$NEW" "$EDGES" || { rm -f "$NEW"; die "cannot move edge file into place"; }
  echo "graph: wrote $EDGES ($NIN input files)"
  awk -F'\t' '{k[$3]++; p[$4]++; n++} END{
    printf "edges: %d\n", n
    for (x in k) printf "  kind %-12s %d\n", x, k[x]
    for (x in p) printf "  provenance %-10s %d\n", x, p[x]
  }' "$EDGES" | LC_ALL=C sort
  return 0
}

# ── common prelude for the queries: edge file present, readable, fresh ───────
# stale_input: prints the first tracked input (or the profile) newer than the edge file
stale_input() {
  newer=""
  list_inputs "$TMP/inputs.z" z
  if [ -s "$TMP/inputs.z" ]; then
    newer=$(GE="$EDGES" xargs -0 sh -c 'find "$@" -newer "$GE" -print 2>/dev/null' sh < "$TMP/inputs.z" | head -n 1)
  fi
  [ -z "$newer" ] && [ "$CONF" -nt "$EDGES" ] && newer="$CONF"
  printf '%s' "$newer"
}
# rebuild_or_exit <why>: run the build once (output swallowed), say so on ONE stderr line.
# The subshell keeps cmd_build's die/exit from ending this process; on failure the
# previous edge file is untouched (cmd_build only renames a finished temp file).
rebuild_or_exit() {
  t0=$(date +%s)
  ( cmd_build ) > /dev/null 2> "$TMP/rebuild.err"; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    cat "$TMP/rebuild.err" >&2
    echo "graph: NOT MEASURED — edge file was $1 and the automatic rebuild failed (exit $rrc); previous file left untouched" >&2; exit 2
  fi
  echo "graph: edge file was $1 — rebuilt in $(( $(date +%s) - t0 ))s" >&2
}
prelude() {
  if [ ! -e "$EDGES" ]; then
    if [ "$NO_REBUILD" = 1 ] || [ "$ALLOW_STALE" = 1 ]; then
      echo "graph: NOT MEASURED — edge file absent ($EDGES); run: graph.sh build" >&2; exit 2
    fi
    rebuild_or_exit absent
  fi
  if [ ! -r "$EDGES" ] || [ ! -f "$EDGES" ]; then echo "graph: NOT MEASURED — edge file unreadable ($EDGES)" >&2; exit 2; fi
  if [ "$ALLOW_STALE" = 0 ]; then
    newer=$(stale_input)
    if [ -n "$newer" ]; then
      if [ "$NO_REBUILD" = 1 ]; then
        echo "graph: NOT MEASURED — edge file older than its inputs (e.g. $newer); run: graph.sh build (or --allow-stale)" >&2; exit 2
      fi
      rebuild_or_exit stale
    fi
  fi
}

# resolve_node <name> <outfile>: candidate nodes (tracked files + edge endpoints)
#   exact path wins; otherwise every node ending in /<name> (so a basename or a path suffix)
resolve_node() {
  { git ls-files 2>/dev/null; awk -F'\t' '$4!="AMBIGUOUS"{print $1; print $2}' "$EDGES"; } | sort -u > "$TMP/nodes"
  GX="${1#./}" awk '
    BEGIN { x = ENVIRON["GX"]; tail = "/" x; tl = length(tail) }
    { if ($0 == x) { ex = $0 }
      else if (length($0) >= tl && substr($0, length($0) - tl + 1) == tail) { m[++n] = $0 } }
    END { if (ex != "") print ex; else for (i = 1; i <= n; i++) print m[i] }' "$TMP/nodes" > "$2"
}

# node_or_exit <name> <outvar>: sets the variable, or exits 3 (several) / 5 (none)
node_or_exit() {
  resolve_node "$1" "$TMP/c.$2"
  nc=$(wc -l < "$TMP/c.$2" | tr -d ' ')
  if [ "$nc" -eq 0 ]; then
    echo "graph: verdict 5 — NOT MEASURED: '$1' is not a node of the graph (typo, or an untracked file)" >&2; exit 5
  fi
  if [ "$nc" -gt 1 ]; then
    if [ "$NODE_QUIET" = 1 ]; then echo "$1: ambiguous name, matches $nc nodes (give a longer path)"
    else
      echo "## AMBIGUOUS: '$1' matches $nc nodes — give a longer path"
      sed 's/^/## candidate /' "$TMP/c.$2"
    fi
    echo "graph: verdict 3 — AMBIGUOUS: '$1' matches $nc nodes" >&2; exit 3
  fi
  eval "$2=\$(cat \"\$TMP/c.$2\")"
}

# ambiguous_for <basename> <outfile>: AMBIGUOUS edges whose raw expression names the basename
ambiguous_for() {
  GB="$1" GK="$KIND" awk -F'\t' 'BEGIN{b=ENVIRON["GB"]; k=ENVIRON["GK"]; kk="," k ","}
    $4=="AMBIGUOUS" && (k=="" || index(kk, "," $3 ",") > 0) && index($2, b) > 0 {print $1 "\t" $2 "\t" $5}' "$EDGES" | sort -u > "$2"
}
count_nameless() {
  GK="$KIND" awk -F'\t' 'BEGIN{k=ENVIRON["GK"]; kk="," k ","} $4=="AMBIGUOUS" && (k=="" || index(kk, "," $3 ",") > 0) && $2 !~ /[.][A-Za-z0-9]+[\047"]/ {n++} END{print n+0}' "$EDGES"
}

# affected_core <node> <depth>: breadth-first walk to $TMP/res, one
#   `path <TAB> kind <TAB> weakest-provenance <TAB> depth` per (file, kind), sorted.
affected_core() {
  GK="$KIND" GS="$1" GD="$2" awk -F'\t' '
    BEGIN { k = ENVIRON["GK"]; kk = "," k ","; start = ENVIRON["GS"]; maxd = ENVIRON["GD"] + 0 }
    $4 == "AMBIGUOUS" { next }
    k != "" && index(kk, "," $3 ",") == 0 { next }
    { n[$2]++; rf[$2, n[$2]] = $1; rp[$2, n[$2]] = $4; rk[$2, n[$2]] = $3 }
    END {
      seen[start] = -1; cn = 1; cur[1] = start; cw[1] = "EXTRACTED"
      for (d = 1; d <= maxd && cn > 0; d++) {
        nn = 0
        for (i = 1; i <= cn; i++) {
          t = cur[i]
          for (j = 1; j <= n[t]; j++) {
            f = rf[t, j]
            if ((f in seen) && seen[f] != d) continue
            key = f SUBSEP rk[t, j]
            if (key in em) continue
            em[key] = 1
            w = (cw[i] == "INFERRED" || rp[t, j] == "INFERRED") ? "INFERRED" : "EXTRACTED"
            if (!(f in seen)) { seen[f] = d; nn++; nxt[nn] = f; nw[nn] = w }
            print f "\t" rk[t, j] "\t" w "\t" d
          }
        }
        for (i = 1; i <= nn; i++) { cur[i] = nxt[i]; cw[i] = nw[i] }
        cn = nn
      }
    }' "$EDGES" | sort > "$TMP/res"
}

cmd_affected() {
  [ -n "$P1" ] || die "affected needs <X>"
  [ -z "$P2" ] || die "affected takes one argument"
  prelude
  node_or_exit "$P1" NODE
  depth="${DEPTH:-1}"
  affected_core "$NODE" "$depth"
  nres=$(wc -l < "$TMP/res" | tr -d ' ')
  head -n "$BUDGET" "$TMP/res"
  [ "$nres" -gt "$BUDGET" ] && echo "## cut: $((nres - BUDGET)) more result(s) beyond --budget $BUDGET"
  ambiguous_for "${NODE##*/}" "$TMP/amb"
  namb=$(wc -l < "$TMP/amb" | tr -d ' ')
  if [ "$namb" -gt 0 ]; then
    echo "## AMBIGUOUS candidates — unresolved edges naming '${NODE##*/}' (from<TAB>raw expression<TAB>source); not certain:"
    head -n "$BUDGET" "$TMP/amb"
    [ "$namb" -gt "$BUDGET" ] && echo "## cut: $((namb - BUDGET)) more candidate(s) beyond --budget $BUDGET"
  fi
  nl=$(count_nameless)
  [ "$nl" -gt 0 ] && echo "graph: note — $nl unresolved edge(s) name no file at all and cannot be tied to '$NODE'" >&2
  if [ "$namb" -gt 0 ]; then
    echo "graph: verdict 3 — AMBIGUOUS: $nres certain result(s) for '$NODE' plus $namb unresolved edge(s) that may concern it" >&2; exit 3
  fi
  if [ "$nres" -gt 0 ]; then
    echo "graph: verdict 0 — $nres result(s) for '$NODE' (depth $depth), all EXTRACTED/INFERRED, no ambiguous edge names it" >&2; exit 0
  fi
  echo "graph: verdict 4 — nothing depends on '$NODE' (depth $depth) and no ambiguous edge names it" >&2; exit 4
}

# summary: the same walk as `affected`, one stdout line, same exit codes
cmd_summary() {
  [ -n "$P1" ] || die "summary needs <X>"
  [ -z "$P2" ] || die "summary takes one argument"
  prelude
  NODE_QUIET=1
  node_or_exit "$P1" NODE
  depth="${DEPTH:-1}"
  affected_core "$NODE" "$depth"
  nres=$(wc -l < "$TMP/res" | tr -d ' ')
  ambiguous_for "${NODE##*/}" "$TMP/amb"
  namb=$(wc -l < "$TMP/amb" | tr -d ' ')
  parts=$(awk -F'\t' '{c[$2]++} END{for (x in c) print x "\t" c[x]}' "$TMP/res" | sort | awk -F'\t' '{printf "%s%d %s", (NR>1 ? ", " : ""), $2, $1}')
  if [ "$namb" -gt 0 ]; then parts="${parts:+$parts, }$namb ambiguous"; fi
  echo "$NODE: ${parts:-no dependents}"
  if [ "$namb" -gt 0 ]; then
    echo "graph: verdict 3 — AMBIGUOUS: $nres certain result(s) for '$NODE' plus $namb unresolved edge(s) that may concern it" >&2; exit 3
  fi
  if [ "$nres" -gt 0 ]; then
    echo "graph: verdict 0 — $nres result(s) for '$NODE' (depth $depth)" >&2; exit 0
  fi
  echo "graph: verdict 4 — nothing depends on '$NODE' (depth $depth) and no ambiguous edge names it" >&2; exit 4
}

cmd_rank() {
  prelude
  GK="$KIND" awk -F'\t' 'BEGIN{k=ENVIRON["GK"]; kk="," k ","}
    k != "" && index(kk, "," $3 ",") == 0 { next }
    $4 == "AMBIGUOUS" { na++; next }
    { c[$2]++ }
    END { for (x in c) print c[x] "\t" x; print "#AMB\t" na + 0 }' "$EDGES" > "$TMP/rk"
  grep -v '^#AMB' "$TMP/rk" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | head -n "$TOP" > "$TMP/rk.top"
  namb=$(awk -F'\t' '$1=="#AMB"{print $2}' "$TMP/rk")
  cat "$TMP/rk.top"
  echo "# AMBIGUOUS edges (not counted above): $namb"
  if [ -s "$TMP/rk.top" ]; then echo "graph: verdict 0 — top $(wc -l < "$TMP/rk.top" | tr -d ' ') by in-degree (EXTRACTED+INFERRED only), $namb AMBIGUOUS edge(s) apart" >&2; exit 0; fi
  echo "graph: verdict 4 — no resolvable edge" >&2; exit 4
}

cmd_path() {
  [ -n "$P1" ] && [ -n "$P2" ] || die "path needs <A> <B>"
  prelude
  node_or_exit "$P1" NA
  node_or_exit "$P2" NB
  depth="${DEPTH:-6}"
  GK="$KIND" GS="$NA" GT="$NB" GD="$depth" awk -F'\t' '
    BEGIN { k = ENVIRON["GK"]; kk = "," k ","; start = ENVIRON["GS"]; goal = ENVIRON["GT"]; maxd = ENVIRON["GD"] + 0 }
    $4 == "AMBIGUOUS" { next }
    k != "" && index(kk, "," $3 ",") == 0 { next }
    { n[$1]++; at[$1, n[$1]] = $2; ap[$1, n[$1]] = $4 }
    END {
      seen[start] = 1; cn = 1; cur[1] = start; found = (start == goal)
      for (d = 1; d <= maxd && cn > 0 && !found; d++) {
        nn = 0
        for (i = 1; i <= cn && !found; i++) {
          t = cur[i]
          for (j = 1; j <= n[t]; j++) {
            f = at[t, j]
            if (f in seen) continue
            seen[f] = 1; par[f] = t; pp[f] = ap[t, j]
            nn++; nxt[nn] = f
            if (f == goal) { found = 1; break }
          }
        }
        for (i = 1; i <= nn; i++) cur[i] = nxt[i]
        cn = nn
      }
      if (!found) exit 1
      m = 0; x = goal
      while (x != start) { m++; hf[m] = par[x]; ht[m] = x; hp[m] = pp[x]; x = par[x] }
      for (i = m; i >= 1; i--) print hf[i] "\t" ht[i] "\t" hp[i]
    }' "$EDGES" > "$TMP/chain"
  arc=$?
  if [ "$arc" -eq 0 ]; then
    cat "$TMP/chain"
    echo "graph: verdict 0 — '$NA' reaches '$NB' in $(wc -l < "$TMP/chain" | tr -d ' ') hop(s), all EXTRACTED/INFERRED" >&2; exit 0
  fi
  ambiguous_for "${NB##*/}" "$TMP/amb"
  namb=$(wc -l < "$TMP/amb" | tr -d ' ')
  if [ "$namb" -gt 0 ]; then
    echo "## AMBIGUOUS candidates — unresolved edges naming '${NB##*/}' (from<TAB>raw expression<TAB>source); a chain through one of them is possible:"
    head -n "$BUDGET" "$TMP/amb"
    echo "graph: verdict 3 — AMBIGUOUS: no certain chain from '$NA' to '$NB' within depth $depth, but $namb unresolved edge(s) name it" >&2; exit 3
  fi
  echo "graph: verdict 4 — no chain from '$NA' to '$NB' within depth $depth and no ambiguous edge names the target" >&2; exit 4
}

case "$CMD" in
  build)    cmd_build ;;
  affected) cmd_affected ;;
  summary)  cmd_summary ;;
  rank)     cmd_rank ;;
  path)     cmd_path ;;
esac
