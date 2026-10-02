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
# EXIT CODES
#   0  default mode: always, whatever was found (safe to call from hooks; read
#      the "pm-doctor: WARN/FAIL" lines). --strict: no FAIL-level finding.
#   1  --strict only: at least one FAIL-level finding (index over the hard
#      budget, dangling links, an agent file without a kernel or with a kernel
#      token that has no bindings row, a session prefix that differs from the
#      profile's, two different index paths, divergent
#      register states).
#   3  DID NOT RUN, in either mode: the conf file was not found, so nothing
#      was measured. 3 is the kit-wide code for "did not run".
#
# CHECKS (each prints ok / WARN / FAIL / info, or UNMEASURED when a tool is missing)
#   1-5   index budget, long lines, dated blockquotes, dangling links, orphans
#   6-8b  oversized topic files, archive retention, agent-file copy drift, skill mirror
#   9-11  git sync of the memory paths, dormancy, dead links between topic files
#   12    arbitration register: router vs bodies (PF_ARB_FILE)
#   13    agent file: kernel present, no paste placeholder, tokens vs bindings
#         rows, ${SESSION_PREFIX} binding equals PF_SESSION_PREFIX, kernel
#         identical to PROTOCOL.md
#   14    hook wiring in settings.json (info only: hooks are optional)
#   15    rails written outside "- " list items (the rails miner never sees them)
#   16    PM_INDEX (pm-kit.conf) and PF_PM_INDEX (profile) name the same file
# Started by another shell (zsh, sh)? These scripts use bash-only expansions
# (e.g. ${VAR:+-flag "$VAR"} word-splitting) — re-exec under bash, never degrade.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
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
    echo "pm-doctor: NOT RUN — conf not found: $CONF (nothing was measured)"
    exit 3
fi
# shellcheck disable=SC1090
. "$CONF"

# ── profile values (closure vocabulary) ─────────────────────────────────────
# The doctor is configured by pm-kit.conf, but the arbitration closure
# vocabulary lives in the PROFILE (PF_ARB_CLOSED_RE) because pm-preflight reads
# it too. The profile is sourced in a SUBSHELL and only that one value is taken:
# a profile repeating a PM_* name must never override pm-kit.conf here.
# Profile = $PM_PROFILE (path, or a bare name under pm-kit/profiles/), else the
# single pm-kit/profiles/*.conf. None found => the default below.
_PROFILE_FILE=""
if [ -n "${PM_PROFILE:-}" ] && [ -f "$PM_PROFILE" ]; then
    _PROFILE_FILE="$PM_PROFILE"
elif [ -n "${PM_PROFILE:-}" ] && [ -f "$KIT_DIR/profiles/$PM_PROFILE.conf" ]; then
    _PROFILE_FILE="$KIT_DIR/profiles/$PM_PROFILE.conf"
elif [ -z "${PM_PROFILE:-}" ] && [ -d "$KIT_DIR/profiles" ]; then
    _N=$(find "$KIT_DIR/profiles" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
    [ "$_N" = 1 ] && _PROFILE_FILE=$(find "$KIT_DIR/profiles" -maxdepth 1 -name '*.conf')
fi
# _prof <VAR>: one profile value, read in a subshell (never leaks into this scope).
_prof() {
    [ -n "$_PROFILE_FILE" ] || return 0
    ( . "$_PROFILE_FILE" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" )
}
ARB_CLOSED_RE="$(_prof PF_ARB_CLOSED_RE)"
ARB_ID_RE="$(_prof PF_ARB_ID_RE)"
ARB_HEADER_RE="$(_prof PF_ARB_HEADER_RE)"
ARB_FILE_REL="$(_prof PF_ARB_FILE)"
[ -n "$ARB_CLOSED_RE" ] || ARB_CLOSED_RE='CLOSED|DONE|RESOLVED|ANSWERED|OBSOLETE'
# Dates are spelled out, not {8}: mawk 1.3.4 has no interval expressions (the
# register check below silently matched nothing under it). Same default as pm-preflight.
[ -n "$ARB_ID_RE" ] || ARB_ID_RE='H-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[a-z]-[a-z0-9-]+'
# Same default as pm-preflight P6: any level-3 heading, the id RE then filters.
[ -n "$ARB_HEADER_RE" ] || ARB_HEADER_RE='^### '
export ARB_CLOSED_RE ARB_ID_RE ARB_HEADER_RE

WARNINGS=0
FAILS=0
warn() { echo "pm-doctor: WARN — $*"; WARNINGS=$((WARNINGS+1)); }
fail() { echo "pm-doctor: FAIL — $*"; FAILS=$((FAILS+1)); }
ok()   { echo "pm-doctor: ok   — $*"; }
# info: neither a pass nor a problem (an optional piece that is simply absent).
# Never matches the "WARN|FAIL" prefixes the pre-flight parses.
info() { echo "pm-doctor: info — $*"; }
# A check that shells out to a tool the machine lacks must say UNMEASURED: its
# command's error is usually swallowed (2>/dev/null) and what remains is an
# empty string that reads as "nothing found" — a false green. Returns 1 (after
# a WARN) when any named tool is missing, so the caller skips the check.
_need() {
    local c="$1" t; shift
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || { warn "$c UNMEASURED — required tool '$t' not found on PATH"; return 1; }
    done
    return 0
}

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

# ── 6. Oversized topic files (a file doing a directory's job) ────────────────
# The index budget is blind to the corpus: a topic file can double the split
# threshold for weeks and no check says a word. Past that size a single file is
# a directory waiting to happen — split it and turn the old file into a small
# pointer index.
#
# The archive directory is EXCLUDED: a verbatim snapshot is meant to be one
# monolithic block — splitting it would destroy the thing it exists for. Its
# size is check 7's business, and letting check 6 shout about it buries the
# real signal under six lines of noise.
if [ -d "$PM_MEMORY_DIR" ] && _need "topic-file size check (6)" find wc awk sort head; then
    TOPIC_WARN="${PM_TOPIC_WARN:-81920}"
    # `find -printf` is GNU-only (BSD find errors, the 2>/dev/null hid it and the
    # check printed "ok" unmeasured): list with -print, size with wc -c.
    BIG=$(find "$PM_MEMORY_DIR" \
              ${PM_ARCHIVE_DIR:+-path "$PM_ARCHIVE_DIR" -prune -o} \
              -name '*.md' -type f -print 2>/dev/null \
          | while IFS= read -r f; do printf '%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "${f#"$PM_MEMORY_DIR"/}"; done \
          | awk -F'\t' -v max="$TOPIC_WARN" '$1 > max' \
          | sort -rn | head -10 \
          | awk -F'\t' '{ printf "    %4d KB  %s\n", $1/1024, $2 }')
    if [ -n "$BIG" ]; then
        warn "topic file(s) over $((TOPIC_WARN/1024)) KB — split into a directory + pointer index (largest first):"
        printf '%s\n' "$BIG"
    else
        ok "no topic file over $((TOPIC_WARN/1024)) KB"
    fi
fi

# ── 7. Archive retention (verbatim snapshots) ────────────────────────────────
# Pre-compaction snapshots are a safety net, not a store: git already holds
# every one of them (`git show <sha>:<index-path>`). They accumulate silently
# because nothing weighs them — check 1 measures the index alone, and check 5
# never calls them orphans since the archive README references them.
# Skipped entirely when PM_ARCHIVE_DIR is unset.
if [ -n "${PM_ARCHIVE_DIR:-}" ] && [ -d "$PM_ARCHIVE_DIR" ] && _need "archive retention check (7)" find wc awk; then
    ARCH_MAX="${PM_ARCHIVE_MAX:-3}"
    ARCH_GLOB="${PM_ARCHIVE_GLOB:-index-verbatim-*.md}"
    ARCH_N=$(find "$PM_ARCHIVE_DIR" -maxdepth 1 -name "$ARCH_GLOB" -type f 2>/dev/null | wc -l)
    ARCH_KB=$(find "$PM_ARCHIVE_DIR" -maxdepth 1 -name "$ARCH_GLOB" -type f -print 2>/dev/null \
              | while IFS= read -r f; do wc -c < "$f"; done \
              | awk '{ s += $1 } END { printf "%d", (s+0)/1024 }')
    if [ "${ARCH_N:-0}" -gt "$ARCH_MAX" ]; then
        warn "${ARCH_N} archived snapshot(s) matching '${ARCH_GLOB}' (> ${ARCH_MAX}), ${ARCH_KB} KB — they are reconstructible with 'git show <sha>:<index>'; keep the newest ${ARCH_MAX} and replace the rest with a git-show line"
    else
        ok "archived snapshots: ${ARCH_N:-0} (<= ${ARCH_MAX}), ${ARCH_KB:-0} KB"
    fi
fi

# ── 8. Agent-definition copy drift ───────────────────────────────────────────
# 🔴 COMPARE AFTER PATH NORMALIZATION, never raw bytes.
# Some install flows rewrite absolute paths at copy time — e.g. a bootstrap
# script that rewrites the original author's $HOME/repo-root into the
# INSTALLING machine's own $HOME/repo-root. On any machine that is not the
# one the canonical copy was authored on, a raw md5 diverges BY CONSTRUCTION
# and this check could NEVER go green. Measured 2026-08-13 on dev B's
# machine: the installed definition was up to date, correctly rewritten by
# the installer, and the check still fired anyway — and ⭐ a detector that
# shouts every single run stops being read on the day it is right. So we
# apply the SAME rewrite the installer performs before comparing; a
# remaining difference is then a REAL copy lag.
#
# Entirely conf-driven and optional — with nothing set below this is a
# no-op passthrough (safe on a fresh install where no such rewrite ever
# happened, or where the checking machine IS the authoring machine):
#   PM_BOOTSTRAP_SOURCE_ROOT — the original repo root the installer rewrites
#                              FROM (e.g. /home/alice/projects/myapp).
#                              Unset = no root rewrite applied.
#   PM_BOOTSTRAP_SOURCE_HOME — the original $HOME the installer rewrites
#                              FROM. Unset = no $HOME rewrite applied.
#   PM_PATH_ALIASES          — colon-separated old=new path-fragment pairs
#                              for anything the two above cannot express —
#                              e.g. a historical project rename that left
#                              old path fragments baked into a canonical
#                              file ("/projects/oldname=/projects/newname").
#                              Unset = no aliasing applied.
_norm_agent_def() {
    local -a sed_args=()
    if [ -n "${PM_BOOTSTRAP_SOURCE_ROOT:-}" ]; then
        sed_args+=(-e "s|$(printf '%s' "$PM_BOOTSTRAP_SOURCE_ROOT" | tr '/' '-')|$(printf '%s' "$REPO_ROOT" | tr '/' '-')|g")
        sed_args+=(-e "s|${PM_BOOTSTRAP_SOURCE_ROOT}|${REPO_ROOT}|g")
        sed_args+=(-e "s|$(dirname "$PM_BOOTSTRAP_SOURCE_ROOT")|$(dirname "$REPO_ROOT")|g")
    fi
    if [ -n "${PM_BOOTSTRAP_SOURCE_HOME:-}" ]; then
        sed_args+=(-e "s|${PM_BOOTSTRAP_SOURCE_HOME}|${HOME}|g")
    fi
    if [ -n "${PM_PATH_ALIASES:-}" ]; then
        local pair old new
        IFS=':' read -ra _pairs <<< "$PM_PATH_ALIASES"
        for pair in "${_pairs[@]}"; do
            old="${pair%%=*}"; new="${pair#*=}"
            sed_args+=(-e "s|${old}|${new}|g")
        done
    fi
    if [ "${#sed_args[@]}" -eq 0 ]; then
        cat "$1"
    else
        sed "${sed_args[@]}" "$1"
    fi
}
if [ -f "$PM_AGENT_CANONICAL" ] && [ -f "$PM_AGENT_INSTALLED" ]; then
    # Compared with `cmp -s`, not a checksum tool: where md5sum is absent both
    # sides of the old comparison were empty strings and every pair read "in sync".
    if _need "agent definition drift check (8)" cmp; then
        _norm_agent_def "$PM_AGENT_CANONICAL" | cmp -s - "$PM_AGENT_INSTALLED"; _CMP_RC=$?
        case "$_CMP_RC" in
            0) ok "agent definition copies in sync" ;;
            1) warn "agent definition drift: $PM_AGENT_INSTALLED != $PM_AGENT_CANONICAL (re-copy / re-run bootstrap)" ;;
            *) warn "agent definition drift check (8) UNMEASURED — cmp failed (rc=$_CMP_RC)" ;;
        esac
    fi
elif [ ! -f "$PM_AGENT_INSTALLED" ]; then
    warn "agent definition not installed at $PM_AGENT_INSTALLED"
fi

# ── 8b. Skill mirror drift ───────────────────────────────────────────────────
# Check 8 watches ONE file (the agent definition) and stopped there, so the
# skill store — dozens of files, mirrored by the same one-directional publish —
# drifted unwatched. Dev B's edits were overwritten TWICE on 2026-08-03 with no
# signal, because `publish.sh` copies live → mirror and never merges.
#
# 🔴 THE TELL IS DIRECTION, NOT DIFFERENCE. A mirror file that is merely
# different is usually just a publish that has not run yet — harmless. A mirror
# file NEWER than its live twin is work that exists only in the mirror, and the
# next publish deletes it. Those are the only ones worth waking someone for, so
# they are counted and named separately.
if [ -n "${PM_SKILLS_LIVE:-}" ] && [ -n "${PM_SKILLS_MIRROR:-}" ] \
   && [ -d "$PM_SKILLS_LIVE" ] && [ -d "$PM_SKILLS_MIRROR" ] \
   && _need "skill mirror drift check (8b)" cmp find; then
    SK_AT_RISK=""; SK_AT_RISK_N=0; SK_STALE_N=0; SK_ONLY_MIRROR=""
    while IFS= read -r M; do
        REL="${M#"$PM_SKILLS_MIRROR"/}"
        L="$PM_SKILLS_LIVE/$REL"
        if [ ! -f "$L" ]; then
            # In the mirror, absent from live: either a skill deleted upstream
            # (publish will not remove it) or content that only ever existed
            # here. Both are worth naming; neither is automatically a loss.
            SK_ONLY_MIRROR="$SK_ONLY_MIRROR $REL"
            continue
        fi
        cmp -s "$M" "$L" && continue
        if [ "$M" -nt "$L" ]; then
            SK_AT_RISK_N=$((SK_AT_RISK_N + 1))
            SK_AT_RISK="$SK_AT_RISK $REL"
        else
            SK_STALE_N=$((SK_STALE_N + 1))
        fi
    done <<EOF
$(find "$PM_SKILLS_MIRROR" -type f -name '*.md' 2>/dev/null)
EOF
    if [ "$SK_AT_RISK_N" -gt 0 ]; then
        warn "${SK_AT_RISK_N} MIRROR skill file(s) NEWER than the live copy — the next publish.sh DELETES these edits (copy them into $PM_SKILLS_LIVE first):$SK_AT_RISK"
    fi
    if [ -n "$SK_ONLY_MIRROR" ]; then
        warn "skill file(s) present in the mirror but absent from live — publish.sh never removes, so these are either deleted-upstream leftovers or mirror-only work:$SK_ONLY_MIRROR"
    fi
    if [ "$SK_AT_RISK_N" -eq 0 ] && [ -z "$SK_ONLY_MIRROR" ]; then
        ok "skill mirror: no mirror-only work at risk (${SK_STALE_N} file(s) merely awaiting a publish)"
    fi
fi

# ── 9. Multi-dev git sync state (memory paths) ───────────────────────────────
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    MEM_REL_INDEX="${PM_INDEX#"$REPO_ROOT"/}"
    MEM_REL_DIR="${PM_MEMORY_DIR#"$REPO_ROOT"/}"
    if git -C "$REPO_ROOT" rev-parse '@{u}' >/dev/null 2>&1; then
        AHEAD=$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        BEHIND=$(git -C "$REPO_ROOT" rev-list --count 'HEAD..@{u}' -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null || echo 0)
        [ "${AHEAD:-0}" -gt 0 ] && warn "${AHEAD} memory commit(s) not pushed — pm-sync push may be stuck (pull, then push)"
        [ "${BEHIND:-0}" -gt 0 ] && warn "${BEHIND} memory commit(s) on upstream not pulled — another dev updated the brain: PULL BEFORE CONSULTING THE PM"
        # 🔴 SCOPE, stated in the message on purpose. This check pathspec-limits to the
        # two MEMORY paths. It is blind to db/migrations/, public/, app/ and bin/ — i.e.
        # to every surface where the two devs actually collide. Measured 2026-08-06: this
        # said "in sync" while six of origin/main's migrations were absent from disk, five
        # of them the other dev's. A green whose scope is not named IS a false green.
        # Repo-wide divergence + a real fetch belong to pm-preflight P1; this check is
        # deliberately NOT widened, so the two instruments cannot drift apart.
        [ "${AHEAD:-0}" = 0 ] && [ "${BEHIND:-0}" = 0 ] && ok "MEMORY paths in sync with upstream (code surfaces NOT checked here — run bin/pm-preflight.sh)"
    fi
    FETCH_HEAD="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir 2>/dev/null || git -C "$REPO_ROOT" rev-parse --git-dir)/FETCH_HEAD"   # bare --git-dir is CWD-relative: wrong file when invoked from outside the repo
    if [ -z "$(git -C "$REPO_ROOT" remote 2>/dev/null)" ]; then
        # Solo mode: with no remote there is nothing to fetch, so "never fetched" is
        # not a finding about this project.
        ok "fetch age: n/a (no remote configured: single-clone mode)"
    elif [ -f "$FETCH_HEAD" ]; then
        # `stat -c` is GNU-only: on BSD/macOS it prints "illegal option -- c" and
        # SUBSTITUTES NOTHING, so the arithmetic became `( 1785343838 - ) / 3600`
        # — a shell syntax error the script printed and then walked past, still
        # reporting "0 fail(s)". Measured on dev B's Mac 2026-07-29: this check
        # had never run there, while the PM index sat at 86 049 B.
        # ⇒ A check that prints its own failure and still returns green is worse
        #   than an absent check: the absent one is visibly absent.
        # `stat -f %m` is the BSD spelling; try GNU first, fall back, and if
        # NEITHER works say UNMEASURED rather than inventing an age.
        MTIME="$(stat -c %Y "$FETCH_HEAD" 2>/dev/null || stat -f %m "$FETCH_HEAD" 2>/dev/null || echo '')"
        case "$MTIME" in
            ''|*[!0-9]*)
                warn "cannot read the mtime of FETCH_HEAD on this platform — fetch age UNMEASURED (neither 'stat -c' nor 'stat -f' worked)" ;;
            *)
                AGE_H=$(( ( $(date +%s) - MTIME ) / 3600 ))
                [ "$AGE_H" -gt 24 ] && warn "last git fetch was ${AGE_H}h ago — brain freshness unknown (git pull)" ;;
        esac
    else
        warn "never fetched from remote — brain freshness unknown (git pull)"
    fi

    # ── 9b. Uncommitted memory edits, right now ──────────────────────────────
    # Check 9 compares COMMITTED state to upstream — it is blind to a
    # concurrent session editing the memory tree in the shared worktree. That
    # blindness nearly cost a compaction pass: a draft built from a 20-minute-
    # old read would have overwritten another session's fresher measurements,
    # a regression wearing the costume of tidying.
    # Informational by design: pm-sync commits on a cron, so a dirty memory
    # tree right after a recording is NORMAL and must not raise a warning.
    # The value is the LIST — if you did not touch one of these files, someone
    # else is writing, and you diff before you rewrite.
    DIRTY=$(git -C "$REPO_ROOT" status --porcelain -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null \
            | awk '{ $1=$1; print }' | cut -d' ' -f2- | head -10)
    if [ -n "$DIRTY" ]; then
        DIRTY_N=$(git -C "$REPO_ROOT" status --porcelain -- "$MEM_REL_INDEX" "$MEM_REL_DIR" 2>/dev/null | wc -l)
        ok "${DIRTY_N} uncommitted memory path(s) — diff before rewriting any you did not touch:"
        printf '%s\n' "$DIRTY" | sed 's/^/    /'
    else
        ok "memory tree clean (no uncommitted edits)"
    fi
fi

# ── 10. Dormant topic files (telemetry-backed) ───────────────────────────────
if [ -f "${PM_LOAD_LOG:-/nonexistent}" ] && [ -d "$PM_MEMORY_DIR" ]; then
    DORM_DAYS="${PM_DORMANT_DAYS:-90}"
    CUTOFF=$(date -d "-${DORM_DAYS} days" +%F 2>/dev/null || date -v -"${DORM_DAYS}"d +%F 2>/dev/null || true)
    if [ -z "$CUTOFF" ]; then
        warn "dormancy check (10) UNMEASURED — neither 'date -d' nor 'date -v' could compute the cutoff"
    else
    RECENT=$(awk -F'\t' -v c="$CUTOFF" '$1 >= c { print $2 }' "$PM_LOAD_LOG" | sort -u)
    DORMANT=0
    DORMANT_LIST=""
    # Only files OLDER than the window can be dormant: "zero loads in N days" says
    # nothing about a file that did not exist N days ago (a topic file created
    # today was reported as a dead pointer).
    while IFS= read -r f; do
        rel="${f#"$PM_MEMORY_DIR"/}"
        if ! printf '%s\n' "$RECENT" | grep -qx -- "$rel"; then
            DORMANT=$((DORMANT+1))
            [ "$DORMANT" -le 10 ] && DORMANT_LIST="${DORMANT_LIST}    ${rel}"$'\n'
        fi
    done < <(find "$PM_MEMORY_DIR" -name '*.md' -type f -mtime +"$DORM_DAYS")
    if [ "$DORMANT" -gt 0 ]; then
        warn "${DORMANT} topic file(s) older than ${DORM_DAYS} days with zero recorded loads in that window (dead pointer or mis-matched trigger — first 10):"
        printf '%s' "$DORMANT_LIST"
    fi
    fi
else
    ok "no load telemetry yet (dormancy check skipped)"
fi

# ── 11. Dead relative links INSIDE the corpus (topic → topic) ────────────────
# Check 4 walks index → topic: the graph the index owns. This walks the OTHER
# half — topic → topic — which nothing watched, so a file citing one that was
# renamed or relocated kept a dead link forever while the doctor reported
# all-clear. Found the hard way on 2026-07-29 (three pruned snapshots, index
# clean, two dead links inside an unrelated arc file).
#
# WARN-only, and deliberately so: this surfaces a large PRE-EXISTING debt
# (relocation leaves the text moved and the paths behind). A FAIL tier would
# break --strict on day one and the check would be switched off, which is worse
# than the debt. The archive directory is excluded — a verbatim snapshot is
# frozen by definition, so its stale paths are historical facts, not defects.
if [ -d "$PM_MEMORY_DIR" ]; then
    DEAD_N=0
    DEAD_LIST=""
    # VERBATIM SNAPSHOTS are counted APART and never as defects. A snapshot is a
    # word-for-word copy of an earlier index; its links were written from the
    # index's own directory and will NEVER be rewritten, because rewriting them
    # would destroy the one thing that gives the snapshot its value. Each carries
    # a LINK-RESOLUTION KEY in its head (`<!-- LINK-RESOLUTION-KEY -->`) naming the
    # prefix to apply. Counting them as defects produced hundreds of permanent
    # alerts on the origin project, and a detector that shouts on every run stops
    # being read on the day it is right. A file is recognised as a snapshot only if
    # it CARRIES the key: a name that merely looks like one is checked normally.
    SNAP_N=0
    ABS_N=0
    ABS_LIST=""
    while IFS= read -r f; do
        FDIR="$(dirname "$f")"
        IS_SNAP=0
        grep -q 'LINK-RESOLUTION-KEY' "$f" 2>/dev/null && IS_SNAP=1
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            case "$p" in http*|mailto:*|'<'*) continue ;; esac
            # An ABSOLUTE path is not a relative link: counting it here produced a
            # permanent, FALSE alert. The ones found point into a developer's
            # PERSONAL auto-recall memory (/home/<dev>/.claude/projects/...), which
            # by construction does not exist on another developer's machine and
            # which nothing in this repository can repair. Counted apart, said
            # once, never a defect.
            case "$p" in
                /*) if [ ! -e "$p" ]; then
                        ABS_N=$((ABS_N+1))
                        [ "$ABS_N" -le 3 ] && ABS_LIST="${ABS_LIST}    ${f#"$PM_MEMORY_DIR"/} → ${p}"$'\n'
                    fi
                    continue ;;
            esac
            [ -e "$FDIR/$p" ] && continue
            if [ "$IS_SNAP" = 1 ]; then
                SNAP_N=$((SNAP_N+1))
                continue
            fi
            DEAD_N=$((DEAD_N+1))
            [ "$DEAD_N" -le 10 ] && DEAD_LIST="${DEAD_LIST}    ${f#"$PM_MEMORY_DIR"/} → ${p}"$'\n'
        done < <(grep -o ']([^)]*)' "$f" 2>/dev/null \
                 | sed 's/^](//; s/)$//; s/#.*$//' | grep '\.md$')
    done < <(find "$PM_MEMORY_DIR" \
                 ${PM_ARCHIVE_DIR:+-path "$PM_ARCHIVE_DIR" -prune -o} \
                 -name '*.md' -type f -print)
    if [ "$DEAD_N" -gt 0 ]; then
        warn "${DEAD_N} dead relative link(s) between topic files (invisible to check 4 — it only walks index → topic; first 10):"
        printf '%s' "$DEAD_LIST"
    else
        ok "no dead relative link between topic files"
    fi
    if [ "$SNAP_N" -gt 0 ]; then
        ok "verbatim snapshots: ${SNAP_N} index-relative link(s), NOT counted as defects (each file carries a link-resolution key in its head)"
    fi
    if [ "$ABS_N" -gt 0 ]; then
        ok "${ABS_N} link(s) with an ABSOLUTE path into a developer's personal memory: not repairable from this repository, never counted as defects:"
        printf '%s' "$ABS_LIST"
    fi
fi

# ── 12. Register router vs bodies: compare STATE, not only PRESENCE ───────────
# pm-preflight P6 reads ONE file (PF_ARB_FILE, the router) and parses only its
# header lines. When the bodies live in a directory of the same name (the router
# keeps only the headers), what makes that safe is not one invariant but TWO: every
# item has its header on both sides, AND both headers carry the SAME state.
#
# Why state and not presence: a guard that checks that a key EXISTS says nothing
# about its VALUE, and here the value drives the escalation. The failure mode of a
# gate that reads a partial population is not a missing alert, it is a reassuring
# alert about the wrong population. Three defects of the presence-only version:
#   1. blind to "router OPEN / body CLOSED": the answer is written in the right
#      place, in the right vocabulary, and the item keeps ageing anyway, pushing
#      toward an escalation of a question already settled;
#   2. the opposite direction (router CLOSED / body OPEN) was flagged with a WRONG
#      diagnosis ("absent from the router" when it is there), and it is the worse
#      of the two: a genuinely open question stops being counted;
#   3. blind to a router header with NO body (everything fits in the router line):
#      P6 sees it so nothing lies, but the item has nowhere to receive an answer.
# A CLOSED body with no router header is SILENT and must stay so: it is the normal
# state of any archived item whose router header was removed.
#
# Paths: the router is PF_ARB_FILE (profile, repo-relative); the bodies directory
# is the router's path without ".md". With no PF_ARB_FILE the check is n/a.
HR=""
[ -n "$ARB_FILE_REL" ] && HR="$REPO_ROOT/$ARB_FILE_REL"
HD="${HR%.md}"
if [ -z "$HR" ]; then
    ok "register router vs bodies: n/a (no arbitration register declared: PF_ARB_FILE is empty)"
elif [ -f "$HR" ] && [ -d "$HD" ]; then
    # One awk pass: the router first, then the bodies, told apart by FILENAME
    # (never by ARGIND, a gawk extension that would make the guard mute under mawk,
    # the exact case it exists against).
    _RC="$(awk -v RFILE="$HR" '
      BEGIN { hre = ENVIRON["ARB_HEADER_RE"]; idre = ENVIRON["ARB_ID_RE"]; cre = ENVIRON["ARB_CLOSED_RE"] }
      $0 ~ hre {
        if (!match($0, idre)) next
        id = substr($0, RSTART, RLENGTH)
        # SAME closure vocabulary as pm-preflight P6 (profile variable
        # PF_ARB_CLOSED_RE): here it covers what P6 cannot see, the BODY headers.
        # No ASCII apostrophe in this block: it lives between shell single quotes.
        st = ($0 ~ ("· *(" cre ")")) ? "closed" : "open"
        if (st == "open") {
          if ($0 ~ ("· *[^A-Za-z0-9]* *(" cre ")")) f[id]="OFF-TEMPLATE"
          else if ($0 ~ ("(" cre ")"))              f[id]="SUSPECT"
        }
        if (FILENAME == RFILE) {
          if (id in r && r[id] != st) r[id] = "INTERNAL-CONFLICT"; else r[id] = st
          nrouter++
        } else {
          if (id in b && b[id] != st) b[id] = "INTERNAL-CONFLICT"; else b[id] = st
        }
      }
      END {
        for (id in r) {
          if (!(id in b))      { print "ROUTER-WITHOUT-BODY\t" id "\t" r[id]; continue }
          if (r[id] != b[id])    print "DIVERGENT\t" id "\trouter=" r[id] "\tbody=" b[id]
        }
        for (id in b) if (!(id in r) && b[id] == "open") print "BODY-WITHOUT-ROUTER\t" id "\t" b[id]
        for (id in f) print "OFF-VOCABULARY\t" id "\t" f[id] | "sort"
        print "COUNT\t" nrouter + 0
      }' "$HR" "$HD"/*.md 2>/dev/null)"

    _DIV="$(printf '%s\n' "$_RC" | grep '^DIVERGENT' || true)"
    _CSR="$(printf '%s\n' "$_RC" | grep '^BODY-WITHOUT-ROUTER' || true)"
    _RSC="$(printf '%s\n' "$_RC" | grep '^ROUTER-WITHOUT-BODY' || true)"
    _FMT="$(printf '%s\n' "$_RC" | grep '^OFF-VOCABULARY' || true)"
    N_ROUTER="$(printf '%s\n' "$_RC" | awk -F'\t' '$1=="COUNT"{n=$2} END{print n+0}')"

    # BSD sed does not read \t in a pattern (it matches a literal "t"): use a real TAB.
    _T="$(printf '\t')"
    if [ -n "$_DIV" ]; then
        fail "register router vs bodies: STATES DIVERGE. P6 reads only the router, so age and escalation follow the LEFT column:"
        printf '%s\n' "$_DIV" | sed "s/^DIVERGENT${_T}/    /" | sed "s/${_T}/  /g"
    fi
    if [ -n "$_CSR" ]; then
        fail "open items INVISIBLE to the pre-flight (in a body, NO header in the router):"
        printf '%s\n' "$_CSR" | sed "s/^BODY-WITHOUT-ROUTER${_T}/    /" | sed "s/${_T}.*//"
    fi
    if [ -n "$_RSC" ]; then
        warn "router header(s) WITHOUT a body: visible to P6, but with nowhere to receive an answer:"
        printf '%s\n' "$_RSC" | sed "s/^ROUTER-WITHOUT-BODY${_T}/    /" | sed "s/${_T}.*//"
    fi
    if [ -n "$_FMT" ]; then
        warn "header(s) OUTSIDE THE CLOSURE VOCABULARY, counted OPEN because they could not be read (' · <WORD>', WORD one of: ${ARB_CLOSED_RE}; the word GLUED to the ' · ', decoration AFTER it):"
        printf '%s\n' "$_FMT" | sed "s/^OFF-VOCABULARY${_T}/    /" | sed "s/${_T}/  /g"
    fi
    [ -z "$_DIV$_CSR$_RSC$_FMT" ] && ok "register router vs bodies: ${N_ROUTER:-0} header(s), states agree on both sides"
fi

# ── 13. Agent file vs the kernel (tokens, drift, placeholder) ────────────────
# Three checks on the agent file that carries the kernel. The file checked is the
# repository copy (PM_AGENT_CANONICAL), else the installed one.
#   (a) every ${TOKEN} inside the kernel markers has a row in the bindings table,
#       and every row names a token the kernel uses. A token without a row fails
#       quietly: the model reads the table and does the lookup.
#   (b) the kernel block is byte-identical to the one in PROTOCOL.md (kernel drift).
#   (c) the paste placeholder is gone.
_AGENT_FILE=""
if [ -f "${PM_AGENT_CANONICAL:-/nonexistent}" ]; then _AGENT_FILE="$PM_AGENT_CANONICAL"
elif [ -f "${PM_AGENT_INSTALLED:-/nonexistent}" ]; then _AGENT_FILE="$PM_AGENT_INSTALLED"; fi
# The marker lines may carry leading whitespace (an indented paste, an editor that
# re-indents); they are matched and printed without it, so detection and the
# byte comparison with PROTOCOL.md both tolerate it. Only the markers are trimmed.
_kernel_block() {
    awk '
      /^[ \t]*<!-- cellarman kernel: begin/ { k = 1; sub(/^[ \t]+/, "") }
      /^[ \t]*<!-- cellarman kernel: end/   { sub(/^[ \t]+/, ""); if (k) { print; k = 0; next } }
      k { print }' "$1"
}
if [ -z "$_AGENT_FILE" ]; then
    : # check 8 already said the agent definition is not installed
elif _need "agent file checks (13)" awk grep sort comm cmp mktemp; then
    _AF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pm-doctor.XXXXXX")" || _AF_TMP=""
    if [ -z "$_AF_TMP" ]; then
        warn "agent file checks (13) UNMEASURED — cannot create a temp dir"
    else
        _kernel_block "$_AGENT_FILE" > "$_AF_TMP/kernel"
        if grep -q 'PASTE-KERNEL-HERE' "$_AGENT_FILE"; then
            fail "agent file $_AGENT_FILE still carries the PASTE-KERNEL-HERE placeholder: the PM has no protocol (paste the kernel block of pm-kit/PROTOCOL.md between the two markers)"
        elif [ ! -s "$_AF_TMP/kernel" ]; then
            fail "agent file $_AGENT_FILE has no kernel block (no '<!-- cellarman kernel: begin -->' ... 'end -->' markers)"
        else
            ok "agent file carries a kernel block, no paste placeholder"
            # (a) tokens vs bindings rows
            grep -oE '\$\{[A-Z_]+\}' "$_AF_TMP/kernel" | sort -u > "$_AF_TMP/tok-kernel"
            awk '/^[ \t]*<!-- cellarman kernel: end/{k=1; next} k' "$_AGENT_FILE" \
                | grep -oE '^\| `\$\{[A-Z_]+\}`' | grep -oE '\$\{[A-Z_]+\}' | sort -u > "$_AF_TMP/tok-table"
            _NOROW="$(comm -23 "$_AF_TMP/tok-kernel" "$_AF_TMP/tok-table" | tr '\n' ' ')"
            _NOUSE="$(comm -13 "$_AF_TMP/tok-kernel" "$_AF_TMP/tok-table" | tr '\n' ' ')"
            if [ -n "$_NOROW" ]; then
                fail "kernel token(s) with NO row in the bindings table of $_AGENT_FILE: ${_NOROW}— a token without a row fails quietly"
            fi
            if [ -n "$_NOUSE" ]; then
                warn "bindings row(s) for token(s) the kernel never uses: ${_NOUSE}— stale row, or the kernel text was edited"
            fi
            [ -z "$_NOROW$_NOUSE" ] && ok "kernel tokens and bindings rows agree ($(wc -l < "$_AF_TMP/tok-kernel" | tr -d ' ') tokens)"
            # (a2) the session prefix bound in the agent file equals the profile's.
            # A mismatch is functional: the lint derives the current session from the
            # profile's prefix while the PM is told another one, so every claim row
            # reads as another session's.
            _PFX_ROW="$(awk '/^[ \t]*<!-- cellarman kernel: end/{k=1; next} k' "$_AGENT_FILE" | grep -F '| `${SESSION_PREFIX}` |' | head -1)"
            _PFX_PROF_SET="$(_prof PF_SESSION_PREFIX)"
            if [ -z "$_PROFILE_FILE" ]; then
                : # no profile to compare with
            elif [ -z "$_PFX_ROW" ]; then
                : # no row: 13a already failed on it
            else
                _PFX_CELL="$(printf '%s' "$_PFX_ROW" | sed 's/^| *`[^`]*` *|//')"
                # The value is the first backticked span of the cell; a cell that BEGINS
                # with the word "empty" means the empty prefix.
                _PFX_TRIM="$(printf '%s' "$_PFX_CELL" | sed 's/^[[:space:]]*//')"
                case "$_PFX_TRIM" in
                    [Ee]mpty*) _PFX_AGENT=""; _PFX_READ=1 ;;
                    *'`'*'`'*) _PFX_AGENT="$(printf '%s' "$_PFX_TRIM" | sed 's/^[^`]*`\([^`]*\)`.*/\1/')"; _PFX_READ=1 ;;
                    *) _PFX_AGENT=""; _PFX_READ=0 ;;
                esac
                if [ "$_PFX_READ" = 0 ]; then
                    warn "session prefix check (13) UNMEASURED: the \${SESSION_PREFIX} binding in $_AGENT_FILE has no backticked value (write the literal prefix in backticks, or the word empty)"
                elif [ "$_PFX_AGENT" = "$_PFX_PROF_SET" ]; then
                    ok "\${SESSION_PREFIX} binding equals PF_SESSION_PREFIX ('${_PFX_AGENT}')"
                else
                    fail "\${SESSION_PREFIX} is '${_PFX_AGENT}' in $_AGENT_FILE but PF_SESSION_PREFIX is '${_PFX_PROF_SET}' in the profile: every claim row would read as another session's"
                fi
            fi
            # (b) kernel drift against PROTOCOL.md
            if [ -f "$KIT_DIR/PROTOCOL.md" ]; then
                _kernel_block "$KIT_DIR/PROTOCOL.md" > "$_AF_TMP/kernel-ref"
                if [ ! -s "$_AF_TMP/kernel-ref" ]; then
                    warn "kernel drift check (13b) UNMEASURED — $KIT_DIR/PROTOCOL.md has no kernel markers"
                elif cmp -s "$_AF_TMP/kernel" "$_AF_TMP/kernel-ref"; then
                    ok "kernel block identical to pm-kit/PROTOCOL.md"
                else
                    warn "kernel drift: the kernel block in $_AGENT_FILE differs from pm-kit/PROTOCOL.md — re-paste it (the kernel is never edited in place) and re-copy the agent file"
                fi
            else
                warn "kernel drift check (13b) UNMEASURED — $KIT_DIR/PROTOCOL.md not found"
            fi
        fi
        rm -rf "$_AF_TMP"
    fi
fi

# ── 14. Hook wiring (informational: hooks are optional) ──────────────────────
# A hook cannot report its own absence and no other script reads settings.json,
# so this is the one place that can say which of the hooks the kit ships are wired.
# "Not wired" is INFO, never a failure. Project settings, local settings and the
# user's settings are all consulted; the match is by script name.
_HOOK_FILES=""
for _sf in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/.claude/settings.local.json" "${HOME:-/nonexistent}/.claude/settings.json"; do
    [ -f "$_sf" ] && _HOOK_FILES="$_HOOK_FILES $_sf"
done
_HOOK_NOT=""; _HOOK_YES=""
for _h in load-telemetry.sh session-ledger.sh pm-sync.sh pm-consult-nudge.sh; do
    _w=0
    # shellcheck disable=SC2086
    [ -n "$_HOOK_FILES" ] && grep -qF -- "$_h" $_HOOK_FILES 2>/dev/null && _w=1
    if [ "$_w" = 1 ]; then _HOOK_YES="$_HOOK_YES $_h"; else _HOOK_NOT="$_HOOK_NOT $_h"; fi
done
if [ -z "$_HOOK_NOT" ]; then
    ok "hooks wired in settings:${_HOOK_YES}"
else
    info "hooks not wired in .claude/settings.json (optional):${_HOOK_NOT} — see README, Hooks (skeleton/settings.example.json)${_HOOK_YES:+; wired:$_HOOK_YES}"
fi

# ── 15. Rails written outside list items (the miner's blind spot) ────────────
# kernel/rails-index.sh mines only "- " list items (and their indented
# continuations). A rail written as a paragraph, a blockquote or an indented block
# with no list item above it is recorded but NEVER indexed, so a pre-flight on its
# surface finds nothing, which reads as "no rail". This lists lines of the index
# that carry a severity marker AND a backticked artefact (file or table, by the
# profile's own patterns) yet are not in a list item.
_SEV_MARKERS="$(_prof PF_SEVERITY_MARKERS)"
_FILE_RE="$(_prof PF_ARTEFACT_FILE_RE)"; [ -n "$_FILE_RE" ] || _FILE_RE='[.](php|js|sh|css|sql|ts|py|md|json|yml|yaml)$'
_TABLE_RE="$(_prof PF_ARTEFACT_TABLE_RE)"
if [ -f "$PM_INDEX" ] && [ -n "$_SEV_MARKERS" ] && _need "rails outside list items (15)" awk; then
    _OUTSIDE="$(MARKERS="$_SEV_MARKERS" FILE_RE="$_FILE_RE" TABLE_RE="$_TABLE_RE" awk '
      BEGIN {
        n = split(ENVIRON["MARKERS"], ml, "\n")
        for (i = 1; i <= n; i++) { m = ml[i]; k = index(m, "|"); if (k > 1) mk[++nm] = substr(m, 1, k - 1) }
        fre = ENVIRON["FILE_RE"]; tre = ENVIRON["TABLE_RE"]
      }
      /^```/ { fence = !fence; next }
      fence { next }
      substr($0, 1, 2) == "- " { rec = 1; next }
      rec && /^[ \t]+[^ \t]/ { next }
      { rec = 0 }
      /^#/ { next }
      /^[ \t]*$/ { next }
      {
        has = 0
        for (i = 1; i <= nm; i++) if (index($0, mk[i]) > 0) { has = 1; break }
        if (!has) next
        s = $0; art = 0
        while ((p1 = index(s, "`")) > 0) {
          rest = substr(s, p1 + 1); p2 = index(rest, "`")
          if (p2 == 0) break
          c = substr(rest, 1, p2 - 1); s = substr(rest, p2 + 1)
          if (c != "" && (c ~ fre || (tre != "" && c ~ tre))) { art = 1; break }
        }
        if (art) { printf "%d ", NR; cnt++ }
      }
      END { if (cnt) printf "\n%d\n", cnt }' "$PM_INDEX")"
    if [ -n "$_OUTSIDE" ]; then
        _OUT_LINES="$(printf '%s\n' "$_OUTSIDE" | head -1)"
        _OUT_N="$(printf '%s\n' "$_OUTSIDE" | tail -1)"
        warn "${_OUT_N} line(s) of the index look like rails (severity marker + backticked artefact) but are not list items, so the rails miner never indexes them. Rewrite each as a '- ' item. Lines: ${_OUT_LINES}"
    else
        ok "no rail-like line outside list items in the index"
    fi
fi

# ── 16. One index, named the same in both configs ────────────────────────────
# pm-kit.conf (PM_INDEX, absolute) and the profile (PF_PM_INDEX, repo-relative)
# both name "the index". When they name different files, the budgets are measured
# on one and the rails are mined from the other, silently.
_PFI="$(_prof PF_PM_INDEX)"
if [ -n "$_PFI" ] && [ -n "${PM_INDEX:-}" ]; then
    _A="${PM_INDEX#"$REPO_ROOT"/}"; _A="${_A#./}"; _B="${_PFI#./}"
    if [ "$_A" = "$_B" ]; then
        ok "PM_INDEX (pm-kit.conf) and PF_PM_INDEX (profile) name the same file"
    else
        fail "PM_INDEX in pm-kit.conf is '$_A' but PF_PM_INDEX in the profile is '$_B': the budgets are measured on one file and the rails mined from the other"
    fi
fi

echo "pm-doctor: ${FAILS} fail(s), ${WARNINGS} warning(s)"
if [ "$STRICT" = 1 ] && [ "$FAILS" -gt 0 ]; then exit 1; fi
exit 0
