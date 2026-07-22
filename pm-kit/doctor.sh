#!/usr/bin/env bash
# pm-kit/doctor.sh — health checks for a PM work-companion instance.
#
# The PM's memory discipline ("keep the index lean, compile out anything
# historical") is a written rule with no enforcement — this script IS the
# enforcement. Generic: zero project knowledge here; everything comes from a
# pm-kit.conf (default: ../pm-kit.conf next to this kit, or pass a path as the
# first non-flag argument).
#
# Usage:
#   doctor.sh [conf-path] [--strict]
#
# Default mode always exits 0 (safe to call from hooks). --strict exits 1 if
# any FAIL-level finding is present (index over hard budget, dangling links) —
# for manual runs and CI.
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"

STRICT=0
CONF=""
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) CONF="$arg" ;;
    esac
done
CONF="${CONF:-$KIT_DIR/../pm-kit.conf}"

if [ ! -f "$CONF" ]; then
    echo "pm-doctor: FAIL — conf not found: $CONF"
    [ "$STRICT" = 1 ] && exit 1
    exit 0
fi
# shellcheck disable=SC1090
. "$CONF"

WARNINGS=0
FAILS=0
warn() { echo "pm-doctor: WARN — $*"; WARNINGS=$((WARNINGS+1)); }
fail() { echo "pm-doctor: FAIL — $*"; FAILS=$((FAILS+1)); }
ok()   { echo "pm-doctor: ok   — $*"; }

# ── 1. Index byte budget ─────────────────────────────────────────────────────
if [ ! -f "$PM_INDEX" ]; then
    fail "index missing: $PM_INDEX"
else
    SIZE=$(wc -c < "$PM_INDEX")
    if [ "$SIZE" -gt "$PM_BUDGET_FAIL" ]; then
        fail "index is ${SIZE} bytes (> hard budget ${PM_BUDGET_FAIL}) — you owe a compaction: compile narration out to topic-file Build logs"
    elif [ "$SIZE" -gt "$PM_BUDGET_WARN" ]; then
        warn "index is ${SIZE} bytes (> soft budget ${PM_BUDGET_WARN}) — compaction due soon"
    else
        ok "index ${SIZE} bytes (budget ${PM_BUDGET_WARN}/${PM_BUDGET_FAIL})"
    fi

    # ── 2. Oversized lines (narration masquerading as routing) ───────────────
    OVER=$(awk -v max="$PM_LINE_WARN" 'length($0)>max { printf "    line %d (%d bytes): %s...\n", NR, length($0), substr($0,1,60) }' "$PM_INDEX")
    if [ -n "$OVER" ]; then
        warn "index lines over ${PM_LINE_WARN} bytes (move narration to the topic file's Build log):"
        printf '%s\n' "$OVER"
    else
        ok "no index line over ${PM_LINE_WARN} bytes"
    fi

    # ── 3. Dated blockquotes accumulating in the index ───────────────────────
    DATED=$(grep -c '^> \*\*20[0-9][0-9]-' "$PM_INDEX" || true)
    if [ "${DATED:-0}" -gt "$PM_DATED_WARN" ]; then
        warn "index holds ${DATED} dated blockquote entries (> ${PM_DATED_WARN}) — journal entries belong in the journal/topic files"
    else
        ok "dated blockquotes in index: ${DATED:-0} (<= ${PM_DATED_WARN})"
    fi

    # ── 4. Dangling links index -> topic files ───────────────────────────────
    MEM_BASE="$(basename "$PM_MEMORY_DIR")"
    INDEX_DIR="$(dirname "$PM_INDEX")"
    DANGLING=""
    while IFS= read -r rel; do
        [ -e "$INDEX_DIR/$rel" ] || DANGLING="${DANGLING}    $rel"$'\n'
    done < <(grep -o "]("$MEM_BASE"/[^)]*)" "$PM_INDEX" | sed 's/^](//; s/)$//' | sed 's/#.*$//' | sort -u)
    if [ -n "$DANGLING" ]; then
        fail "index links to missing topic files:"
        printf '%s' "$DANGLING"
    else
        ok "all index topic-file links resolve"
    fi

    # ── 5. Orphan topic files (referenced nowhere) ───────────────────────────
    if [ -d "$PM_MEMORY_DIR" ]; then
        ORPHANS=""
        while IFS= read -r f; do
            base="$(basename "$f")"
            if ! grep -rql -- "$base" "$PM_INDEX" "$PM_MEMORY_DIR" --include='*.md' --exclude="$base" 2>/dev/null; then
                ORPHANS="${ORPHANS}    ${f#"$PM_MEMORY_DIR"/}"$'\n'
            fi
        done < <(find "$PM_MEMORY_DIR" -name '*.md' -type f)
        if [ -n "$ORPHANS" ]; then
            warn "topic files referenced neither by the index nor by any other topic file:"
            printf '%s' "$ORPHANS"
        else
            ok "no orphan topic files"
        fi
    fi
fi

# ── 6. Agent-definition copy drift ───────────────────────────────────────────
if [ -f "$PM_AGENT_CANONICAL" ] && [ -f "$PM_AGENT_INSTALLED" ]; then
    if [ "$(md5sum < "$PM_AGENT_CANONICAL")" != "$(md5sum < "$PM_AGENT_INSTALLED")" ]; then
        warn "agent definition drift: $PM_AGENT_INSTALLED != $PM_AGENT_CANONICAL (re-copy / re-run bootstrap)"
    else
        ok "agent definition copies in sync"
    fi
elif [ ! -f "$PM_AGENT_INSTALLED" ]; then
    warn "agent definition not installed at $PM_AGENT_INSTALLED"
fi

# ── 7. Multi-dev git sync state (memory paths) ───────────────────────────────
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    MEM_REL_INDEX="${PM_INDEX#"$REPO_ROOT"/}"
    MEM_REL_DIR="${PM_MEMORY_DIR#"$REPO_ROOT"/}"
    if git -C "$REPO_ROOT" rev-parse '@{u}' >/dev/null 2>&1; then
        AHEAD=$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        BEHIND=$(git -C "$REPO_ROOT" rev-list --count 'HEAD..@{u}' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        [ "${AHEAD:-0}" -gt 0 ] && warn "${AHEAD} memory commit(s) not pushed — pm-sync push may be stuck (pull, then push)"
        [ "${BEHIND:-0}" -gt 0 ] && warn "${BEHIND} memory commit(s) on upstream not pulled — another dev updated the brain: PULL BEFORE CONSULTING THE PM"
        [ "${AHEAD:-0}" = 0 ] && [ "${BEHIND:-0}" = 0 ] && ok "memory in sync with upstream"
    fi
    FETCH_HEAD="$(git -C "$REPO_ROOT" rev-parse --git-dir)/FETCH_HEAD"
    if [ -f "$FETCH_HEAD" ]; then
        AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$FETCH_HEAD") ) / 3600 ))
        [ "$AGE_H" -gt 24 ] && warn "last git fetch was ${AGE_H}h ago — brain freshness unknown (git pull)"
    else
        warn "never fetched from remote — brain freshness unknown (git pull)"
    fi
fi

# ── 8. Dormant topic files (telemetry-backed) ────────────────────────────────
if [ -f "${PM_LOAD_LOG:-/nonexistent}" ] && [ -d "$PM_MEMORY_DIR" ]; then
    CUTOFF=$(date -d "-${PM_DORMANT_DAYS} days" +%F 2>/dev/null || date -v -"${PM_DORMANT_DAYS}"d +%F)
    RECENT=$(awk -F'\t' -v c="$CUTOFF" '$1 >= c { print $2 }' "$PM_LOAD_LOG" | sort -u)
    DORMANT=0
    DORMANT_LIST=""
    while IFS= read -r f; do
        rel="${f#"$PM_MEMORY_DIR"/}"
        if ! printf '%s\n' "$RECENT" | grep -qx -- "$rel"; then
            DORMANT=$((DORMANT+1))
            [ "$DORMANT" -le 10 ] && DORMANT_LIST="${DORMANT_LIST}    ${rel}"$'\n'
        fi
    done < <(find "$PM_MEMORY_DIR" -name '*.md' -type f)
    if [ "$DORMANT" -gt 0 ]; then
        warn "${DORMANT} topic file(s) with zero recorded loads in ${PM_DORMANT_DAYS} days (dead pointer or mis-matched trigger — first 10):"
        printf '%s' "$DORMANT_LIST"
    fi
else
    ok "no load telemetry yet (dormancy check skipped)"
fi

echo "pm-doctor: ${FAILS} fail(s), ${WARNINGS} warning(s)"
if [ "$STRICT" = 1 ] && [ "$FAILS" -gt 0 ]; then exit 1; fi
exit 0
