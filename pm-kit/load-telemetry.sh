#!/usr/bin/env bash
# pm-kit/load-telemetry.sh — PostToolUse(Read) hook: stamp every read of a PM
# topic file into a per-machine load log. This is the mechanical counter behind
# the doctor's dormancy check ("which pointers has the PM actually used?") —
# instructional self-reporting is not trusted, the tool call is.
#
# Contract: silent, fast, ALWAYS exit 0 (a hook must never break the session).
# Fires for subagent Reads too — that is the point (the PM is a subagent).
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"
CONF="$KIT_DIR/../pm-kit.conf"
[ -f "$CONF" ] || exit 0
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null || exit 0

FILE_PATH="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -n "$FILE_PATH" ] || exit 0

# Canonicalize BOTH sides: the PM reads via a ~/.claude/agents symlink, so a
# raw prefix match on the repo path would miss every load.
REAL_FILE="$(realpath -q "$FILE_PATH" 2>/dev/null)" || exit 0
REAL_DIR="$(realpath -q "$PM_MEMORY_DIR" 2>/dev/null)" || exit 0

case "$REAL_FILE" in
    "$REAL_DIR"/*)
        printf '%s\t%s\n' "$(date +%F)" "${REAL_FILE#"$REAL_DIR"/}" >> "$PM_LOAD_LOG" 2>/dev/null
        ;;
esac
exit 0
