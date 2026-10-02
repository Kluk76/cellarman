#!/usr/bin/env bash
# pm-kit/load-telemetry.sh — PostToolUse(Read) hook: stamp every read of a PM
# topic file into a per-machine load log. This is the mechanical counter behind
# the doctor's dormancy check ("which pointers has the PM actually used?") —
# instructional self-reporting is not trusted, the tool call is.
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

FILE_PATH="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"
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
exit 0
