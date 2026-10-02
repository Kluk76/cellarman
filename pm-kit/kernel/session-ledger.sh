#!/usr/bin/env bash
# session-ledger.sh — the authorship register that lets pm-sync commit only
# what ITS OWN session wrote, never a neighbour's mid-flight edit.
#
# WHY
#   pm-sync is a hook on `git commit`/`git push`, global across every Claude
#   Code session sharing a clone. Scoped by path alone, any commit in ANY
#   session sweeps up whatever memory file ANY session is mid-write on. With
#   several sessions at once that produces real corruption: a neighbour's
#   half-written file checked in as if finished.
#
#   Every tool-call hook receives the CALLING session's `session_id` on stdin
#   (a sub-agent's calls carry its PARENT session's id, which is the
#   attribution we want). This script is the write side: wired as a
#   PostToolUse hook on Write|Edit, it appends the touched path to a
#   per-session registry. pm-sync (the read side) trusts only the calling
#   session's own registry.
#
# WIRING (the project owns .claude/settings.json; this script wires nothing)
#   PostToolUse, matcher "Write|Edit", command: this script. stdin = the
#   tool-call JSON envelope.
#
# CONTRACT
#   - ALWAYS exits 0. A hook must never break the session: missing jq,
#     unreadable JSON, an out-of-scope path, a full disk all go quiet.
#   - In scope ONLY: the paths pm-sync treats as memory — PM_MEMORY_DIR,
#     PM_INDEX and PM_SYNC_EXTRA_PATHS from pm-kit.conf. Every other path is
#     silently ignored (most Write/Edit calls are not memory).
#   - Registry: <git-common-dir>/pm-ledger/<session_id>.paths. The COMMON dir
#     (`git rev-parse --git-common-dir`), because a worktree's own .git is a
#     stub file and the registry must be visible to whichever clone or
#     worktree eventually runs pm-sync.
#   - Paths are stored relative to the repo root, one per line, de-duplicated.
#   - A session id that is not a plain token ([A-Za-z0-9._-]) is ignored: it
#     becomes a file name.
#
# CONFIG
#   pm-kit.conf is found via $PM_KIT_CONF, else <kit>/../pm-kit.conf. It is
#   sourced with REPO_ROOT (git toplevel, or $PM_REPO_ROOT) and KIT_DIR set.
#
# MANUAL USE
#   echo '{"session_id":"abc","tool_input":{"file_path":"/repo/claude-brain/agents/pm-memory.md"}}' | ./session-ledger.sh
set +e
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0
[ -n "$FILE_PATH" ] || exit 0
case "$SESSION_ID" in
    *[!A-Za-z0-9._-]*) exit 0 ;;
esac

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

REPO_ROOT="${PM_REPO_ROOT:-}"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_ROOT" ] || exit 0
# Compare physical paths (macOS /tmp -> /private/tmp, symlinked checkouts).
REPO_ROOT="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || exit 0

COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
[ -n "$COMMON_DIR" ] || exit 0
case "$COMMON_DIR" in
    /*) : ;;
    *) COMMON_DIR="$REPO_ROOT/$COMMON_DIR" ;;
esac

# Normalise file_path to repo-relative, resolving the directory physically
# (the file itself may have just been created; its directory exists).
case "$FILE_PATH" in
    /*) : ;;
    *) FILE_PATH="$(pwd -P)/$FILE_PATH" ;;
esac
FILE_DIR="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd -P)" || exit 0
PHYS_PATH="$FILE_DIR/$(basename "$FILE_PATH")"
case "$PHYS_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${PHYS_PATH#"$REPO_ROOT"/}" ;;
    *) exit 0 ;;
esac

CONF="${PM_KIT_CONF:-$KIT_DIR/../pm-kit.conf}"
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
REPO_ROOT="$REPO_ROOT" KIT_DIR="$KIT_DIR" . "$CONF" 2>/dev/null || exit 0

# Memory paths, repo-relative (the conf may spell them under the repo root as
# it was resolved — physically, or not).
_rel() {
    local p="$1" alt
    p="${p%/}"
    alt="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"
    case "$p" in "$REPO_ROOT"/*) printf '%s' "${p#"$REPO_ROOT"/}"; return ;; esac
    case "$alt" in "$REPO_ROOT"/*) printf '%s' "${alt#"$REPO_ROOT"/}"; return ;; esac
    case "$p" in /*) return ;; esac
    printf '%s' "$p"
}

IN_SCOPE=0
for raw in "${PM_MEMORY_DIR:-}" "${PM_INDEX:-}" ${PM_SYNC_EXTRA_PATHS:-}; do
    [ -n "$raw" ] || continue
    m="$(_rel "$raw")"
    [ -n "$m" ] || continue
    case "$REL_PATH" in
        "$m"|"$m"/*) IN_SCOPE=1; break ;;
    esac
done
[ "$IN_SCOPE" -eq 1 ] || exit 0

LEDGER_DIR="$COMMON_DIR/pm-ledger"
mkdir -p "$LEDGER_DIR" 2>/dev/null || exit 0
LEDGER_FILE="$LEDGER_DIR/$SESSION_ID.paths"

# Append only if absent. A lost race between two invocations of the SAME
# session costs a duplicate line, which pm-sync tolerates (it checks
# membership, never counts lines).
if [ -f "$LEDGER_FILE" ] && grep -Fxq -- "$REL_PATH" "$LEDGER_FILE" 2>/dev/null; then
    exit 0
fi
printf '%s\n' "$REL_PATH" >> "$LEDGER_FILE" 2>/dev/null
exit 0
