#!/usr/bin/env bash
# run.sh — PM compliance harness: does the PM model FOLLOW the kernel?
#
# MANUAL tool. It costs API calls: never a hook, never cron. v1 covers the consult kinds
# `question` and `plan` (no writes). See README.md in this directory.
#
#   run.sh --dry-run [scenario...]                 build the sandbox, print the exact `claude`
#                                                  command per scenario, run nothing
#   run.sh [--model M] [--max-turns N] [--timeout S] [--budget USD] [scenario...]
#                                                  LIVE: run each scenario, grade, report
#   run.sh --grade <stream.jsonl> --scenario <file>
#                                                  grade a saved transcript offline (grade.tsv
#                                                  on stdout, summary on stderr)
# Options: --repo <path>      the INSTANCE to test: a repository where pm-kit/init.sh has run, with
#                             the kit at claude-brain/pm-kit/ (default: git toplevel of the cwd)
#          --results <dir>    report directory (default: <here>/results/<timestamp>, gitignored)
#          --spec <file>      step spec (default: <here>/spec.tsv)
#          --keep             keep the sandbox
# A scenario is a name under scenarios/ (question-neutral) or a path.
# Exit: 0 every required step observed in every scenario run; 1 at least one required step
#       not observed; 3 did not run (claude missing, kernel hash differs from the spec's,
#       sandbox build failed, a scenario produced no transcript, or a transcript reached the
#       REAL repo's memory while it changed; a change by another session is a note, not a 3).
#
# Portable to bash 3.2: no associative arrays, no mapfile, no case-conversion expansions,
# no grep -P, no readlink -f. jq is required. No exit code is read through a pipe.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE=live; GSTREAM=""; GSCEN=""; MODEL=""; MAXTURNS=40; MAXTURNS_EXPLICIT=0
TIMEOUT=600; BUDGET=5; REPO=""; RES=""; SPEC="$HERE/spec.tsv"; KEEP=0
SCN_ARGS=()

die3() { echo "run.sh: $*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) MODE=dry ;;
    --grade)    [ $# -ge 2 ] || die3 "--grade needs a stream file"; MODE=grade; GSTREAM="$2"; shift ;;
    --scenario) [ $# -ge 2 ] || die3 "--scenario needs a file"; GSCEN="$2"; shift ;;
    --model)    [ $# -ge 2 ] || die3 "--model needs a value"; MODEL="$2"; shift ;;
    --max-turns) [ $# -ge 2 ] || die3 "--max-turns needs a value"; MAXTURNS="$2"; MAXTURNS_EXPLICIT=1; shift ;;
    --timeout)  [ $# -ge 2 ] || die3 "--timeout needs a value"; TIMEOUT="$2"; shift ;;
    --budget)   [ $# -ge 2 ] || die3 "--budget needs a value"; BUDGET="$2"; shift ;;
    --repo)     [ $# -ge 2 ] || die3 "--repo needs a path"; REPO="$2"; shift ;;
    --results)  [ $# -ge 2 ] || die3 "--results needs a path"; RES="$2"; shift ;;
    --spec)     [ $# -ge 2 ] || die3 "--spec needs a file"; SPEC="$2"; shift ;;
    --keep)     KEEP=1 ;;
    -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
    -*)         die3 "unknown option: $1" ;;
    *)          SCN_ARGS+=("$1") ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || die3 "jq is required"
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO=""
  [ -n "$REPO" ] || REPO="$(cd "$HERE" && git rev-parse --show-toplevel 2>/dev/null)" || REPO=""
fi
[ -n "$REPO" ] && [ -d "$REPO" ] || die3 "no repository: pass --repo <path>"
REPO="$(cd "$REPO" && pwd)"
PROTOCOL="$REPO/claude-brain/pm-kit/PROTOCOL.md"
[ -f "$PROTOCOL" ] || die3 "no kit at $PROTOCOL — --repo must be an instance where pm-kit/init.sh has run (the kit itself is not one)"
# The instance's paths come from claude-brain/pm-kit.conf (PM_AGENT_CANONICAL, PM_INDEX,
# PM_MEMORY_DIR). Sourced in a subshell, as doctor.sh does, with REPO_ROOT / KIT_DIR set first.
CONF="$REPO/claude-brain/pm-kit.conf"
AGENT=""; MEMFILE=""; LAYOUT_NOTE=""
if [ -f "$CONF" ]; then
  # mktemp, not $$: a predictable name can be pre-created by someone else.
  CONF_OUT="$(mktemp "${TMPDIR:-/tmp}/comply-conf.XXXXXX")" || die3 "mktemp failed"
  # shellcheck disable=SC2034  # REPO_ROOT and KIT_DIR are read by the conf this subshell sources
  ( REPO_ROOT="$REPO"; KIT_DIR="$REPO/claude-brain/pm-kit"; PM_AGENT_CANONICAL=""; PM_INDEX=""
    # shellcheck disable=SC1090
    . "$CONF" > /dev/null 2>&1
    printf '%s\t%s\n' "$PM_AGENT_CANONICAL" "$PM_INDEX" ) > "$CONF_OUT" 2>/dev/null
  IFS="$(printf '\t')" read -r AGENT MEMFILE < "$CONF_OUT"
  rm -f "$CONF_OUT"
  LAYOUT_NOTE="paths read from $CONF"
else
  # No pm-kit.conf: fall back to the skeleton layout claude-brain/agents/<name>-pm.md, and say so.
  set -- "$REPO"/claude-brain/agents/*-pm.md
  [ $# -eq 1 ] && [ -f "$1" ] || die3 "no claude-brain/pm-kit.conf and not exactly one claude-brain/agents/*-pm.md: cannot find the agent file"
  AGENT="$1"; MEMFILE="${AGENT%.md}-memory.md"
  LAYOUT_NOTE="NO pm-kit.conf at $CONF: using the skeleton layout (claude-brain/agents/<name>-pm.md)"
  echo "run.sh: $LAYOUT_NOTE" >&2
fi
[ -n "$AGENT" ] && [ -n "$MEMFILE" ] || die3 "pm-kit.conf does not set PM_AGENT_CANONICAL and PM_INDEX"
for f in "$PROTOCOL" "$AGENT" "$MEMFILE" "$SPEC" "$HERE/grade.jq"; do [ -f "$f" ] || die3 "missing file: $f"; done
# The agent name is the frontmatter `name:` of the canonical file, never a constant.
AGENT_NAME="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && /^name:/ {sub(/^name:[ ]*/,""); gsub(/["\r]/,""); print; exit}' "$AGENT")"
[ -n "$AGENT_NAME" ] || die3 "the agent file $AGENT has no frontmatter 'name:'"
case "$AGENT_NAME" in *[!A-Za-z0-9._-]*) die3 "unsafe agent name '$AGENT_NAME'" ;; esac
# Where the memory lives, repo-relative, for the real-repo fingerprint.
MEM_REL="$(dirname "${MEMFILE#"$REPO"/}")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/comply.XXXXXX")" || die3 "mktemp failed"
SB=""
cleanup() {
  [ -n "$SB" ] && [ "$KEEP" = 0 ] && [ "$SB" != "$REPO" ] && rm -rf "$SB" "${SB}-origin.git"
  [ -n "$SB" ] && [ "$KEEP" = 1 ] && echo "run.sh: sandbox kept at $SB (its local origin: ${SB}-origin.git)" >&2
  rm -rf "$TMP"
}
trap cleanup EXIT

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
kernel_block() { awk '/^<!-- cellarman kernel: begin/{k=1} k; /^<!-- cellarman kernel: end/{k=0}' "$1"; }
kernel_hash() { kernel_block "$1" > "$TMP/kb"; [ -s "$TMP/kb" ] || { echo "none"; return; }; sha256 < "$TMP/kb"; }

# ---- the kernel-hash rule: spec, PROTOCOL.md and the agent file must carry the same kernel
SPEC_HASH="$(sed -n 's/^# kernel-sha256:[ ]*//p' "$SPEC" | head -n 1)"
SPEC_KINDS="$(sed -n 's/^# kinds:[ ]*//p' "$SPEC" | head -n 1)"
[ -n "$SPEC_HASH" ] || die3 "spec has no '# kernel-sha256:' header"
PROTO_HASH="$(kernel_hash "$PROTOCOL")"
AGENT_HASH="$(kernel_hash "$AGENT")"
[ "$PROTO_HASH" = "$SPEC_HASH" ] || die3 "kernel hash mismatch: spec $SPEC_HASH, PROTOCOL.md $PROTO_HASH — re-read the kernel changes and re-baseline the spec"
[ "$AGENT_HASH" = "$SPEC_HASH" ] || die3 "kernel hash mismatch: spec $SPEC_HASH, agent file $AGENT_HASH — the agent under test is not the kernel the spec was written for"

# ---- bindings: the first backticked value of each row of the table after the kernel
awk '/^<!-- cellarman kernel: end/{k=1} k && /^\| `[$][{][A-Z_]+[}]` \| /{
       name=$0; sub(/^\| `[$][{]/,"",name); sub(/[}]`.*/,"",name);
       rest=$0; sub(/^\| `[$][{][A-Z_]+[}]` \| /,"",rest);
       if (match(rest,/`[^`]*`/)) print name "\t" substr(rest,RSTART+1,RLENGTH-2) }' "$AGENT" > "$TMP/tokens.tsv"
jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' "$TMP/tokens.tsv" > "$TMP/tokens.json" || die3 "could not read the bindings table of $AGENT"
for t in PREFLIGHT_CMD PM_INDEX MEMORY_DIR RAILS_INDEX SHIPPED_INDEX; do
  jq -e --arg t "$t" 'has($t)' "$TMP/tokens.json" >/dev/null 2>&1 || die3 "the bindings table of the agent file has no row for \${$t}"
done

# ---- the spec as JSON
jq -Rn '[inputs | select(length > 0 and (startswith("#") | not)) | split("\t")
         | if length != 6 then error("spec row with \(length) fields: \(.[0])")
           else {id: .[0], kinds: .[1], required: .[2], after: .[3], detector: .[4], desc: .[5]} end]' "$SPEC" > "$TMP/spec.json" 2> "$TMP/spec.err" \
  || die3 "unreadable spec: $(cat "$TMP/spec.err")"

# ---- scenarios
resolve_scenario() {
  if [ -f "$HERE/scenarios/$1.txt" ]; then echo "$HERE/scenarios/$1.txt"
  elif [ -f "$1" ]; then echo "$1"
  else echo ""; fi
}
load_scenario() { # <file> <prompt-out>
  S_NAME="$(basename "$1" .txt)"
  S_KIND="$(sed -n '1,/^$/s/^kind:[ ]*//p' "$1" | head -n 1)"
  S_LEVEL="$(sed -n '1,/^$/s/^level:[ ]*//p' "$1" | head -n 1)"
  S_FILES="$(sed -n '1,/^$/s/^files:[ ]*//p' "$1" | head -n 1)"
  awk 'b{print} !b && /^$/{b=1}' "$1" > "$2"
  [ -n "$S_KIND" ] || die3 "scenario $1 has no 'kind:' header"
  case " $SPEC_KINDS " in *" $S_KIND "*) ;; *) die3 "scenario $S_NAME is kind '$S_KIND', which the spec does not cover (spec kinds: $SPEC_KINDS)" ;; esac
}

# ---- transcript -> {calls, final}
extract_stream() { # <stream> <out.json>
  jq -nR '[inputs | fromjson?] as $r
    | [ $r[] | select(.type == "assistant") | (.message.content // [])[]? | select(.type == "tool_use") | {name: .name, input: (.input // {})} ] as $t
    | ($r | map(select(.type == "result" and ((.result | type) == "string") and ((.result | length) > 0))) | last | .result) as $res
    | ([ $r[] | select(.type == "assistant") | (.message.content // [])[]? | select(.type == "text") | .text ] | last) as $lt
    | {calls: ($t | to_entries | map(.value + {n: (.key + 1)})), final: ($res // $lt // ""), records: ($r | length)}' "$1" > "$2"
}

# ---- grade one transcript: writes <outdir>/grade.json and grade.tsv ; sets REQ_TOTAL REQ_OBS
REQ_TOTAL=0; REQ_OBS=0
grade_one() { # <stream> <outdir> <scenario-name> <kind> <level> <files>
  local stream="$1" out="$2" name="$3" kind="$4" level="$5" files="$6"
  extract_stream "$stream" "$TMP/ex.json" || return 3
  jq -nc --arg f "$files" '$f | split(" ") | map(select(length > 0))' > "$TMP/files.json"
  jq -n --argjson calls "$(jq -c .calls "$TMP/ex.json")" --argjson final "$(jq -c .final "$TMP/ex.json")" \
        --argjson files "$(cat "$TMP/files.json")" --arg kind "$kind" \
        --argjson steps "$(cat "$TMP/spec.json")" --argjson tokens "$(cat "$TMP/tokens.json")" \
        -f "$HERE/grade.jq" > "$TMP/g.json" 2> "$TMP/g.err" || { echo "run.sh: grader failed: $(cat "$TMP/g.err")" >&2; return 3; }
  jq --arg s "$name" --arg k "$kind" --arg l "$level" '. + {scenario: $s, kind: $k, level: $l}' "$TMP/g.json" > "$out/grade.json"
  jq -r '(["step","required","observed","evidence"] | @tsv),
         (.rows[] | [.id, (if .status == "n/a" then "n/a" elif .required then "required" else "optional" end), .status, .evidence] | @tsv)' \
     "$out/grade.json" > "$out/grade.tsv"
  REQ_TOTAL="$(jq -r .req_total "$out/grade.json")"; REQ_OBS="$(jq -r .req_observed "$out/grade.json")"
  return 0
}

# ============================================================== --grade mode
if [ "$MODE" = grade ]; then
  [ -f "$GSTREAM" ] || die3 "no such transcript: $GSTREAM"
  [ -n "$GSCEN" ] || die3 "--grade needs --scenario <file>"
  SF="$(resolve_scenario "$GSCEN")"; [ -n "$SF" ] || die3 "no such scenario: $GSCEN"
  load_scenario "$SF" "$TMP/prompt.txt"
  mkdir -p "$TMP/o"
  grade_one "$GSTREAM" "$TMP/o" "$S_NAME" "$S_KIND" "$S_LEVEL" "$S_FILES" || die3 "grading failed"
  cat "$TMP/o/grade.tsv"
  echo "compliance: $REQ_OBS/$REQ_TOTAL required steps observed ($S_NAME; a step not observed is not a proven violation)" >&2
  [ "$REQ_OBS" = "$REQ_TOTAL" ] && exit 0
  exit 1
fi

# ============================================================== dry-run / live
SCN_FILES=()
if [ ${#SCN_ARGS[@]} -eq 0 ]; then
  for f in "$HERE"/scenarios/*.txt; do
    [ -f "$f" ] || continue
    if sed -n '1,/^$/p' "$f" | grep -q '^enabled:[ ]*no'; then continue; fi
    SCN_FILES+=("$f")
  done
else
  for a in "${SCN_ARGS[@]}"; do
    f="$(resolve_scenario "$a")"; [ -n "$f" ] || die3 "no such scenario: $a"
    if sed -n '1,/^$/p' "$f" | grep -q '^enabled:[ ]*no'; then die3 "scenario $a is disabled (v2 stub)"; fi
    SCN_FILES+=("$f")
  done
fi
[ ${#SCN_FILES[@]} -gt 0 ] || die3 "no scenario to run"

TS="$(date +%Y%m%dT%H%M%S)"
if [ -z "$RES" ]; then
  if [ "$MODE" = dry ]; then RES="$TMP/results"; else RES="$HERE/results/$TS"; fi
fi
mkdir -p "$RES/stub" || die3 "cannot create $RES"
RES="$(cd "$RES" && pwd)"

CLAUDE_OK=1; command -v claude >/dev/null 2>&1 || CLAUDE_OK=0
if [ "$MODE" = live ] && [ "$CLAUDE_OK" = 0 ]; then die3 "claude is not on PATH"; fi
USE_MAXTURNS=1
if [ "$CLAUDE_OK" = 1 ] && [ "$MAXTURNS_EXPLICIT" = 0 ]; then
  claude --help > "$TMP/claude-help.txt" 2>&1
  grep -q -- '--max-turns' "$TMP/claude-help.txt" || USE_MAXTURNS=0
fi

# ---- isolated ssh/scp stubs, recorded
for s in ssh scp; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/ssh-stub.rec"\necho "comply: %s is stubbed in the harness" >&2\nexit 1\n' "$s" "$RES" "$s" > "$RES/stub/$s"
  chmod +x "$RES/stub/$s"
done
: > "$RES/ssh-stub.rec"

# ---- sandbox: archive of the repo's HEAD, one commit, a LOCAL bare origin at the same commit
SB="$(mktemp -d "${TMPDIR:-/tmp}/comply-sb.XXXXXX")" || die3 "mktemp failed"
SB="$(cd "$SB" && pwd)"
[ "$SB" != "$REPO" ] || die3 "sandbox equals the real repo"
git -C "$REPO" archive HEAD -o "$TMP/head.tar" 2> "$TMP/archive.err" || die3 "git archive failed: $(cat "$TMP/archive.err")"
tar -xf "$TMP/head.tar" -C "$SB" || die3 "tar extraction failed"
rm -f "$TMP/head.tar"
mkdir -p "$SB/.claude/agents"
cp "$AGENT" "$SB/.claude/agents/$AGENT_NAME.md" || die3 "cannot install the agent definition in the sandbox"
export GIT_AUTHOR_NAME=Comply GIT_AUTHOR_EMAIL=comply@example.invalid GIT_COMMITTER_NAME=Comply GIT_COMMITTER_EMAIL=comply@example.invalid
git -C "$SB" init -q > "$TMP/git.out" 2>&1 || die3 "sandbox git init failed"
git -C "$SB" symbolic-ref HEAD refs/heads/main
git -C "$SB" add -A > "$TMP/git.out" 2>&1 || die3 "sandbox git add failed"
git -C "$SB" commit -q -m "comply sandbox snapshot" > "$TMP/git.out" 2>&1 || die3 "sandbox commit failed: $(cat "$TMP/git.out")"
# The sandbox's `origin` is a throwaway LOCAL bare repository holding the same snapshot, so the
# pre-flight's upstream check measures "level with origin/main" instead of raising a STOP for a
# missing ref — measured 2026-10-06: without it every run exits 2 on `upstream`, the kernel says
# not to plan on a STOP, and the plan scenarios never reach Steps 1-2. A push from the PM lands in
# that bare repo (harmless) and is still caught by the no_remote detector. Nothing network-shaped.
ORIGIN="${SB}-origin.git"
git init -q --bare "$ORIGIN" > "$TMP/git.out" 2>&1 || die3 "sandbox origin init failed"
git -C "$SB" remote add origin "$ORIGIN" || die3 "cannot add the sandbox origin"
git -C "$SB" push -q origin main > "$TMP/git.out" 2>&1 || die3 "sandbox push to its local origin failed: $(cat "$TMP/git.out")"
git -C "$SB" remote get-url origin > "$TMP/remote.out" 2>&1
case "$(cat "$TMP/remote.out")" in "$ORIGIN") ;; *) die3 "the sandbox's remote is not its local bare repo: $(cat "$TMP/remote.out")" ;; esac
git -C "$SB" rev-parse --verify -q refs/remotes/origin/main > /dev/null || die3 "the sandbox has no origin/main ref"
# If the instance carries a hooks directory, arm it as a real clone's would be, so the pre-flight's
# core.hooksPath check is not a WARN here (it looks only when the directory exists).
[ -d "$SB/.githooks" ] && git -C "$SB" config core.hooksPath .githooks
SB_HEAD="$(git -C "$SB" rev-parse --short HEAD)"
SRC_HEAD="$(git -C "$REPO" rev-parse --short HEAD)"

# ---- the agent definition as an inline --agents file (frontmatter + body), the highest-priority source
AGENT_JSON="$RES/agents.json"
awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; body=1; next} body {print}' "$AGENT" > "$TMP/agent.body"
A_DESC="$(sed -n '1,/^---$/{/^description:/p}' "$AGENT" | head -n 1 | sed -e 's/^description:[ ]*//' -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')"
A_TOOLS="$(sed -n '1,/^---$/{/^tools:/p}' "$AGENT" | head -n 1 | sed 's/^tools:[ ]*//')"
A_MODEL="$(sed -n '1,/^---$/{/^model:/p}' "$AGENT" | head -n 1 | sed 's/^model:[ ]*//')"
[ -z "$MODEL" ] || A_MODEL="$MODEL"
jq -n --arg n "$AGENT_NAME" --arg d "$A_DESC" --arg t "$A_TOOLS" --arg m "$A_MODEL" --rawfile p "$TMP/agent.body" \
  '{($n): ({description: $d, prompt: $p, tools: ($t | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0)))} + (if $m == "" then {} else {model: $m} end))}' > "$AGENT_JSON" \
  || die3 "could not build the inline agent definition"

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---- the command, as an argument array (everything after the prompt)
CMD_TAIL=()
build_tail() {
  CMD_TAIL=(--agent "$AGENT_NAME" --agents "$AGENT_JSON" --output-format stream-json --verbose)
  [ "$USE_MAXTURNS" = 1 ] && CMD_TAIL+=(--max-turns "$MAXTURNS")
  CMD_TAIL+=(--max-budget-usd "$BUDGET" --no-session-persistence --settings '{"disableAllHooks":true}')
  [ -z "$MODEL" ] || CMD_TAIL+=(--model "$MODEL")
  CMD_TAIL+=(--allowedTools "Read,Grep,Glob,Bash")
}
build_tail
CMD_STR="claude -p \"\$(cat PROMPT_FILE)\""
for a in "${CMD_TAIL[@]}"; do CMD_STR="$CMD_STR $(shq "$a")"; done
case "$CMD_STR" in *disableAllHooks*) ;; *) die3 "internal: the command lacks disableAllHooks" ;; esac
case "$CMD_STR" in *--allowedTools*) ;; *) die3 "internal: the command lacks --allowedTools" ;; esac

# ---- the real repo's memory fingerprint (before / after)
real_fp() { # <out>
  {
    printf 'memory-sha256 %s\n' "$(sha256 < "$MEMFILE")"
    git -C "$REPO" status --porcelain -uall -- "$MEM_REL/" > "$TMP/fp.status" 2>&1
    cat "$TMP/fp.status"
    sed 's/^...//' "$TMP/fp.status" | while IFS= read -r p; do
      [ -f "$REPO/$p" ] && printf 'cksum %s %s\n' "$(cksum < "$REPO/$p" | cut -d' ' -f1,2)" "$p"
    done
  } > "$1"
}

if [ "$MODE" = dry ]; then
  echo "comply --dry-run: nothing is run."
  echo "repo:     $REPO (HEAD $SRC_HEAD; agent \"$AGENT_NAME\"; $LAYOUT_NOTE)"
  echo "sandbox:  $SB (HEAD $SB_HEAD; origin = local bare ${SB}-origin.git, level with it, core.hooksPath set if the instance has .githooks)"
  echo "agents:   $AGENT_JSON (inline definition built from $AGENT)"
  echo "note:     the sandbox and the paths below are removed when this command exits (--keep keeps the sandbox)"
  echo "env:      PM_OFFLINE=1 PATH=$RES/stub:\$PATH (ssh/scp stubs record to $RES/ssh-stub.rec), cwd = the sandbox"
  echo "timeout:  ${TIMEOUT}s per scenario; max-turns ${MAXTURNS} $( [ "$USE_MAXTURNS" = 1 ] && echo '(passed)' || echo '(NOT passed: this claude does not list --max-turns in --help; pass --max-turns N to force it)' )"
  echo
  for sf in "${SCN_FILES[@]}"; do
    load_scenario "$sf" "$RES/$(basename "$sf" .txt).prompt.txt"
    echo "# $S_NAME  (kind=$S_KIND level=$S_LEVEL files=${S_FILES:-none})"
    echo "(cd $(shq "$SB") && env PM_OFFLINE=1 PATH=$(shq "$RES/stub"):\"\$PATH\" ${CMD_STR//PROMPT_FILE/$(shq "$RES/$S_NAME.prompt.txt")})"
    echo
  done
  exit 0
fi

# ============================================================== live
real_fp "$RES/real-before.txt"
echo "$(date +%Y-%m-%dT%H:%M:%S) comply live run, repo $REPO HEAD $SRC_HEAD, kernel $SPEC_HASH" > "$RES/run.log"
ANY_FAIL=0; NORUN=0
for sf in "${SCN_FILES[@]}"; do
  load_scenario "$sf" "$TMP/p.txt"
  OUT="$RES/$S_NAME"; mkdir -p "$OUT"; cp "$TMP/p.txt" "$OUT/prompt.txt"
  git -C "$SB" reset -q --hard HEAD; git -C "$SB" clean -fdxq
  echo "comply: running $S_NAME ..." >&2
  PROMPT="$(cat "$OUT/prompt.txt")"
  ( cd "$SB" && PM_OFFLINE=1 PATH="$RES/stub:$PATH" exec claude -p "$PROMPT" "${CMD_TAIL[@]}" ) > "$OUT/stream.jsonl" 2> "$OUT/stderr.txt" &
  CPID=$!
  ( i=0; while [ "$i" -lt "$TIMEOUT" ]; do sleep 1; kill -0 "$CPID" 2>/dev/null || exit 0; i=$((i+1)); done; kill "$CPID" 2>/dev/null ) > /dev/null 2>&1 &
  WPID=$!
  wait "$CPID"; CRC=$?
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  echo "$S_NAME claude-rc=$CRC" >> "$RES/run.log"
  if ! jq -nRe '[inputs | fromjson? | select(.type == "assistant")] | length > 0' "$OUT/stream.jsonl" > /dev/null 2>&1; then
    echo "run.sh: $S_NAME produced no assistant message (claude rc=$CRC). stderr:" >&2
    head -n 20 "$OUT/stderr.txt" >&2
    NORUN=1; break
  fi
  grade_one "$OUT/stream.jsonl" "$OUT" "$S_NAME" "$S_KIND" "$S_LEVEL" "$S_FILES" || { NORUN=1; break; }
  [ "$CRC" = 0 ] || echo "note: $S_NAME ended with claude rc=$CRC (143 = killed by the ${TIMEOUT}s timeout; the transcript is graded as far as it goes)" >> "$RES/run.log"
  [ "$REQ_OBS" = "$REQ_TOTAL" ] || ANY_FAIL=1
done

# ---- summary
{
  echo "# PM compliance run $TS"
  echo
  echo "- repo: $REPO (HEAD $SRC_HEAD); sandbox snapshot $SB_HEAD; kernel sha256 $SPEC_HASH"
  echo "- claude: $(claude --version 2>/dev/null | head -n 1); model: ${A_MODEL:-agent default}; max-turns: $( [ "$USE_MAXTURNS" = 1 ] && echo "$MAXTURNS" || echo 'not passed' ); timeout ${TIMEOUT}s"
  echo "- hooks disabled for the run (--settings '{\"disableAllHooks\":true}'): the project's and the user's hooks (pm-sync, a bash guard) did NOT run, so these results measure the model's own habits"
  if [ -s "$RES/ssh-stub.rec" ]; then echo "- ssh/scp stub record: NOT EMPTY ($(wc -l < "$RES/ssh-stub.rec" | tr -d ' ') call(s)) — see ssh-stub.rec"; else echo "- ssh/scp stub record: empty"; fi
  echo "- one run is one sample; 'NO' means not observed by a literal detector, not proven violated"
  echo
  GL=""; for sf in "${SCN_FILES[@]}"; do g="$RES/$(basename "$sf" .txt)/grade.json"; [ -f "$g" ] && GL="$GL $g"; done
  if [ -n "$GL" ]; then
    # shellcheck disable=SC2086
    jq -rs '(.[0].rows | map(.id)) as $ids
      | "| scenario | " + ($ids | join(" | ")) + " | required observed | rate |",
        "|---|" + ($ids | map("---") | join("|")) + "|---|---|",
        (.[] | "| \(.scenario) | "
           + (.rows | map(if .status == "yes" then "yes" elif .status == "n/a" then "-" elif .required then "NO" else "no" end) | join(" | "))
           + " | \(.req_observed)/\(.req_total) | "
           + (if .req_total > 0 then (((.req_observed * 100 / .req_total) | floor | tostring) + "%") else "n/a" end) + " |")' $GL
  fi
} > "$RES/summary.md"
cat "$RES/summary.md"

real_fp "$RES/real-after.txt"
if ! cmp -s "$RES/real-before.txt" "$RES/real-after.txt"; then
  diff -u "$RES/real-before.txt" "$RES/real-after.txt" > "$RES/real-repo-diff.txt"
  # Who moved it? A PM under test can only reach the real memory through an ABSOLUTE path
  # (the real repo, ~/.claude, $HOME/.claude): every legitimate call in the sandbox is relative
  # or under the sandbox. Grep every tool input of every transcript for such a path. A hit is
  # exit 3 (the sandbox leaked). No hit means another session wrote the memory during the run
  # (the usual case in working hours — measured 2026-10-06, a parallel report-back) and the
  # grades stand: say so, name the diff, and keep the measured exit code.
  : > "$RES/real-repo-suspects.txt"
  # The real path as a pattern: metacharacters escaped, and every / matching a RUN of
  # slashes. A transcript spells the path as the caller typed it, and a TMPDIR with a
  # trailing slash (macOS) gives mktemp paths with "//", while $REPO went through cd/pwd.
  REPO_RE="$(printf '%s\n' "$REPO" | sed -e 's/[][\.*^$+?(){}|]/\\&/g' -e 's,/,/+,g')"
  for sf in "${SCN_FILES[@]}"; do
    st="$RES/$(basename "$sf" .txt)/stream.jsonl"; [ -f "$st" ] || continue
    # shellcheck disable=SC2088  # a literal ~ in the transcript text is what is searched for
    jq -r --arg s "$(basename "$sf" .txt)" '
        select(.type == "assistant") | (.message.content // [])[]? | select(.type == "tool_use")
        | "\($s)\t\(.name)\t\(.input | tojson)"' "$st" 2>/dev/null \
      | grep -E -e "$REPO_RE" -e '~/\.claude' -e 'HOME[}]?/\.claude' -e '/home/[^/"]+/\.claude' -e '/Users/[^/"]+/\.claude' \
      | cut -c1-300 >> "$RES/real-repo-suspects.txt"
  done
  if [ -s "$RES/real-repo-suspects.txt" ]; then
    echo "run.sh: THE REAL REPO'S MEMORY CHANGED DURING THE RUN and a transcript reaches outside the sandbox (real-repo-suspects.txt). Diff:" >&2
    cat "$RES/real-repo-diff.txt" >&2
    echo "suspect tool calls:" >&2; cat "$RES/real-repo-suspects.txt" >&2
    exit 3
  fi
  echo "run.sh: note — the real repo's memory changed during the run but no transcript names a path outside the sandbox: another session wrote it (see real-repo-diff.txt). The grades stand." >&2
  echo "- real memory changed during the run by ANOTHER writer (no transcript names an outside path); see real-repo-diff.txt" >> "$RES/summary.md"
fi
[ "$NORUN" = 0 ] || exit 3
[ "$ANY_FAIL" = 0 ] && exit 0
exit 1
