#!/usr/bin/env bash
# claim.sh — the ONLY writer of CLAIMS.tsv lines. It appends (never rewrites)
# one row, mechanically, so the 7th field (which SESSION holds a claim) is
# never left to a human to remember.
#
# WHY
#   Several sessions of the SAME developer can run in parallel on one shared
#   clone. The first six fields carry only the developer INITIAL, not which of
#   that developer's sessions holds a claim, so one session can overwrite
#   another's work. A written-only rule ("name your session in the text") has
#   no mechanical carrier and does not hold. So the 7th field is written BY
#   THIS SCRIPT, from the environment, never by hand.
#
# FORMAT — TAB-separated, appended to the claims file:
#   status<TAB>date<TAB>dev<TAB>slug<TAB>surfaces<TAB>intent<TAB>session
#   status   open | closed | restated | abandoned   (from the verb you pass)
#   dev      the value of the profile's dev env var (never guessed)
#   session  <session prefix><first 8 chars of the session env var>
#            — the same derivation ownership-lint.sh uses to recognise "mine"
#
# USAGE
#   claim.sh open|close|restate|abandon <slug>
#            [--surfaces "<space-separated globs>"] [--intent "<one sentence>"]
#            [--conf <profile>] [--dry-run] [--no-commit] [--push]
#
#   open|restate    write a LIVE row — refused when the session env var is
#                   unset (a live row with no session recreates the defect).
#   close|abandon   a missing session is TOLERATED (closing a dead session's
#                   row is a normal act) but stated on stderr, not silently
#                   written as an empty field.
#   --dry-run       print the composed row and exit; nothing is written,
#                   staged, committed or pushed.
#   --no-commit     append only; do not stage or commit.
#   --push          after the commit, push (see below). Also enabled by
#                   PF_CLAIM_PUSH=1 in the profile. OFF by default.
#
# EXIT CODES   0 done · 1 the row was written but a git step failed ·
#              2 refused or bad usage (nothing written).
#
# PROFILE VARIABLES (see profiles/example.conf)
#   DEV_ENV_VAR         env var holding the developer initial (default PM_DEV)
#   DEVS                optional; when set, the initial must be one of them
#   PF_CLAIMS_FILE      claims file, repo-relative (required)
#   PF_SESSION_ENV_VAR  env var holding the session id (default
#                       CLAUDE_CODE_SESSION_ID)
#   PF_SESSION_PREFIX   prefix of the session field (default empty)
#   PF_CLAIM_PUSH       1 = push after commit (default 0)
#
# NO FALLBACK FOR THE DEV. Under sudo the environment is purged; falling back
# to $USER/$LOGNAME would record a shared account — an attribution that LOOKS
# filled in while naming nobody. The script refuses instead.
#
# APPEND-ONLY. Never `sed -i`, never edit another developer's row. The claims
# file is meant to be union-merged; this script only ever appends.
#
# SANITISING. A TAB or newline inside --intent/--surfaces would split the row
# into 8+ fields and corrupt every awk/`cut -f7` reader. TAB/CR/LF become a
# space, and stderr says so. A slug is restricted to [A-Za-z0-9._-].
#
# GIT. After a successful write: `git add` of THIS FILE ONLY (never -A: the
# tree is shared), a commit limited to that path, and — only when push is
# enabled — a push. A push sends the whole branch, so it is REFUSED when any
# commit ahead of the upstream touches a path other than the claims file; the
# commit then stays local. Every exit code is captured outside a pipe. This
# script never rebases and never forces.
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck disable=SC1091
. "$KIT_DIR/kernel/profile-lib.sh" || exit 2

die() { echo "claim.sh: $*" >&2; exit 2; }

_usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]:-$0}" | grep -E '^#( |$)' | sed -E 's/^# ?//'; }

# ── arguments ────────────────────────────────────────────────────────────────
[ $# -ge 1 ] || { _usage; exit 2; }
case "$1" in -h|--help) _usage; exit 0 ;; esac
[ $# -ge 2 ] || { _usage; exit 2; }

action="$1"; slug="$2"; shift 2

case "$action" in
  open)    status_word="open" ;;
  close)   status_word="closed" ;;
  restate) status_word="restated" ;;
  abandon) status_word="abandoned" ;;
  *) die "unknown action '$action' — expected open|close|restate|abandon" ;;
esac

[ -n "$slug" ] || die "<slug> is empty"
case "$slug" in
  *[!A-Za-z0-9._-]*) die "slug '$slug' must match [A-Za-z0-9._-]+ (no spaces, TABs or slashes)" ;;
esac

surfaces=""; intent=""; dry_run=0; do_commit=1; push_flag=0; CONF_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surfaces)  [ $# -ge 2 ] || die "--surfaces needs a value"; surfaces="$2"; shift 2 ;;
    --intent)    [ $# -ge 2 ] || die "--intent needs a value"; intent="$2"; shift 2 ;;
    --conf)      [ $# -ge 2 ] || die "--conf needs a value"; CONF_ARG="$2"; shift 2 ;;
    --dry-run)   dry_run=1; shift ;;
    --no-commit) do_commit=0; shift ;;
    --push)      push_flag=1; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# ── repo + profile ───────────────────────────────────────────────────────────
pm_repo_root || die "not inside a git repository and PM_REPO_ROOT is not set"
if [ -n "$CONF_ARG" ] && [ ! -f "$CONF_ARG" ]; then
  die "--conf '$CONF_ARG' does not exist"
fi
pm_find_profile "$CONF_ARG" || die "no profile found (--conf, \$PM_PROFILE, or exactly one *.conf in $KIT_DIR/profiles/)"
# shellcheck disable=SC1090
. "$CONF" || die "cannot source profile $CONF"

: "${DEV_ENV_VAR:=PM_DEV}"
: "${PF_SESSION_ENV_VAR:=CLAUDE_CODE_SESSION_ID}"
: "${PF_SESSION_PREFIX:=}"
: "${PF_CLAIM_PUSH:=0}"
: "${PF_CLAIMS_FILE:=}"
[ -n "$PF_CLAIMS_FILE" ] || die "PF_CLAIMS_FILE is not set in $CONF"
[ "$PF_CLAIM_PUSH" = 1 ] && push_flag=1

for v in "$DEV_ENV_VAR" "$PF_SESSION_ENV_VAR"; do
  case "$v" in
    ""|[0-9]*|*[!A-Za-z0-9_]*) die "'$v' (from the profile) is not a valid environment variable name" ;;
  esac
done

CLAIMS_REL="${PF_CLAIMS_FILE#"$REPO_ROOT"/}"
case "$CLAIMS_REL" in /*) die "PF_CLAIMS_FILE '$PF_CLAIMS_FILE' is outside the repository" ;; esac
CLAIMS_ABS="$REPO_ROOT/$CLAIMS_REL"

# ── dev: mandatory, no fallback ──────────────────────────────────────────────
eval "dev=\"\${${DEV_ENV_VAR}:-}\""
if [ -z "$dev" ]; then
  cat >&2 <<TXT

claim.sh: \$$DEV_ENV_VAR is not set — refusing to write.

Field 3 (dev) of the claims file must carry the initial of the developer
posting the row. There is NO fallback: under sudo the environment is purged,
and falling back to \$USER or \$LOGNAME would record a shared account — the
row would lose its author without anything signalling it.

Expected form:
    export $DEV_ENV_VAR=<your initial>
TXT
  exit 2
fi
case "$dev" in
  *[!A-Za-z0-9_-]*) die "\$$DEV_ENV_VAR value '$dev' must match [A-Za-z0-9_-]+" ;;
esac
if [ -n "${DEVS:-}" ]; then
  known=0
  for d in $DEVS; do [ "$d" = "$dev" ] && known=1; done
  [ "$known" = 1 ] || die "\$$DEV_ENV_VAR='$dev' is not one of the profile's DEVS ($DEVS)"
fi

# ── session ──────────────────────────────────────────────────────────────────
eval "session_id=\"\${${PF_SESSION_ENV_VAR}:-}\""
session_field=""
if [ -n "$session_id" ]; then
  session_field="${PF_SESSION_PREFIX}${session_id:0:8}"
else
  case "$action" in
    open|restate)
      cat >&2 <<TXT

claim.sh: \$$PF_SESSION_ENV_VAR is not set — refusing to write a '${status_word}' row.

A LIVE row (open/restated) without a session recreates the exact defect this
script exists to close: another session could no longer tell who holds it.
There is no fallback here either.
TXT
      exit 2
      ;;
    close|abandon)
      echo "claim.sh: WARNING \$$PF_SESSION_ENV_VAR is not set; field 7 will be EMPTY on this '${status_word}' row (it may close the row of a session that is already gone)." >&2
      ;;
  esac
fi

# ── sanitise ─────────────────────────────────────────────────────────────────
_sanitize() {
  local raw="$1" cleaned
  cleaned="$(printf '%s' "$raw" | tr '\t\r\n' '   ')"
  if [ "$cleaned" != "$raw" ]; then
    echo "claim.sh: WARNING TAB/newline replaced by a space in a field (--surfaces or --intent)" >&2
  fi
  printf '%s' "$cleaned"
}
surfaces="$(_sanitize "$surfaces")"
intent="$(_sanitize "$intent")"

date_field="$(date +%Y-%m-%d)"
line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$status_word" "$date_field" "$dev" "$slug" "$surfaces" "$intent" "$session_field")"
nfields="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"

if [ "$dry_run" = 1 ]; then
  echo "claim.sh --dry-run: nothing written. Composed row (${nfields} fields):"
  printf '%s\n' "$line"
  exit 0
fi

[ -f "$CLAIMS_ABS" ] || die "$CLAIMS_REL does not exist — create it first (skeleton/CLAIMS.tsv.example)"

# A file whose last byte is not a newline would glue our row onto its last line.
if [ -s "$CLAIMS_ABS" ]; then
  last_byte="$(tail -c 1 "$CLAIMS_ABS" | od -An -tx1 | tr -d ' \n')"
  if [ "$last_byte" != "0a" ]; then
    printf '\n' >> "$CLAIMS_ABS" || die "cannot append to $CLAIMS_REL"
  fi
fi
printf '%s\n' "$line" >> "$CLAIMS_ABS" || die "cannot append to $CLAIMS_REL"
echo "claim.sh: row appended to $CLAIMS_REL (${nfields} fields)"
printf '%s\n' "$line"

[ "$do_commit" = 1 ] || exit 0

TMPLOG="$(mktemp -d "${TMPDIR:-/tmp}/claim-sh.XXXXXX")" || { echo "claim.sh: cannot create a temp dir; row written but not committed" >&2; exit 1; }
trap 'rm -rf "$TMPLOG"' EXIT

git -C "$REPO_ROOT" add -- "$CLAIMS_REL" > "$TMPLOG/add.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "claim.sh: git add FAILED (rc=$rc) — the row is on disk, not staged:" >&2
  cat "$TMPLOG/add.log" >&2
  exit 1
fi

commit_msg="chore(claims): ${action} ${slug} — dev=${dev} session=${session_field:-<none>}"
git -C "$REPO_ROOT" commit -m "$commit_msg" -- "$CLAIMS_REL" > "$TMPLOG/commit.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "claim.sh: git commit FAILED (rc=$rc) — the row is on disk and STAGED, not committed:" >&2
  cat "$TMPLOG/commit.log" >&2
  exit 1
fi
echo "claim.sh: committed —"
cat "$TMPLOG/commit.log"

if [ "$push_flag" != 1 ]; then
  echo "claim.sh: not pushed (push is opt-in: --push or PF_CLAIM_PUSH=1)"
  exit 0
fi

branch="$(git -C "$REPO_ROOT" symbolic-ref -q --short HEAD 2>/dev/null)"
remote=""; mergeref=""; upstream=""
if [ -n "$branch" ]; then
  remote="$(git -C "$REPO_ROOT" config "branch.$branch.remote" 2>/dev/null)"
  mergeref="$(git -C "$REPO_ROOT" config "branch.$branch.merge" 2>/dev/null)"
  upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
fi
if [ -z "$remote" ] || [ -z "$mergeref" ] || [ -z "$upstream" ]; then
  echo "claim.sh: no remote/upstream configured — committed locally, push skipped"
  exit 0
fi

# Guard: a push publishes the whole branch, not just this commit.
foreign=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$p" != "$CLAIMS_REL" ]; then
      foreign="$foreign $(git -C "$REPO_ROOT" log -1 --format=%h "$sha")"
      break
    fi
  done < <(git -C "$REPO_ROOT" -c core.quotepath=false show --name-only --format= "$sha" 2>/dev/null)
done < <(git -C "$REPO_ROOT" log --format=%H "$upstream..HEAD" 2>/dev/null)
if [ -n "$foreign" ]; then
  echo "claim.sh: PUSH REFUSED — unpushed commit(s) touching other paths:$foreign" >&2
  echo "claim.sh: the claim commit stays local; push when you have decided to publish that work." >&2
  exit 1
fi

git -C "$REPO_ROOT" push "$remote" "HEAD:$mergeref" > "$TMPLOG/push.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "claim.sh: git push FAILED (rc=$rc) — common on a shared tree (non-fast-forward). The commit stays local; no rebase and no force is attempted by this script." >&2
  cat "$TMPLOG/push.log" >&2
  exit 1
fi
echo "claim.sh: pushed —"
cat "$TMPLOG/push.log"
exit 0
