#!/usr/bin/env bash
# pm-kit/load-telemetry.sh — PostToolUse hook with two legs, dispatched on the
# hook JSON's .tool_name. Both write per-machine, gitignored logs — instructional
# self-reporting is not trusted, the tool call is. The Read log backs the
# doctor's dormancy check; no check reads the Skill log yet.
#   Read   (or tool_name absent) — stamp every read of a PM topic file as
#          `date<TAB>relative-path` in $PM_LOAD_LOG ("which pointers has the PM
#          actually used?").
#   Skill  — stamp every Skill-tool load as `date<TAB>session8<TAB>skill` in
#          $PM_SKILL_LOG (session8 = first 8 chars of session_id, or `unknown`).
#          Only a name matching ^[A-Za-z0-9._:@/-]{1,128}$ is recorded, never
#          free text. Does nothing when PM_SKILL_LOG is unset or empty.
#   any other tool — exit 0, nothing recorded.
# LIMIT of the Skill leg: a skill pre-loaded through an agent's frontmatter, or
# read as a SKILL.md file with the Read tool, never fires the Skill tool — so a
# zero count is NOT proof that a skill was not used.
#
# Contract: silent, fast, ALWAYS exit 0 (a hook must never break the session).
# Fires for subagent Reads too — that is the point (the PM is a subagent).
# Started by another shell (zsh, sh)? These scripts use bash-only expansions
# (e.g. ${VAR:+-flag "$VAR"} word-splitting) — re-exec under bash, never degrade.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

# Canonical path, with a fallback for systems whose `realpath` is absent (older
# macOS) or lacks GNU options: follow symlinks with plain `readlink`, then
# resolve the directory with `pwd -P`. No `readlink -f`, no `realpath -q`.
_realpath() {
    local p="$1" l n=0 d
    if command -v realpath >/dev/null 2>&1 && realpath "$p" 2>/dev/null; then return 0; fi
    while [ -L "$p" ] && [ "$n" -lt 40 ]; do
        l="$(readlink "$p")" || return 1
        case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
        n=$((n + 1))
    done
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd -P)
    else
        d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
        printf '%s/%s\n' "$d" "$(basename "$p")"
    fi
}

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # REPO_ROOT is read by the profile this script sources
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
CONF="$KIT_DIR/../pm-kit.conf"
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null || exit 0

# Read stdin ONCE: both legs need it, and jq would consume it on the first call.
INPUT="$(cat 2>/dev/null)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"

case "$TOOL_NAME" in
    ""|Read)
        FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        [ -n "$FILE_PATH" ] || exit 0

        # Canonicalize BOTH sides: the PM reads via a ~/.claude/agents symlink, so a
        # raw prefix match on the repo path would miss every load.
        REAL_FILE="$(_realpath "$FILE_PATH")" || exit 0
        REAL_DIR="$(_realpath "$PM_MEMORY_DIR")" || exit 0

        case "$REAL_FILE" in
            "$REAL_DIR"/*)
                printf '%s\t%s\n' "$(date +%F)" "${REAL_FILE#"$REAL_DIR"/}" >> "$PM_LOAD_LOG" 2>/dev/null
                ;;
        esac
        ;;
    Skill)
        [ -n "${PM_SKILL_LOG:-}" ] || exit 0
        # The shape test lives in jq, anchored with \z: a bash $(...) would strip a
        # trailing newline and accept "name\n", and `$` also matches before one.
        SKILL="$(printf '%s' "$INPUT" | jq -r '(.tool_input.skill // .tool_input.name // .tool_input.command) | select(type == "string" and test("^[A-Za-z0-9._:@/-]{1,128}\\z"))' 2>/dev/null)"
        [ -n "$SKILL" ] || exit 0
        SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty | strings' 2>/dev/null | tr -cd 'A-Za-z0-9-')"
        SID="${SID:0:8}"
        printf '%s\t%s\t%s\n' "$(date +%F)" "${SID:-unknown}" "$SKILL" >> "$PM_SKILL_LOG" 2>/dev/null
        ;;
esac
exit 0
