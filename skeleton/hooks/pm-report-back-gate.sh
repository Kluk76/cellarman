#!/usr/bin/env bash
# pm-report-back-gate.sh — OPTIONAL, off by default (nothing wires it unless
# you do). Blocks the PM subagent ONCE when a consult that declared itself a
# report-back is about to end and no file under the PM memory paths was
# written during it.
#
# Claude Code documentation this file relies on (read 2026-10-02):
#   https://code.claude.com/docs/en/hooks
#     - SubagentStop input: agent_id, agent_type, agent_transcript_path,
#       stop_hook_active; blocked with {"decision":"block","reason":"..."} on
#       stdout (exit 0) — the reason is delivered to the subagent as its next
#       instruction.
#     - PostToolUse input: tool_input.file_path for Write and Edit; inside a
#       subagent the common input carries agent_id and agent_type.
#     - "Hooks in skills and agents": a Stop hook in a subagent's frontmatter
#       is converted to SubagentStop.
#   https://code.claude.com/docs/en/sub-agents
#     - frontmatter `hooks`, and the workspace-trust rule: frontmatter hooks
#       of a PROJECT-level agent (.claude/agents/) run only after the folder's
#       trust dialog was accepted; a `-p` session does not count.
#
# WHAT IT IS, HONESTLY
#   A reminder with one tooth. It makes the PM spend one more turn; it cannot
#   make that turn produce a good record. Known ways it goes wrong:
#   - FILLER WRITES. A model that is blocked for "no write" can satisfy the
#     check by writing something worthless. The block message therefore offers
#     a second way out (state why nothing needs recording), and the kernel
#     tells the PM not to write an entry in order to have written one. That is
#     an instruction, not a mechanism. If you see filler entries, unwire this.
#   - It sees only Write and Edit calls. A memory file written through Bash
#     is not recorded, so the PM is blocked once although it did write.
#   - It blocks once per subagent run, then lets the run end whatever happened.
#   - It finds the declaration by searching the subagent's transcript file as
#     plain text. The transcript's line format is not a documented schema, so
#     this is a text search, not a parse. It looks for `consult:` followed by
#     the kind, at the start of a prompt line. A consult that does not carry
#     that first line is never gated.
#   - NOT CONFIRMED: on Claude Code v2.1.271 or later a subagent may deliver
#     its report through the SubagentHandback tool before it stops. A write
#     made after the block still lands on disk, but whether the PM's amended
#     reply reaches the orchestrator in that case is not something the
#     documentation states. Treat the gate as protecting the record, not the
#     reply.
#
# WIRING (in the PM agent file's frontmatter; see skeleton/agent-example.md)
#   hooks:
#     PostToolUse:
#       - matcher: "Write|Edit"
#         hooks:
#           - type: command
#             command: '"${CLAUDE_PROJECT_DIR}/.claude/hooks/pm-report-back-gate.sh"'
#     Stop:
#       - hooks:
#           - type: command
#             command: '"${CLAUDE_PROJECT_DIR}/.claude/hooks/pm-report-back-gate.sh"'
#   Both entries are needed: the first records writes, the second checks. The
#   script tells the two apart by hook_event_name on stdin.
#
# CONFIG
#   PM_GATE_MEMORY_PATHS  space-separated files or directories that count as
#                         PM memory (absolute, or relative to the project
#                         dir). If unset, PM_MEMORY_DIR / PM_INDEX /
#                         PM_SYNC_EXTRA_PATHS are read from pm-kit.conf, found
#                         at $PM_KIT_CONF or
#                         <project dir>/claude-brain/pm-kit.conf.
#   No memory paths found => the gate cannot judge and lets the run end.
#
# CONTRACT
#   - Always exits 0. Any internal error means "do not block": a broken hook
#     must not brick a session.
#   - jq is optional. Without it the few flat string fields needed are taken
#     from the JSON with sed, which is adequate for ids and ordinary paths and
#     wrong for a path containing an escaped quote (the write is then missed
#     and the PM is blocked once).
#   - Writes only its state under ${TMPDIR:-/tmp}/cellarman-report-back-gate/
#     (<agent_id>.writes, <agent_id>.blocked), and prunes entries older than
#     seven days there.
#   - bash 3.2 compatible.
#
# MANUAL TEST
#   printf '%s' '{"hook_event_name":"SubagentStop","agent_id":"a1","stop_hook_active":false,"agent_transcript_path":"/path/to/agent-a1.jsonl"}' \
#     | PM_GATE_MEMORY_PATHS=/path/to/memory ./pm-report-back-gate.sh; echo "rc=$?"
set +e
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

INPUT="$(cat 2>/dev/null)"

gate() {
    [ -n "$INPUT" ] || return 0

    HAVE_JQ=0
    command -v jq >/dev/null 2>&1 && HAVE_JQ=1

    # str <jq path> <bare key>: a string field, by jq or by the sed fallback.
    str() {
        if [ "$HAVE_JQ" = 1 ]; then
            printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
        else
            printf '%s' "$INPUT" | tr '\n' ' ' \
                | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
        fi
    }

    EVENT="$(str '.hook_event_name' hook_event_name)"
    AGENT_ID="$(str '.agent_id' agent_id)"
    # Outside a subagent there is no agent_id, and nothing here applies.
    [ -n "$AGENT_ID" ] || return 0
    case "$AGENT_ID" in *[!A-Za-z0-9._-]*) return 0 ;; esac

    STATE_DIR="${TMPDIR:-/tmp}/cellarman-report-back-gate"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    find "$STATE_DIR" -type f -mtime +7 -exec rm -f {} + 2>/dev/null

    PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(pwd)"

    # phys <path>: physical absolute path of a file or directory whose parent
    # exists (macOS /tmp -> /private/tmp, symlinked agent directories).
    phys() {
        _p="$1"
        case "$_p" in "~/"*) _p="$HOME/${_p#"~/"}" ;; esac
        case "$_p" in /*) : ;; *) _p="$PROJECT_DIR/$_p" ;; esac
        if [ -d "$_p" ]; then
            (cd "$_p" 2>/dev/null && pwd -P)
        else
            _d="$(cd "$(dirname "$_p")" 2>/dev/null && pwd -P)" || return 1
            printf '%s/%s\n' "$_d" "$(basename "$_p")"
        fi
    }

    MEM_PATHS="${PM_GATE_MEMORY_PATHS:-}"
    if [ -z "$MEM_PATHS" ]; then
        CONF="${PM_KIT_CONF:-$PROJECT_DIR/claude-brain/pm-kit.conf}"
        if [ -f "$CONF" ]; then
            REPO_ROOT="$PROJECT_DIR"
            KIT_DIR="$(dirname "$CONF")/pm-kit"
            # shellcheck disable=SC1090
            . "$CONF" 2>/dev/null
            MEM_PATHS="${PM_MEMORY_DIR:-} ${PM_INDEX:-} ${PM_SYNC_EXTRA_PATHS:-}"
        fi
    fi
    case "$MEM_PATHS" in *[!\ ]*) : ;; *) return 0 ;; esac

    case "$EVENT" in
    PostToolUse)
        FILE_PATH="$(str '.tool_input.file_path' file_path)"
        [ -n "$FILE_PATH" ] || return 0
        F="$(phys "$FILE_PATH")" || return 0
        for raw in $MEM_PATHS; do
            M="$(phys "$raw")" || continue
            case "$F" in
                "$M"|"$M"/*)
                    printf '%s\n' "$F" >> "$STATE_DIR/$AGENT_ID.writes" 2>/dev/null
                    return 0 ;;
            esac
        done
        return 0
        ;;
    SubagentStop|Stop)
        # Already continuing because of a stop hook, or already blocked once.
        if [ "$HAVE_JQ" = 1 ]; then
            ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
        else
            ACTIVE=false
            printf '%s' "$INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && ACTIVE=true
        fi
        [ "$ACTIVE" = true ] && return 0
        [ -e "$STATE_DIR/$AGENT_ID.blocked" ] && return 0

        TRANSCRIPT="$(str '.agent_transcript_path' agent_transcript_path)"
        case "$TRANSCRIPT" in "~/"*) TRANSCRIPT="$HOME/${TRANSCRIPT#"~/"}" ;; esac
        [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || return 0

        # Declared as a report-back? The kind line opens the prompt, so in the
        # transcript it follows a JSON quote or an escaped newline.
        grep -Eiq '("|\\n)[[:space:]]*consult:[[:space:]]*report-back' "$TRANSCRIPT" 2>/dev/null || return 0

        [ -s "$STATE_DIR/$AGENT_ID.writes" ] && return 0

        : > "$STATE_DIR/$AGENT_ID.blocked" 2>/dev/null || return 0
        printf '%s\n' '{"decision":"block","reason":"This consult declared itself a report-back and no file under the PM memory paths was written during it (only Write and Edit calls are seen). Either record the build now, under the admission tests, and end your reply with the paths you wrote, or state why nothing needs to be recorded. Do not write an entry only to satisfy this check. It will not fire again in this run."}'
        return 0
        ;;
    esac
    return 0
}

# Run in a subshell: whatever the sourced conf does (an `exit`, a syntax
# error), this script still ends with 0 and prints only the gate's own output.
OUT="$(gate 2>/dev/null)"
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
