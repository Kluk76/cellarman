#!/usr/bin/env bash
# pm-sync.example.sh — sweep PM-memory changes into git + push, so the shared
# PM brain stays in sync without anyone remembering to commit it.
#
# Wire as a Claude Code PostToolUse hook gated on git commit / git push (see
# the cellarman README). Run manually any time too.
#
# SAFE BY DESIGN:
#   - commits ONLY the PM-memory paths (never your code changes)
#   - no-op if the memory hasn't changed
#   - best-effort push; if the remote moved on (non-ff), the memory commit just
#     waits locally for your next pull+push — it is never lost (the doctor
#     surfaces the stuck state)
#   - NEVER rebases/merges (so it can't leave a half-resolved conflict)
#   - always exits 0 (a hook must not break your workflow)
set +e

REPO="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (this script lives in claude-brain/)
cd "$REPO" 2>/dev/null || exit 0

CONF="$REPO/claude-brain/pm-kit.conf"
[ -f "$CONF" ] || exit 0
REPO_ROOT="$REPO" KIT_DIR="$REPO/claude-brain/pm-kit" . "$CONF" 2>/dev/null || exit 0

MEM="${PM_MEMORY_DIR#"$REPO"/}"
MEM_MD="${PM_INDEX#"$REPO"/}"

# Anything to sync? (unstaged OR staged changes under the memory tree)
if git diff --quiet -- "$MEM" "$MEM_MD" 2>/dev/null \
   && git diff --cached --quiet -- "$MEM" "$MEM_MD" 2>/dev/null; then
    exit 0
fi

git add -- "$MEM" "$MEM_MD" 2>/dev/null
git commit -q -m "chore(pm-memory): auto-sync" -- "$MEM" "$MEM_MD" 2>/dev/null \
    && echo "[pm-sync] committed PM-memory changes"

if git push -q 2>/dev/null; then
    echo "[pm-sync] pushed PM memory"
else
    echo "[pm-sync] PM memory committed locally; push deferred (pull+push when ready)"
fi

# Health check (warn-only — doctor always exits 0 without --strict).
if [ -x "$REPO/claude-brain/pm-kit/doctor.sh" ]; then
    "$REPO/claude-brain/pm-kit/doctor.sh" 2>/dev/null | grep -E "WARN|FAIL" | sed 's/^/[pm-sync] /'
fi
exit 0
