#!/usr/bin/env bash
# pm-preflight.sh — the clash detector a PM runs BEFORE it sequences anything,
# and before any build agent is dispatched. Portable kernel: carries no project
# nouns — see profiles/*.conf for those, and the profile-discovery block below.
#
# WHY THIS EXISTS
#   Every cross-dev incident had the same shape: the correct rule was written
#   down, in prose, in a file somebody had to remember to read — and nothing
#   evaluated the rule against the actual state at the moment it mattered. This
#   script evaluates them. It is the executable half of rails that otherwise
#   exist only as words in a project's PM memory.
#
# DESIGN CONSTRAINTS (learned the hard way)
#   - MUST run on macOS bash 3.2 as well as Linux bash 5. No associative arrays,
#     no mapfile, no ${x,,}, no `date -Is`, no `grep -P`, no `readlink -f`.
#     Empty arrays are always expanded as ${a[@]+"${a[@]}"}.
#   - MUST NOT write anything outside $TMPDIR. It is a read-only instrument.
#   - MUST distinguish WARN from STOP. Everything else in this toolchain exits 0
#     with a warning nobody reads; that pattern is the bug, not the baseline.
#
# EXIT CODES  (the whole point — a checker that cannot stop a session is decoration)
#   0  clear
#   1  warnings only — proceed, but the consult must name them
#   2  STOP — the PM must not sequence the build until a human resolves it
#   3  DID NOT RUN — nothing was measured: no profile, a bad argument, a missing
#      tool (git/awk/sed/grep/find) or an unusable repo root. 0/1/2 are verdicts;
#      any other code means no verdict exists. The launcher (bin/pm-preflight.sh)
#      passes every code through and uses 3 for its own failure to find the kernel.
#   Phases that run but cannot reach their target print an `unmeasured` line
#   (counted separately in the summary). That keeps exit 1 unless the target is
#   undeclared (then the phase prints n/a and nothing changes).
#
# USAGE
#   pm-preflight.sh                                  # repo-wide pre-flight
#   pm-preflight.sh --paths src/billing.php app/db.php
#   pm-preflight.sh --migrations db/migrations/_draft/foo.sql
#   pm-preflight.sh --probe-db                       # + live deploy-target/schema probes
#   pm-preflight.sh --no-fetch                       # skip network (offline)
#   pm-preflight.sh --json                           # machine-readable summary
#   pm-preflight.sh --paths -- --odd-name.php        # `--` ends the option list: every
#                                                    # later word is a path, even if it
#                                                    # starts with --
#
# PORTABILITY (this file carries ZERO project nouns — see profiles/*.conf)
#   Repo root, in order:
#     1. $PM_REPO_ROOT if the environment provides it
#     2. `git rev-parse --show-toplevel` run FROM THE CALLER'S CWD
#     3. fallback: the kernel dir's grandparent-of-grandparent (works only
#        when this file still lives at <repo>/claude-brain/pm-kit/kernel/) —
#        printed as an explicit WARNING, never silent.
#   Profile (the file supplying every project noun), in order:
#     1. --conf <path>
#     2. $PM_PROFILE — a path if the file exists at that exact path, else
#        treated as a bare profile NAME resolved under the kit's profiles/ dir
#     3. <repo-root>/claude-brain/pm-kit/profiles/*.conf — used only if
#        EXACTLY ONE match
#     4. a *.conf sitting next to this script (kernel/*.conf) — used only if
#        EXACTLY ONE match
#   No profile found ⇒ did not run (exit 3). This tool has no meaning without one.

# Started by another shell (zsh, sh)? These scripts use bash-only expansions
# (e.g. ${VAR:+-flag "$VAR"} word-splitting) — re-exec under bash, never degrade.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

# A missing tool means nothing below can be trusted: say so and do not run
# (exit 3), rather than let each phase swallow its own command-not-found.
for _t in git awk sed grep find mktemp sort comm; do
  command -v "$_t" >/dev/null 2>&1 || { echo "pm-preflight: NOT RUN — required tool '$_t' not found on PATH" >&2; exit 3; }
done

# ── locate ──────────────────────────────────────────────────────────────────────
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=""

if [ -n "${PM_REPO_ROOT:-}" ]; then
  REPO_ROOT="$PM_REPO_ROOT"
elif REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO_ROOT" ]; then
  :
else
  REPO_ROOT="$(cd "$KIT_DIR/../../.." && pwd)"
  echo "pm-preflight: WARNING no \$PM_REPO_ROOT and cwd is not inside a git repo — falling back to the kernel's grandparent-of-grandparent ($REPO_ROOT). This is only correct if the kernel still lives at <repo>/claude-brain/pm-kit/kernel/." >&2
fi

DO_FETCH=1; DO_PROBE=0; DO_JSON=0
# PM_OFFLINE=1: nothing here may open a network connection or contact a remote
# host. Every leg that would (git fetch, the deploy-target leg, the live schema
# probe) is skipped and reported UNMEASURED with the text "offline (PM_OFFLINE=1)":
# a skipped leg is never printed as ok, and never as a finding either.
OFFLINE=0; [ "${PM_OFFLINE:-}" = 1 ] && OFFLINE=1
PATHS=(); MIGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --conf)       [ $# -ge 2 ] && [ -n "$2" ] || { echo "pm-preflight: --conf needs a value" >&2; exit 3; }; CONF="$2"; shift 2 ;;
    --no-fetch)   DO_FETCH=0; shift ;;
    --probe-db)   DO_PROBE=1; shift ;;
    --json)       DO_JSON=1; shift ;;
    --paths)      shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do PATHS[${#PATHS[@]}]="$1"; shift; done ;;
    --)           shift; while [ $# -gt 0 ]; do PATHS[${#PATHS[@]}]="$1"; shift; done ;;
    --migrations) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do MIGS[${#MIGS[@]}]="$1"; shift; done ;;
    -h|--help)    awk 'NR==1{next} /^#/{print;next} {exit}' "$0"; exit 0 ;;
    *) echo "pm-preflight: unknown arg '$1'" >&2; exit 3 ;;
  esac
done

# ── profile discovery (see header) ─────────────────────────────────────────────
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

if [ -n "$CONF" ] && [ ! -f "$CONF" ]; then
  echo "pm-preflight: NOT RUN — --conf '$CONF' does not exist (a profile named explicitly is never replaced by discovery)." >&2
  exit 3
fi
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "pm-preflight: NOT RUN — no profile found (--conf, \$PM_PROFILE, a single claude-brain/pm-kit/profiles/*.conf, or a single kernel/*.conf). This kernel carries no project nouns of its own and cannot run without one." >&2
  exit 3
fi

# shellcheck disable=SC1090
. "$CONF"

# ── profile → internal working variables ───────────────────────────────────────
# The profile speaks its own PF_*/PM_* vocabulary (see profiles/*.conf); this is
# the ONE place that vocabulary is translated into the names the checks below
# use. Keeping the mapping here (not scattered through the checks) is what lets
# the checks stay noun-free.
: "${UPSTREAM:=${PF_REF_NAME:-}}"
: "${MIG_DIR:=${PF_QUEUE_DIR:-}}"
: "${DRAFT_DIR:=${PF_QUEUE_STAGING:-}}"
: "${HANDOFF:=${PF_ARB_FILE:-}}"
: "${OWNERSHIP_MAP:=${PF_OWNERSHIP_MAP:-}}"
: "${SCRAPPING:=${PF_DEBT_FILE:-}}"
: "${DOCTOR:=${PM_DOCTOR:-}}"
: "${SSH_TARGET:=${PF_TARGET_HOST:-}}"
: "${QUEUE_TARGET_CMD:=${PF_QUEUE_TARGET:-}}"
: "${TARGET_PATH:=${PF_TARGET_PATH:-}}"
: "${DB_SCHEMA:=${PF_DB_SCHEMA:-}}"
: "${ARB_WARN_DAYS:=${PF_ARB_WARN_DAYS:-3}}"
: "${ARB_STOP_DAYS:=${PF_ARB_STOP_DAYS:-7}}"
: "${SHARED_TOOLS:=${PF_SHARED_TOOLS:-}}"
: "${QUEUE_AUTHOR_RE:=${PF_QUEUE_AUTHOR_RE:-}}"
: "${NS_TAKEN_CMD:=${PF_NS_TAKEN:-}}"
: "${DEV_ENV_VAR:=PM_DEV}"
: "${RAILS_TSV:=${PF_RAILS_OUTPUT:-}}"
: "${OWNERSHIP_PROSE:=${PF_OWNERSHIP_PROSE:-}}"
# PF_MEMORY_PATHS: repo-relative files and directories that are the PM's memory
# (space-separated). Default: the index named by PF_PM_INDEX and the topic
# directory next to it, i.e. the same name without ".md" (the layout the seed and
# the example agent file use). Read by the memory-freshness check (P7).
: "${MEMORY_PATHS:=${PF_MEMORY_PATHS:-}}"
if [ -z "$MEMORY_PATHS" ] && [ -n "${PF_PM_INDEX:-}" ]; then
  MEMORY_PATHS="$PF_PM_INDEX ${PF_PM_INDEX%.md}"
fi
# PF_MEMORY_COMMIT_WARN: warn when this many code commits sit on the current
# branch since the last commit that touched the memory paths. 0 turns it off.
MEMORY_COMMIT_WARN="${PF_MEMORY_COMMIT_WARN:-10}"
case "$MEMORY_COMMIT_WARN" in ''|*[!0-9]*) MEMORY_COMMIT_WARN=10 ;; esac
: "${ALWAYS_PATHS:=${PF_ALWAYS_PATHS:-}}"
# PF_DRIFT_SLUG_RE: despite the name, a SED SCRIPT that reduces a migration's
# basename (no .sql) to its subject word. Default is author-agnostic: any single
# lowercase initial, so a project that never set it is not blind to its own devs.
# PF_ARB_ID_RE: an ERE (read by awk) matching a register item id. The default
# accepts any lowercase dev initial and spells the date out instead of using
# {8}: mawk 1.3.4 has no interval expressions and would match nothing.
ARB_ID_RE="${PF_ARB_ID_RE:-}"
[ -n "$ARB_ID_RE" ] || ARB_ID_RE='H-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[a-z]-[a-z0-9-]+'
export ARB_ID_RE
# PF_ARB_CLOSED_RE: ERE of closure words accepted right after the " · " separator
# of a register header. Same default (and same reader contract) in doctor.sh.
ARB_CLOSED_RE="${PF_ARB_CLOSED_RE:-}"
[ -n "$ARB_CLOSED_RE" ] || ARB_CLOSED_RE='CLOSED|DONE|RESOLVED|ANSWERED|OBSOLETE'
export ARB_CLOSED_RE
# PF_ARB_HEADER_RE: ERE matching the HEADER line of a register item (awk). The
# id (PF_ARB_ID_RE) is then looked for inside that line. Default: any level-3
# heading, so a register that never set it is read the way the example profile
# documents.
ARB_HEADER_RE="${PF_ARB_HEADER_RE:-}"
[ -n "$ARB_HEADER_RE" ] || ARB_HEADER_RE='^### '
export ARB_HEADER_RE
# PF_ARB_DECLARED_AGE_RE: optional ERE matching a hand-maintained age field in a
# header (for example "· [0-9]+ d"). When set, the digits in the match are compared
# with the age computed from the id and a disagreement is flagged STALE. Unset: no
# declared age is read.
ARB_DECLARED_AGE_RE="${PF_ARB_DECLARED_AGE_RE:-}"
export ARB_DECLARED_AGE_RE
DRIFT_SLUG_SED="${PF_DRIFT_SLUG_RE:-}"
[ -n "$DRIFT_SLUG_SED" ] || DRIFT_SLUG_SED='s/^[0-9]\{12\}_[a-z]_//; s/[-_].*$//'

# ── governance population — judged on EVERY run, not opt-in per call ───────────
# A caller's --paths names the build's OWN files; it has no reason to also name
# the kit's governance surface (the ownership map, the claims ledger, the handoff
# register) — yet every phase below that reads the touched population (P5
# ownership, the shared-tools check, P8 artefact-keyed rails) computes its
# verdict ONLY over what it was given. An omitted governance path is not a
# partial measurement, it is a DIFFERENT, weaker population: measured on the
# origin project, same build, same worktree, verdict STOP vs WARN with the only
# delta being whether the ownership map was IN --paths that run. PF_ALWAYS_PATHS
# closes that gap unconditionally so no caller has to remember to pass it.
# Default empty => no always-checked path.
# But they are AMBIENT, not the build: a STOP that comes ONLY from one of them
# (and not from a path the caller passed or a dirty file) is reported as a WARN
# marked "[ambient]" (text) and "ambient":true (--json) — see _load_touch and P5/P8.
ALWAYS_ARR=()
if [ -n "$ALWAYS_PATHS" ]; then
  set -f
  for AP in $ALWAYS_PATHS; do ALWAYS_ARR[${#ALWAYS_ARR[@]}]="$AP"; done
  set +f
fi

if [ -z "$UPSTREAM" ]; then
  echo "pm-preflight: NOT RUN — profile '$CONF' does not define PF_REF_NAME (or UPSTREAM directly) — the shared-reference branch is undeclared." >&2
  exit 3
fi

cd "$REPO_ROOT" || { echo "pm-preflight: cannot cd $REPO_ROOT" >&2; exit 3; }

# Propagate the resolved root/profile/dev-var so a spawned ownership-lint.sh
# (P5 below) resolves the SAME profile deterministically, rather than
# re-discovering it independently and risking disagreement.
export PM_REPO_ROOT="$REPO_ROOT"
export PM_PROFILE="$CONF"
export DEV_ENV_VAR

# Paths git sees as changed, ONE PER LINE, safe for names with spaces. `status
# --porcelain` (no -z) quotes such names and renames print "old -> new", so the
# old `awk '{print $NF}'` judged "src/my file.php" as "file.php"; untracked
# directories arrive as "dir/" with --untracked-files=normal, hence =all. With
# -z a rename is "XY new" NUL "old": the old name has no XY prefix and is
# skipped. (A path containing a newline is the one thing this cannot carry.)
_dirty_paths() {
  git status --porcelain -z --untracked-files=all ${@+"$@"} 2>/dev/null | tr '\0' '\n' | awk '
    skip { skip = 0; next }
    length($0) < 4 { next }
    { x = substr($0, 1, 1); y = substr($0, 2, 1)
      if (x ~ /[RC]/ || y ~ /[RC]/) skip = 1
      print substr($0, 4) }'
}

# The touched population, as ARRAYS (names may contain spaces):
#   BUILD_ARR   — this build's own paths: the caller's --paths, else whatever git
#                 sees as changed (a dirty always-checked path is a dirty file,
#                 so it is BUILD, not ambient);
#   AMBIENT_ARR — the always-checked paths (PF_ALWAYS_PATHS) not already in BUILD;
#   TOUCH_ARR   — both, BUILD first. This is what the verdicts are computed over.
BUILD_ARR=(); AMBIENT_ARR=(); TOUCH_ARR=()
_load_touch() {
  local p a found
  BUILD_ARR=(); AMBIENT_ARR=(); TOUCH_ARR=()
  if [ ${#PATHS[@]} -gt 0 ]; then
    for p in "${PATHS[@]}"; do BUILD_ARR[${#BUILD_ARR[@]}]="$p"; done
  else
    while IFS= read -r p; do
      [ -n "$p" ] && BUILD_ARR[${#BUILD_ARR[@]}]="$p"
    done < <(_dirty_paths)
  fi
  for a in ${ALWAYS_ARR[@]+"${ALWAYS_ARR[@]}"}; do
    found=0
    for p in ${BUILD_ARR[@]+"${BUILD_ARR[@]}"}; do
      [ "$a" = "$p" ] && found=1 && break
    done
    [ "$found" = 0 ] && AMBIENT_ARR[${#AMBIENT_ARR[@]}]="$a"
  done
  for p in ${BUILD_ARR[@]+"${BUILD_ARR[@]}"}; do TOUCH_ARR[${#TOUCH_ARR[@]}]="$p"; done
  for p in ${AMBIENT_ARR[@]+"${AMBIENT_ARR[@]}"}; do TOUCH_ARR[${#TOUCH_ARR[@]}]="$p"; done
}

RC=0
WARN_N=0
STOP_N=0
UNMEAS_N=0
AMB_N=0
JSON_ROWS=""
# _AMB=1 marks the row being emitted as AMBIENT: it comes only from an
# always-checked governance path, not from this build's own paths. Text rows
# carry the literal marker "[ambient]"; --json rows carry "ambient":true.
# Callers use the *_amb wrappers below, so the PM never has to infer it.
_AMB=0

_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
_row() { # kind check message
  local amb=""
  [ "$_AMB" = 1 ] && amb=',"ambient":true'
  JSON_ROWS="$JSON_ROWS{\"level\":\"$1\",\"check\":\"$2\",\"msg\":\"$(_esc "$3")\"$amb},"
}
ok()   { [ "$DO_JSON" = 1 ] || printf '  \033[32mok\033[0m   %-22s %s\n' "$1" "$2"; _row ok "$1" "$2"; }
warn() { WARN_N=$((WARN_N+1)); [ "$RC" -lt 1 ] && RC=1
         [ "$DO_JSON" = 1 ] || printf '  \033[33mWARN\033[0m %-22s %s\n' "$1" "$2"; _row warn "$1" "$2"; }
stop() { STOP_N=$((STOP_N+1)); RC=2
         [ "$DO_JSON" = 1 ] || printf '  \033[31mSTOP\033[0m %-22s %s\n' "$1" "$2"; _row stop "$1" "$2"; }
# info: a line that is neither a pass nor a problem — used to say a phase did NOT
# measure this build. It never touches the exit code (so CLEAR stays reachable)
# and it is never printed as "ok".
info() { [ "$DO_JSON" = 1 ] || printf '  \033[36minfo\033[0m %-22s %s\n' "$1" "$2"; _row info "$1" "$2"; }
# unmeasured: a check whose target was DECLARED but could not be reached (a probe
# not run, a host down, a file the profile names that is absent). It is neither a
# pass nor a finding; it is a measurement that did not happen, so it keeps exit 1
# and is counted on its own in the summary. A target the profile never declared is
# not unmeasured: that phase prints "n/a" and changes nothing.
unmeasured() { UNMEAS_N=$((UNMEAS_N+1)); [ "$RC" -lt 1 ] && RC=1
         [ "$DO_JSON" = 1 ] || printf '  \033[35mUNMEASURED\033[0m %-22s %s\n' "$1" "$2"; _row unmeasured "$1" "$2"; }
ok_amb()   { _AMB=1; ok   "$1" "[ambient] $2"; _AMB=0; }
warn_amb() { AMB_N=$((AMB_N+1)); _AMB=1; warn "$1" "[ambient] $2"; _AMB=0; }
sec()  { [ "$DO_JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "$DO_JSON" = 1 ] || printf '\033[1mpm-preflight\033[0m  %s  @ %s\n' "$REPO_ROOT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── P1. Divergence from upstream — the WHOLE repo, not just the memory paths ────
# doctor.sh check 9 measures ahead/behind for the two memory paths only. It is
# structurally blind to db/migrations/, public/, app/ and bin/ — i.e. to every
# surface where two devs actually collide. This is that check, un-narrowed.
sec "P1 · upstream divergence"
# SOLO = there is no shared reference to measure against (no such remote, or the
# ref is absent). That is a statement about the project, not a clash: WARN once,
# and mark every comparison against the reference n/a — never STOP a solo clone
# forever, never print an "ok" that compared nothing.
SOLO=0
UP_REMOTE="${UPSTREAM%%/*}"
HAVE_REMOTE=0
git remote 2>/dev/null | grep -Fxq -- "$UP_REMOTE" && HAVE_REMOTE=1
if [ "$HAVE_REMOTE" = 0 ]; then
  : # nothing to fetch from; the shared-reference check below says so once
elif [ "$DO_FETCH" = 1 ] && [ "$OFFLINE" = 1 ]; then
  unmeasured fetch "offline (PM_OFFLINE=1): git fetch not run — divergence below measured against a possibly stale remote ref"
elif [ "$DO_FETCH" = 1 ]; then
  if git fetch --quiet "$UP_REMOTE" 2>/dev/null; then ok fetch "fetched $UP_REMOTE"
  else warn fetch "git fetch failed (offline? host unreachable?) — divergence below may be stale"; fi
else
  warn fetch "--no-fetch: divergence measured against a possibly stale remote ref"
fi

if git rev-parse --verify --quiet "$UPSTREAM" >/dev/null; then
  BEHIND=$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)
  AHEAD=$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)
  BR=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BEHIND" -gt 0 ]; then
    stop behind "$BEHIND commit(s) on $UPSTREAM not in HEAD ($BR) — PULL before sequencing anything"
    # Name the other dev's work explicitly: 'behind' is abstract, a filename is not.
    OTHERS=$(git log --format='%an' "HEAD..$UPSTREAM" 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$OTHERS" ] && stop behind "  authors upstream you have not pulled: $OTHERS"
  else
    ok behind "HEAD contains all of $UPSTREAM"
  fi
  if [ "$AHEAD" -gt 0 ]; then
    # A push is NOT bounded by a pathspec: whatever sits here rides out with the
    # next push, including another session's commits. Enumerate, never count.
    warn ahead "$AHEAD local commit(s) not on $UPSTREAM — a push ships ALL of them:"
    git log --format='         %h %an %s' "$UPSTREAM..HEAD" 2>/dev/null | head -12 \
      | while IFS= read -r l; do [ "$DO_JSON" = 1 ] || printf '%s\n' "$l"; done
  else
    ok ahead "nothing unpushed"
  fi
else
  SOLO=1
  if [ "$HAVE_REMOTE" = 0 ]; then
    warn upstream "no shared reference — single-clone mode (no remote '$UP_REMOTE' is configured, so '$UPSTREAM' cannot exist); divergence and queue-vs-reference checks are n/a"
  else
    warn upstream "no shared reference — single-clone mode ('$UPSTREAM' does not exist on remote '$UP_REMOTE': push the branch, or fix PF_REF_NAME); divergence and queue-vs-reference checks are n/a"
  fi
fi

# Uncommitted work in the SHARED worktree, listed not counted.
DIRTY=$(git status --porcelain 2>/dev/null | head -30)
if [ -n "$DIRTY" ]; then
  N=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  warn dirty "$N uncommitted path(s) in the shared tree — diff any you did not touch:"
  [ "$DO_JSON" = 1 ] || printf '%s\n' "$DIRTY" | sed 's/^/         /' | head -12
else
  ok dirty "worktree clean"
fi

# A HOOK CANNOT DETECT ITS OWN ABSENCE. The pre-commit gates a repo ships only
# run in a clone that opted in with `git config core.hooksPath <dir>`. Measured
# 2026-09-14 on a second dev's clone: the setting was EMPTY (rc=1) while every
# gate already existed in the repo — that clone had been committing with NO
# guard, silently, and nothing anywhere said so: not at commit time, not at
# pre-flight, not at deploy. This is the only phase positioned to notice, and
# it is exactly the kind of check that must live OUTSIDE the mechanism it
# audits. It only WARNS, and it never sets the config itself: the setting
# covers EVERY worktree of that clone, a parallel session's checkout included,
# so flipping it is an operator gesture to announce — not something a tool
# does on someone's behalf.
: "${HOOKS_DIR:=${PF_HOOKS_PATH:-.githooks}}"
# Compare PATHS, not strings: `./.githooks`, `.githooks/` and an absolute path
# into this repo all name the same directory and must not read as "no gate".
_norm_path() {
  local p="$1"
  case "$p" in "$REPO_ROOT"/*) p="${p#"$REPO_ROOT"/}" ;; esac
  while :; do case "$p" in ./*) p="${p#./}" ;; *) break ;; esac; done
  while :; do case "$p" in */) p="${p%/}" ;; *) break ;; esac; done
  printf '%s' "$p"
}
if [ -d "$REPO_ROOT/$HOOKS_DIR" ]; then
  HOOKS_PATH="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [ "$(_norm_path "$HOOKS_PATH")" != "$(_norm_path "$HOOKS_DIR")" ]; then
    warn hooks "core.hooksPath is '${HOOKS_PATH:-<unset>}', not $HOOKS_DIR — this clone commits with NO pre-commit gate. Fix once per clone, and ANNOUNCE it (it covers every worktree): git config core.hooksPath $HOOKS_DIR"
  else
    ok hooks "core.hooksPath=$HOOKS_DIR"
  fi
fi

# ── P2. Migration queue — three-way: disk ↔ shared reference ↔ deploy target ────
# The migration runner applies the ENTIRE pending lot in lexical filename order,
# and a deploy makes the other dev's committed-but-unapplied migrations
# applicable. 'Pending 0' proves nothing: a status check enumerates the queue
# dir ON THE DEPLOY TARGET and never the shared reference ($UPSTREAM). The only
# measure that decides, in BOTH directions, is a diff.
sec "P2 · migration queue"
# mktemp -d: a predictable $TMPDIR/pmpf.$$ can be pre-created by someone else.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pmpf.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT INT TERM

if [ -z "$MIG_DIR" ]; then
  # No queue declared: measure nothing. (An empty PF_QUEUE_DIR used to be globbed as
  # "/*.sql" and every phase below printed a green on the filesystem root.)
  ok mig-upstream "n/a (no queue declared)"
  ok mig-local "n/a (no queue declared)"
  ok mig-draft "n/a (no queue declared)"
  ok queue-target "n/a (no queue declared)"
  ONLY_UP=""; ONLY_DK=""
else
  for f in "$MIG_DIR"/*.sql; do if [ -e "$f" ]; then basename "$f"; fi; done | sort > "$TMP/disk"
  git ls-tree "$UPSTREAM" "$MIG_DIR/" --name-only 2>/dev/null \
    | sed 's|.*/||' | grep '\.sql$' | sort > "$TMP/upstream"

  ONLY_UP=""; ONLY_DK=""
  if [ "$SOLO" = 0 ]; then
    ONLY_UP=$(comm -13 "$TMP/disk" "$TMP/upstream")
    ONLY_DK=$(comm -23 "$TMP/disk" "$TMP/upstream")
  fi

  if [ "$SOLO" = 1 ]; then
    ok mig-upstream "n/a (single-clone mode: no shared reference to compare against)"
  elif [ -n "$ONLY_UP" ]; then
    stop mig-upstream "migration(s) on $UPSTREAM and NOT on your disk — the next deploy by ANYONE arms them:"
    [ "$DO_JSON" = 1 ] || printf '%s\n' "$ONLY_UP" | sed 's/^/         /'
    # Whose are they? The initial in the filename is the only reliable attributor:
    # git blame lies for a queue dir (a staged file rides out in another
    # session's commit), and md5(local)==md5(shared ref)==md5(deploy target) is
    # the real proof. The capture regex and the env var it names are BOTH
    # profile-supplied (PF_QUEUE_AUTHOR_RE / DEV_ENV_VAR) — this kernel does not
    # know how many devs there are or what their initials look like.
    if [ "$DO_JSON" != 1 ] && [ -n "${QUEUE_AUTHOR_RE:-}" ]; then
      printf '%s\n' "$ONLY_UP" | sed -n "s/${QUEUE_AUTHOR_RE}.*/         → authored by ${DEV_ENV_VAR}=\\1/p" | sort -u
    fi
  else
    ok mig-upstream "no migration on $UPSTREAM missing from disk"
  fi

  if [ "$SOLO" = 1 ]; then
    ok mig-local "n/a (single-clone mode: no shared reference to compare against)"
  elif [ -n "$ONLY_DK" ]; then
    warn mig-local "migration file(s) on disk and NOT on $UPSTREAM (unpushed, or another session's):"
    [ "$DO_JSON" = 1 ] || printf '%s\n' "$ONLY_DK" | sed 's/^/         /'
  else
    ok mig-local "no unpushed migration files"
  fi

  # Staging directory: whatever promotes a draft into the queue usually sweeps the
  # WHOLE directory, so another session's draft gets promoted under your name and
  # may land untracked by git.
  if [ -d "$DRAFT_DIR" ]; then
    DN=0; for f in "$DRAFT_DIR"/*.sql; do if [ -e "$f" ]; then DN=$((DN+1)); fi; done
    if [ "$DN" -gt 0 ]; then
      warn mig-draft "$DN file(s) in $DRAFT_DIR — promoting sweeps ALL of them; list before running it:"
      [ "$DO_JSON" = 1 ] || for f in "$DRAFT_DIR"/*.sql; do if [ -e "$f" ]; then printf '         %s\n' "$f"; fi; done
    else ok mig-draft "_draft/ empty"; fi
  else ok mig-draft "_draft/ absent (nothing staged)"; fi

  # The target leg: n/a when the project declares no deploy target (a permanent
  # WARN about something that does not exist is wallpaper); otherwise it stays
  # UNMEASURED-with-a-WARN until --probe-db is given.
  # The target leg. PF_QUEUE_TARGET, when set, is a COMMAND that prints the queue
  # file names present on the target (the profile owns how the target is reached);
  # otherwise the generic fallback is `ssh $PF_TARGET_HOST ls $PF_TARGET_PATH/<queue>`.
  # Declared by either one; neither declared is n/a.
  if [ -z "$SSH_TARGET" ] && [ -z "$QUEUE_TARGET_CMD" ]; then
    ok queue-target "n/a (no deploy target declared)"
  elif [ "$OFFLINE" = 1 ]; then
    unmeasured queue-target "offline (PM_OFFLINE=1): the deploy-target leg was not run (no ssh, no PF_QUEUE_TARGET command) — target side of the three-way diff NOT measured"
  elif [ "$DO_PROBE" = 1 ]; then
    if [ -n "$QUEUE_TARGET_CMD" ]; then
      TARGET_WHO="the PF_QUEUE_TARGET command"
      TARGET_LS=$(eval "$QUEUE_TARGET_CMD" 2>/dev/null); VRC=$?
    else
      TARGET_WHO="ssh to $SSH_TARGET"
      TARGET_LS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
          "ls $TARGET_PATH/$MIG_DIR/*.sql 2>/dev/null | xargs -n1 basename; true" 2>/dev/null); VRC=$?
    fi
    if [ "$VRC" = 0 ]; then
      printf '%s\n' "$TARGET_LS" | sed 's|.*/||' | grep '\.sql$' | sort > "$TMP/target"
      UP_NOT_TARGET=$(comm -13 "$TMP/target" "$TMP/upstream")
      TARGET_NOT_UP=$(comm -23 "$TMP/target" "$TMP/upstream")
      if [ -n "$UP_NOT_TARGET" ]; then
        warn queue-target "on $UPSTREAM, not yet on the deploy target (a deploy arms them):"
        [ "$DO_JSON" = 1 ] || printf '%s\n' "$UP_NOT_TARGET" | sed 's/^/         /'
      fi
      if [ -n "$TARGET_NOT_UP" ]; then
        stop queue-target "on the deploy target and NOT on $UPSTREAM — the target has a queued change git does not know about:"
        [ "$DO_JSON" = 1 ] || printf '%s\n' "$TARGET_NOT_UP" | sed 's/^/         /'
      fi
      [ -z "$UP_NOT_TARGET$TARGET_NOT_UP" ] && ok queue-target "deploy target == $UPSTREAM for $MIG_DIR/"
    else
      unmeasured queue-target "could not reach the deploy target ($TARGET_WHO failed, exit $VRC) — target side of the three-way diff NOT measured"
    fi
  else
    unmeasured queue-target "--probe-db not given: the deploy-target leg is not measured ('Pending 0' would be an unproven claim)"
  fi
fi


# ── P3. Global-namespace collision for NEW migrations ──────────────────────────
# Some databases (MySQL, for one) scope FK *and* CHECK constraint names to the
# SCHEMA, not the table. A sandbox schema proves syntax and behaviour; it can NEVER
# prove uniqueness in a global namespace, because the colliding object is precisely
# what the sandbox left out (see profiles/example.conf, "global namespaces"). This
# phase and the slug check below assume a SQL migration queue: with no queue
# declared they print n/a.
sec "P3 · global namespace (constraint / trigger / event names)"
CAND=""
if [ -z "$MIG_DIR" ]; then
  ok namespace "n/a (no queue declared)"
else
  if [ ${#MIGS[@]} -gt 0 ]; then
    CAND="$(printf '%s\n' "${MIGS[@]}")"
  else
    # default candidate set: drafts + anything unpushed + anything uncommitted
    CAND="$([ -n "$DRAFT_DIR" ] && ls "$DRAFT_DIR"/*.sql 2>/dev/null; \
            printf '%s\n' "$ONLY_DK" | sed "s|^|$MIG_DIR/|" ; \
            _dirty_paths -- "$MIG_DIR")"
  fi
  CAND=$(printf '%s\n' "$CAND" | grep '\.sql$' | sort -u)

  if [ -z "$CAND" ]; then
    ok namespace "no new/edited migration to check"
  else
    # Extract every name this file would CREATE in a schema-global namespace.
    : > "$TMP/names"
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      {
        grep -oiE 'CONSTRAINT[[:space:]]+`?[A-Za-z0-9_]+`?'      "$f" | awk '{print $NF}' | tr -d '`'
        grep -oiE 'CREATE[[:space:]]+TRIGGER[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" | awk '{print $NF}' | tr -d '`'
        grep -oiE 'CREATE[[:space:]]+EVENT[[:space:]]+`?[A-Za-z0-9_]+`?'   "$f" | awk '{print $NF}' | tr -d '`'
      } >> "$TMP/names"
    done <<< "$CAND"
    sort -u "$TMP/names" -o "$TMP/names"
    NN=$(wc -l < "$TMP/names" | tr -d ' ')

    if [ "$NN" = 0 ]; then
      ok namespace "candidate migration(s) declare no schema-global name"
    elif [ "$OFFLINE" = 1 ] && [ "$DO_PROBE" = 1 ] && [ -n "$NS_TAKEN_CMD" ]; then
      unmeasured namespace "offline (PM_OFFLINE=1): the live schema probe (PF_NS_TAKEN) was not run; falling back to the repo-corpus lower bound"
      DO_PROBE=0
    elif [ "$DO_PROBE" = 1 ] && [ -z "$NS_TAKEN_CMD" ]; then
      unmeasured namespace "profile defines no namespace probe (PF_NS_TAKEN): the real schema was not queried; falling back to the repo-corpus lower bound"
      DO_PROBE=0
    elif [ "$DO_PROBE" = 1 ]; then
      # AUTHORITATIVE: the entire reach-the-real-schema command is profile-owned
      # (PF_NS_TAKEN / NS_TAKEN_CMD) — this kernel does not know how the project's
      # DB is bootstrapped, reached, or authenticated to.
      if TAKEN=$(eval "$NS_TAKEN_CMD" 2>/dev/null); then
        printf '%s\n' "$TAKEN" | sort -u > "$TMP/taken"
        HITS=$(comm -12 "$TMP/names" "$TMP/taken")
        if [ -n "$HITS" ]; then
          stop namespace "name(s) ALREADY TAKEN in schema '$DB_SCHEMA' — this migration will fail:"
          [ "$DO_JSON" = 1 ] || printf '%s\n' "$HITS" | sed 's/^/         /'
        else
          ok namespace "$NN declared name(s) verified free against the REAL schema"
        fi
      else
        unmeasured namespace "live probe failed: the real schema was not queried; falling back to the repo-corpus lower bound (see below)"
        DO_PROBE=0
      fi
    fi

    if [ "$DO_PROBE" = 0 ] && [ "$NN" -gt 0 ]; then
      # OFFLINE LOWER BOUND — explicitly NOT a proof. It greps every constraint name
      # ever declared in db/migrations/ (excluding the candidate files themselves).
      # It under-reports: objects created outside migrations, or renamed since, are
      # invisible. It never over-reports: a hit here is a real prior declaration.
      : > "$TMP/corpus"
      for f in "$MIG_DIR"/*.sql; do
        # $CAND is NEWLINE-separated: a `case " $CAND " in *" $f "*)` test only ever
      # matched a single-candidate list, so with two or more every candidate
      # stayed in the corpus and collided with itself.
      if printf '%s\n' "$CAND" | grep -Fxq -- "$f"; then continue; fi
        grep -oiE 'CONSTRAINT[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" 2>/dev/null | awk '{print $NF}' | tr -d '`' >> "$TMP/corpus"
      done
      sort -u "$TMP/corpus" -o "$TMP/corpus"
      HITS=$(comm -12 "$TMP/names" "$TMP/corpus")
      if [ -n "$HITS" ]; then
        stop namespace "name(s) already declared elsewhere in $MIG_DIR — a collision is near-certain:"
        [ "$DO_JSON" = 1 ] || printf '%s\n' "$HITS" | sed 's/^/         /'
      else
        warn namespace "$NN name(s) clear of the repo corpus — this is a LOWER BOUND, not a proof. Re-run with --probe-db before applying."
      fi
    fi
  fi
fi

# ── P4. Migration slug ↔ created table names ───────────────────────────────────
# A build whose files say `retro-*` and whose tables say `crm_*` has drifted from
# what the PM recorded as planned, and nobody notices until someone greps the
# planned name and finds nothing. Five-line detector, catches it at write time.
sec "P4 · migration slug vs created objects"
if [ -n "$CAND" ]; then
  DRIFT=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    B=$(basename "$f" .sql)
    SLUG=$(printf '%s' "$B" | sed "$DRIFT_SLUG_SED" | tr '[:upper:]' '[:lower:]')
    TBLS=$(grep -oiE 'CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" \
           | awk '{print $NF}' | tr -d '`' | tr '[:upper:]' '[:lower:]' | sort -u)
    [ -z "$TBLS" ] && continue
    for t in $TBLS; do
      case "$t" in "$SLUG"*|*"$SLUG"*) ;; *) DRIFT=1
        warn slug-drift "$(basename "$f"): slug '$SLUG' creates table '$t' — name the drift in the PM record" ;;
      esac
    done
  done <<< "$CAND"
  [ "$DRIFT" = 0 ] && ok slug-drift "no slug/table divergence in candidate migrations"
elif [ -z "$MIG_DIR" ]; then
  ok slug-drift "n/a (no queue declared)"
else
  ok slug-drift "n/a"
fi

# ── P5. Ownership of the touched paths ─────────────────────────────────────────
sec "P5 · ownership"
_load_touch
if [ -z "$OWNERSHIP_MAP" ]; then
  ok ownership "n/a (no ownership map declared: PF_OWNERSHIP_MAP is empty)"
elif [ ! -f "$OWNERSHIP_MAP" ]; then
  unmeasured ownership "$OWNERSHIP_MAP absent — ownership is prose only${OWNERSHIP_PROSE:+ ($OWNERSHIP_PROSE)}; no machine check possible"
else
  if [ ${#TOUCH_ARR[@]} -eq 0 ]; then
    info ownership "NOT measured for this build — no --paths given and the worktree is clean (and no always-checked path is declared)"
  else
    # The lint cannot judge a lane without knowing WHO is acting, and it answers
    # "cannot judge" with the same rc=1 as a shared lane. Say the real cause here,
    # before running it, instead of mapping that rc to a lane claim it never made.
    eval "ACTING_DEV=\"\${${DEV_ENV_VAR}:-}\""
    if [ -z "$ACTING_DEV" ]; then
      unmeasured ownership "\$$DEV_ENV_VAR is unset — the acting dev is unknown, so lanes CANNOT be judged. Export it, or run ownership-lint.sh --dev <id>."
    else
      # The always-checked paths are a governance surface every session READS,
      # never its own build: a claim held over one of them must not STOP an
      # unrelated build, so they go to the lint as --claim-exempt (the LANE check
      # still applies to them). Empty PF_ALWAYS_PATHS => the call is as before.
      "$KIT_DIR/ownership-lint.sh" --map "$OWNERSHIP_MAP" --quiet ${ALWAYS_PATHS:+--claim-exempt "$ALWAYS_PATHS"} "${TOUCH_ARR[@]}"
      LRC=$?
      # A STOP that arises ONLY from an ambient path is not this build's problem:
      # re-judge the build's own paths alone, and downgrade if they are not STOP.
      AMBIENT_ONLY=0
      if [ "$LRC" = 2 ] && [ ${#AMBIENT_ARR[@]} -gt 0 ]; then
        if [ ${#BUILD_ARR[@]} -eq 0 ]; then
          AMBIENT_ONLY=1
        else
          "$KIT_DIR/ownership-lint.sh" --map "$OWNERSHIP_MAP" --quiet ${ALWAYS_PATHS:+--claim-exempt "$ALWAYS_PATHS"} "${BUILD_ARR[@]}"
          BRC=$?
          [ "$BRC" != 2 ] && AMBIENT_ONLY=1
        fi
      fi
      case $LRC in
        0) if [ ${#BUILD_ARR[@]} -eq 0 ]; then
             info ownership "NOT measured for this build — no --paths given and the worktree is clean; only the ${#AMBIENT_ARR[@]} always-checked path(s) were judged (within lane)"
           else
             ok ownership "all touched paths are within the acting dev's lane"
           fi ;;
        1) warn ownership "touched path(s) in a shared, contested or unmapped lane (or a ratified crossing) — run ownership-lint.sh for the list" ;;
        2) if [ "$AMBIENT_ONLY" = 1 ]; then
             warn_amb ownership "an always-checked path (PF_ALWAYS_PATHS) is in the OTHER dev's lane, a FROZEN lane, or under another claim. It would show for any build, not caused by this build's own paths; run ownership-lint.sh on it"
           else
             stop ownership "touched path(s) in the OTHER dev's lane or a FROZEN lane — see ownership-lint.sh"
           fi ;;
        3) unmeasured ownership "ownership-lint.sh did not run (exit 3): lanes were not judged" ;;
        *) unmeasured ownership "ownership-lint.sh unavailable or errored (exit $LRC): lanes were not judged" ;;
      esac
    fi
  fi
fi

# Shared tools carry environment-dependent constants. bin/deploy.sh has been
# patched by both devs on orthogonal axes (host address; GNU-vs-BSD portability)
# and neither could validate the other's environment. Touching one of these is a
# handoff event, not a commit.
TOUCHNOW=$(_dirty_paths)
for t in $SHARED_TOOLS; do
  # Whole-line match over a newline-separated list ($TOUCHNOW is one path per
  # line): the old space-padded `case` matched only when exactly one path was dirty.
  if { printf '%s\n' "$TOUCHNOW"; printf '%s\n' ${TOUCH_ARR[@]+"${TOUCH_ARR[@]}"}; } | grep -Fxq -- "$t"; then
    warn shared-tool "$t is a SHARED TOOL: environment-dependent constants in it are usually tested by its author alone. Open an arbitration item BEFORE landing (an id of the form PF_ARB_ID_RE describes) stating the system, host and interpreter version you tested on."
  fi
done

# ── P6. Arbitration queue — age computed from the ID, never from the column ────
# A register's age rule that reads a hand-maintained "N days" field goes stale:
# measured on the origin project, 9 of 11 open items carried a stale age and
# eight had crossed the stop threshold while reading "0". A detector keys on
# SILENCE, not on a status column somebody has to remember to write. The age
# comes from the date inside the item id; a declared age (PF_ARB_DECLARED_AGE_RE,
# optional) is only COMPARED against it, to flag the field as stale.
sec "P6 · arbitration queue (age recomputed, not read)"
if [ -z "$HANDOFF" ]; then
  ok arbitration "n/a (no arbitration register declared: PF_ARB_FILE is empty)"
elif [ ! -f "$HANDOFF" ]; then
  unmeasured arbitration "$HANDOFF not found"
else
  TODAY=$(date -u '+%Y%m%d')
  awk -v today="$TODAY" -v warnd="$ARB_WARN_DAYS" -v stopd="$ARB_STOP_DAYS" '
    BEGIN { hre = ENVIRON["ARB_HEADER_RE"]; idre = ENVIRON["ARB_ID_RE"]
            cre = ENVIRON["ARB_CLOSED_RE"]; dre = ENVIRON["ARB_DECLARED_AGE_RE"] }
    function g(y,m,d,  a,yy,mm){a=int((14-m)/12);yy=y+4800-a;mm=m+12*a-3;
      return d+int((153*mm+2)/5)+365*yy+int(yy/4)-int(yy/100)+int(yy/400)-32045}
    $0 ~ hre {
      line=$0
      if (match(line, idre)) {
        id=substr(line,RSTART,RLENGTH)
        idend=RSTART+RLENGTH
        # The age is computed from the first run of 8 digits inside the id.
        if (!match(id, /[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]/)) next
        ds=substr(id,RSTART,8)
        y=substr(ds,1,4)+0; m=substr(ds,5,2)+0; d=substr(ds,7,2)+0
        ty=substr(today,1,4)+0; tm=substr(today,5,2)+0; td=substr(today,7,2)+0
        age=g(ty,tm,td)-g(y,m,d)
        # The title: what follows the " · " separator, else what follows the id.
        title=substr(line, idend)
        if (match(line, /· */)) title=substr(line, RSTART+RLENGTH)
        gsub(/^[ \t-]+/, "", title); gsub(/[ \t]+$/, "", title); gsub(/\t/, " ", title)
        # CLOSURE VOCABULARY, declared by the profile (PF_ARB_CLOSED_RE, an ERE of
        # alternatives): the word is GLUED to the " · " separator, decoration only
        # AFTER it. The same value is read by pm-kit/doctor.sh (which reads the
        # BODIES this phase does not) — one variable, two readers.
        # No ASCII apostrophe anywhere in this block: it lives between shell single
        # quotes and one would close it.
        state = (line ~ ("· *(" cre ")")) ? "closed" : "open"
        # An item that could not be READ must never be rendered as one that is
        # OPEN: a closed item written off-template keeps ageing and pushes toward
        # an escalation of an already-settled question. Two levels, graded on
        # CERTAINTY:
        #   OFF-TEMPLATE : the separator, then ONLY decoration, then the word
        #                  (" · DONE" with a tick or bold markers in between).
        #                  Near-certain: the strict form already failed here.
        #   SUSPECT      : a closure word elsewhere in the header (e.g. after a
        #                  dash instead of the separator). May be legitimate
        #                  prose in an open item, so it is flagged, not asserted.
        if (state=="open") {
          if (line ~ ("· *[^A-Za-z0-9]* *(" cre ")")) badfmt[id]="OFF-TEMPLATE"
          else if (line ~ ("(" cre ")"))              badfmt[id]="SUSPECT"
        }
        decl=-1
        if (dre != "" && match(line, dre)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); if (s != "") decl=s+0 }
        if (state=="open") {
          lvl = (age>=stopd) ? "STOP" : ((age>=warnd) ? "WARN" : "ok")
          drift = (decl>=0 && decl!=age) ? sprintf(" [declared %dd — STALE]", decl) : ""
          if (id in badfmt) drift = drift " [" badfmt[id] "]"
          printf "%s\037%s\037%d\037%s\037%s\n", lvl, id, age, drift, title
        }
      }
    }
    END { for (i in badfmt) printf "FMT\037%s\0370\037%s\037\n", i, badfmt[i] | "sort" }' "$HANDOFF" > "$TMP/arb"

  if [ ! -s "$TMP/arb" ]; then
    ok arbitration "no open items"
  else
    NSTOP=$(grep -c '^STOP' "$TMP/arb" 2>/dev/null || true); NSTOP=${NSTOP:-0}
    NWARN=$(grep -c '^WARN' "$TMP/arb" 2>/dev/null || true); NWARN=${NWARN:-0}
    NOPEN=$(grep -cE '^(STOP|WARN|ok)[[:space:]]' "$TMP/arb" 2>/dev/null || true); NOPEN=${NOPEN:-0}
    NSTALE=$(grep -c 'STALE' "$TMP/arb" 2>/dev/null || true); NSTALE=${NSTALE:-0}
    # US (0x1F) separates the fields: a TAB is whitespace to read, so an empty field
    # would collapse and shift the rest.
    while IFS="$(printf '\037')" read -r LVL ID AGE DRIFT TITLE; do
      case "$LVL" in
        # PF_ARB_STOP_DAYS: an item open that long is reported, but as an AMBIENT
        # warning, never a STOP. The register is checked on every run whatever the
        # build is, so one stale item would freeze every unrelated build at exit 2;
        # whether the item is in THIS build's domain is the PM's call (kernel,
        # Response item 9). The line states the fact only: id, title, age,
        # threshold. What follows is the project policy, held in the agent file.
        STOP) warn_amb arbitration "$ID${TITLE:+ — $TITLE} — $AGE d open, past the ${ARB_STOP_DAYS}d stop threshold$DRIFT" ;;
        WARN) warn arbitration "$ID${TITLE:+ — $TITLE} — $AGE d open (warn threshold ${ARB_WARN_DAYS}d)$DRIFT" ;;
        ok)   ok arbitration "$ID${TITLE:+ — $TITLE} — $AGE d open$DRIFT" ;;
      esac
    done < "$TMP/arb"
    # An item that could not be READ must never be rendered by the same byte as
    # one that is open. Aggregated into ONE line: a rule repeated per item turns
    # into wallpaper.
    NFMT=$(grep -c '^FMT' "$TMP/arb" 2>/dev/null || true); NFMT=${NFMT:-0}
    if [ "${NFMT:-0}" -gt 0 ]; then
      FMTIDS=$(awk -F"$(printf '\037')" '$1=="FMT"{printf "%s(%s) ", $2, $4}' "$TMP/arb")
      warn arbitration "$NFMT header(s) OUTSIDE THE CLOSURE VOCABULARY, counted OPEN because they could not be read: ${FMTIDS}— closure is written ' · <WORD>' with the word GLUED to the ' · ' separator and any decoration AFTER it; <WORD> is one of: $ARB_CLOSED_RE (profile variable PF_ARB_CLOSED_RE). OFF-TEMPLATE = decoration between the separator and the word (near-certain); SUSPECT = a closure word elsewhere in the header (may be legitimate prose)."
    fi
    [ "$NSTALE" -gt 0 ] && warn arbitration "$NSTALE item(s) carry a declared age that disagrees with the age computed from the id (PF_ARB_DECLARED_AGE_RE): the field is decoration; delete it or generate it"
    ok arbitration "queue measured: $NOPEN open, $NSTOP past the stop threshold, $NWARN past the warn threshold"
  fi
fi

# Dead-but-live surface: an open scrapping item with an explicitly empty gate is
# a decision nobody scheduled, not a piece of debt. Surface it unprompted.
if [ -f "$SCRAPPING" ]; then
  NOGATE=$(grep -nE '^#[0-9]+ —.*OPEN' "$SCRAPPING" | grep -icE 'gate[^.]{0,30}none' 2>/dev/null || true); NOGATE=${NOGATE:-0}
  [ "${NOGATE:-0}" -gt 0 ] && warn dead-surface "$NOGATE open debt item(s) declare NO gate — they are unscheduled decisions, not debt. Name them."
fi

# ── P7. Memory-store health (delegate, don't reimplement) ──────────────────────
sec "P7 · PM memory"
if [ -z "$DOCTOR" ]; then
  ok memory "n/a (no memory doctor declared: PM_DOCTOR is empty)"
elif [ -x "$DOCTOR" ]; then
  # ANCHORED on the doctor's own line prefix. An unanchored `grep -E 'WARN|FAIL'`
  # also matched listed FILENAMES (an orphan named FAILOVER-notes.md) and the
  # summary text, and STOPped on a doctor that reported "0 fail(s)". The STOP
  # quotes the doctor's own FAIL line(s) — a hard-coded cause sends the reader
  # chasing the wrong problem.
  # The doctor's exit code is read from the command itself, never through a pipe.
  DALL=$("$DOCTOR" 2>/dev/null); DRC=$?
  DOUT=$(printf '%s\n' "$DALL" | grep -E '^pm-doctor: (WARN|FAIL) ' || true)
  if [ "$DRC" = 3 ]; then
    unmeasured memory "doctor.sh did not run (exit 3): $(printf '%s\n' "$DALL" | sed -n 's/^pm-doctor: NOT RUN — //p' | head -1)"
  elif [ -n "$DOUT" ]; then
    [ "$DO_JSON" = 1 ] || printf '%s\n' "$DOUT" | sed 's/^/         /'
    DFAIL=$(printf '%s\n' "$DOUT" | awk '/^pm-doctor: FAIL /{ sub(/^pm-doctor: FAIL — /, ""); printf "%s%s", (n++ ? " · " : ""), $0 }')
    [ -n "$DFAIL" ] && stop memory "doctor.sh FAIL: $DFAIL"
    printf '%s\n' "$DOUT" | grep -q '^pm-doctor: WARN ' && warn memory "doctor.sh warnings above — this is where the debt lives; '0 fail' ≠ 'in budget'"
  else
    ok memory "doctor.sh clean"
  fi
else
  unmeasured memory "$DOCTOR is not executable — memory health was not measured"
fi

# ── P7b. Memory freshness: code commits since the last memory commit ────────────
# A code commit with no memory update is how the record falls behind the code.
# Counts commits on the CURRENT branch that touch something other than the memory
# paths and the governance paths (claims, ownership map, register: those commits
# are bookkeeping, not code) since the last commit that touched the memory paths.
if [ -z "$MEMORY_PATHS" ]; then
  ok memory-fresh "n/a (no memory paths declared: PF_MEMORY_PATHS and PF_PM_INDEX are empty)"
elif [ "$MEMORY_COMMIT_WARN" = 0 ]; then
  ok memory-fresh "n/a (PF_MEMORY_COMMIT_WARN=0: check turned off)"
else
  MEMSPEC=(); MEMEXCL=()
  set -f
  for _mp in $MEMORY_PATHS; do MEMSPEC[${#MEMSPEC[@]}]="$_mp"; MEMEXCL[${#MEMEXCL[@]}]=":(exclude)$_mp"; done
  for _ap in ${ALWAYS_ARR[@]+"${ALWAYS_ARR[@]}"}; do MEMEXCL[${#MEMEXCL[@]}]=":(exclude)$_ap"; done
  set +f
  LASTMEM=$(git log -1 --format=%H -- "${MEMSPEC[@]}" 2>/dev/null)
  if [ -z "$LASTMEM" ]; then
    ok memory-fresh "n/a (no commit has touched the memory paths yet)"
  else
    NCODE=$(git rev-list --count "$LASTMEM..HEAD" -- . "${MEMEXCL[@]}" 2>/dev/null || true)
    case "$NCODE" in ''|*[!0-9]*) unmeasured memory-fresh "could not count commits since the last memory commit ($(git log -1 --format=%h "$LASTMEM"))" ; NCODE="" ;; esac
    if [ -n "$NCODE" ]; then
      if [ "$NCODE" -ge "$MEMORY_COMMIT_WARN" ]; then
        warn memory-fresh "$NCODE code commit(s) since the last memory commit ($(git log -1 --format='%h %cs' "$LASTMEM")) — the record may be behind the code (threshold $MEMORY_COMMIT_WARN, PF_MEMORY_COMMIT_WARN)"
      else
        ok memory-fresh "$NCODE code commit(s) since the last memory commit (threshold $MEMORY_COMMIT_WARN)"
      fi
    fi
  fi
fi

# ── P8. Artefact-keyed rails — recall by ADDRESS, not by association ───────────
# rails-index.sh mines the PM's always-read index into a TSV keyed on the
# named artefact each rail protects (table/file/column/symbol), transitively
# expanded over the view-dependency graph. This phase is the consumer: for
# every touched path/table, grep the TSV and print what it finds VERBATIM — a
# STOP-severity hit is exactly as blocking as any other STOP check in this
# tool, a WARN exactly as advisory. A missing TSV is never a clean pass: it is
# UNMEASURED, said as loudly as a failed probe anywhere else in this file.
sec "P8 · artefact-keyed rails"
if [ -z "$RAILS_TSV" ]; then
  ok rails "n/a (no rails table declared: PF_RAILS_OUTPUT is empty)"
elif [ ! -f "$RAILS_TSV" ]; then
  unmeasured rails "$RAILS_TSV absent — not a clean pass. Run kernel/rails-index.sh (with --refresh-graph at least once, if a view graph is declared) before trusting this check."
else
  # Freshness: the table is DERIVED from the index (and the extra corpus), and
  # nothing regenerates it. A source newer than the table means rails written or
  # changed since the last rails-index.sh run are invisible here. The pre-flight is
  # a read-only instrument, so it warns instead of regenerating. (mtimes: a pull
  # that rewrites the index also trips this, which is the right call: the table
  # was built from the old text.)
  # (cwd is the repo root; EXTRA_CORPUS patterns are globs, expanded here.)
  for _f in ${PF_PM_INDEX:-} ${PF_RAILS_EXTRA_CORPUS:-}; do
    [ -f "$_f" ] || continue
    if [ "$_f" -nt "$RAILS_TSV" ]; then
      warn rails-stale "$_f is newer than $RAILS_TSV — rails recorded since the last run are not in the table. Run kernel/rails-index.sh."
    fi
  done
  _load_touch
  # Candidates (the path and its basename) for the build's own paths and, apart,
  # for the ambient ones — a candidate named by both counts as the build's.
  : > "$TMP/rails-cand-b"; : > "$TMP/rails-cand-a"
  for P in ${BUILD_ARR[@]+"${BUILD_ARR[@]}"}; do
    printf '%s\n' "$P" >> "$TMP/rails-cand-b"
    case "$P" in */*) basename "$P" >> "$TMP/rails-cand-b" ;; esac
  done
  for P in ${AMBIENT_ARR[@]+"${AMBIENT_ARR[@]}"}; do
    printf '%s\n' "$P" >> "$TMP/rails-cand-a"
    case "$P" in */*) basename "$P" >> "$TMP/rails-cand-a" ;; esac
  done
  sort -u "$TMP/rails-cand-b" -o "$TMP/rails-cand-b"
  sort -u "$TMP/rails-cand-a" -o "$TMP/rails-cand-a"
  comm -13 "$TMP/rails-cand-b" "$TMP/rails-cand-a" > "$TMP/rails-cand-amb"

  # _rails_scan <candidate-file> <ambient 0|1>: print every rail keyed to a
  # candidate VERBATIM; sets RAIL_HITS. An ambient STOP is a WARN, labelled.
  _rails_scan() {
    RAIL_HITS=0
    while IFS= read -r RCAND; do
      [ -z "$RCAND" ] && continue
      # ENVIRON, not `awk -v c=...`: -v interprets backslash escapes, so a path
      # containing a backslash would be rewritten and never match its own row.
      RAILS_CAND="$RCAND" awk -F'\t' '$1==ENVIRON["RAILS_CAND"]' "$RAILS_TSV" > "$TMP/rails-hit" 2>/dev/null
      [ -s "$TMP/rails-hit" ] || continue
      while IFS="$(printf '\t')" read -r ART SEV RAIL SRC ORIG; do
        [ -z "$ART" ] && continue
        RAIL_HITS=$((RAIL_HITS + 1))
        MSG="$ART [$ORIG] ($SRC): $RAIL"
        # An ambient STOP is a WARN, and every ambient row carries the marker.
        if [ "$2" = 1 ]; then
          case "$SEV" in
            STOP|WARN) warn_amb rails "$MSG" ;;
            *)         ok_amb rails "[$SEV] $MSG" ;;
          esac
        else
          case "$SEV" in
            STOP) stop rails "$MSG" ;;
            WARN) warn rails "$MSG" ;;
            *)    ok rails "[$SEV] $MSG" ;;
          esac
        fi
      done < "$TMP/rails-hit"
    done < "$1"
  }

  if [ ${#BUILD_ARR[@]} -eq 0 ]; then
    info rails "NOT measured for this build — no --paths given and the worktree is clean"
  else
    _rails_scan "$TMP/rails-cand-b" 0
    CAND_N=$(wc -l < "$TMP/rails-cand-b" | tr -d ' ')
    [ "$RAIL_HITS" -eq 0 ] && ok rails "no rail keyed to any of the $CAND_N touched artefact(s)"
  fi
  [ -s "$TMP/rails-cand-amb" ] && _rails_scan "$TMP/rails-cand-amb" 1
fi

# ── verdict ────────────────────────────────────────────────────────────────────
if [ "$DO_JSON" = 1 ]; then
  printf '{"rc":%d,"warn":%d,"stop":%d,"unmeasured":%d,"ambient_warn":%d,"checks":[%s]}\n' "$RC" "$WARN_N" "$STOP_N" "$UNMEAS_N" "$AMB_N" "${JSON_ROWS%,}"
else
  printf '\n'
  case "$RC" in
    0) printf '\033[32m● CLEAR\033[0m — no warning, no STOP, nothing unmeasured. (Ownership and rails cover only the paths given with --paths.) Proceed.\n' ;;
    1) printf '\033[33m● PROCEED WITH NAMED WARNINGS (%d warning(s) of which %d ambient, %d unmeasured)\033[0m — the consult MUST name each warning and report each unmeasured check as unmeasured.\n' "$WARN_N" "$AMB_N" "$UNMEAS_N" ;;
    2) printf '\033[31m● STOP (%d blocking, %d warning(s) of which %d ambient, %d unmeasured)\033[0m — do not sequence this build. Resolve, or hand it to a human.\n' "$STOP_N" "$WARN_N" "$AMB_N" "$UNMEAS_N" ;;
  esac
fi
exit "$RC"
