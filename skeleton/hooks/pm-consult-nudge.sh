#!/usr/bin/env bash
# pm-consult-nudge.sh — OPTIONAL. A SessionStart hook that puts a short
# reminder into the main session's context: consult the PM subagent before
# planning a build and after one lands.
#
# Claude Code documentation this file relies on (read 2026-10-02):
#   https://code.claude.com/docs/en/hooks
#     - SessionStart: matcher values startup | resume | clear | compact | fork;
#       input fields `source` and, when the session runs as an agent,
#       `agent_type`; plain-text stdout of a SessionStart hook that exits 0 is
#       added to Claude's context.
#   https://code.claude.com/docs/en/sub-agents
#     - Claude decides when to delegate from each subagent's description.
#       The documentation describes no way to force the main session to
#       consult a subagent.
#
# WHAT IT IS, HONESTLY
#   A nudge, not a gate. It adds text once per session start; the model may
#   still plan a build without consulting anyone, and nothing detects that.
#   It is one of three carriers of the same sentence (the agent description
#   and the CLAUDE.md snippet are the others). If your CLAUDE.md already
#   carries the rule, this hook adds little; its use is re-injecting the rule
#   after a compaction, when early context has been summarised away.
#
#   It is a SessionStart hook on purpose, not a per-prompt one: a per-prompt
#   injector would charge its tokens on every message.
#
# COST
#   The text below is about 670 bytes: roughly 150 to 200 tokens (estimated
#   from the byte count, not measured with a tokenizer), paid once
#   per session start, /clear and compaction (with the matcher shown under
#   WIRING). To measure it on your install:
#     echo '{"source":"startup"}' | ./pm-consult-nudge.sh acme-pm | wc -c
#
# WIRING (.claude/settings.json; see skeleton/settings.example.json)
#   "SessionStart": [ { "matcher": "startup|clear|compact",
#       "hooks": [ { "type": "command",
#                    "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/pm-consult-nudge.sh",
#                    "args": ["acme-pm"] } ] } ]
#   `resume` is left out of the matcher because a resumed conversation still
#   holds the text from its first start.
#
# USAGE
#   pm-consult-nudge.sh [<pm agent name>]     (or PM_AGENT_NAME in the env)
#
# CONTRACT
#   - Always exits 0; on any internal error it prints nothing.
#   - jq is optional. It is used only to read `agent_type`, so that a session
#     which IS the PM (claude --agent <name>) is not told to consult itself.
#     Without jq a sed fallback reads the same flat string field.
#   - Writes nothing anywhere. bash 3.2 compatible.
set +e
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

AGENT_NAME="${1:-${PM_AGENT_NAME:-}}"
INPUT="$(cat 2>/dev/null)"

AGENT_TYPE=""
if [ -n "$INPUT" ]; then
    if command -v jq >/dev/null 2>&1; then
        AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)"
    else
        AGENT_TYPE="$(printf '%s' "$INPUT" | tr '\n' ' ' \
            | sed -n 's/.*"agent_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null)"
    fi
fi
if [ -n "$AGENT_NAME" ] && [ "$AGENT_TYPE" = "$AGENT_NAME" ]; then
    exit 0
fi

case "$AGENT_NAME" in
    "") WHO="the project's PM subagent" ;;
    *[!A-Za-z0-9._-]*) WHO="the project's PM subagent" ;;
    *) WHO="the \`$AGENT_NAME\` subagent" ;;
esac

cat 2>/dev/null <<EOF
Project reminder (a nudge, not a gate): this project keeps its architecture and build record with $WHO.
- Before planning or starting a build, consult it. Open the prompt with the line \`consult: plan\`, then the task, the files and tables it touches, constraints, and the plan item id (or "off-plan").
- After a build lands or stops, consult it again so its record is updated. Open the prompt with the line \`consult: report-back\`, then commits, every queued change written, how far it got (committed, pushed, deployed, applied) and what is open.
- Where its answer says "recorded <date>, not re-checked", check that statement yourself before acting on it.
EOF
exit 0
