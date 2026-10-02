#!/usr/bin/env bash
# pm-sync.example.sh — sweep PM-memory changes into git, so the shared PM brain
# stays in sync without anyone remembering to commit it.
#
# INSTALL: copy to <repo>/claude-brain/pm-sync.sh (next to pm-kit.conf; the
# script resolves its config relative to its own location, override with
# PM_KIT_CONF). Wire it as a Claude Code PostToolUse hook gated on git
# commit / git push, and wire pm-kit/kernel/session-ledger.sh as a
# PostToolUse hook on Write|Edit (see the cellarman README). Both hooks need
# `jq`. Can also be run by hand: `./pm-sync.sh --all`.
#
# WHAT IT DOES
#   - Looks for changes under the memory paths: tracked edits (staged or not)
#     AND untracked new files (a brand-new topic file is invisible to
#     `git diff`).
#   - SESSION-SCOPED: it commits only the memory files THIS session wrote,
#     as recorded by session-ledger.sh in <git-common-dir>/pm-ledger/. A
#     changed memory file that is in no ledger, or in a neighbour session's
#     ledger, is named and left alone — committing content nobody can
#     attribute is how a half-written file from a parallel session ends up
#     checked in.
#       --all       deliberate escape hatch: sweep every changed memory file
#                   (recovering an orphan from a dead session). Never default.
#       no stdin    a bare manual run, or a hook without a usable JSON
#                   envelope (or without jq), knows no session, so it commits
#                   NOTHING and says so. Fail-closed on purpose: falling back
#                   to a whole-tree sweep would silently reinstate the defect.
#   - Steps aside when non-memory paths are already staged: a commit sequence
#     is in flight, and an auto-commit wedged between two of its commits
#     hollows out the next one.
#   - Serialises on a lock in the git common dir. `flock` where available;
#     otherwise (macOS has no flock(1)) a portable `mkdir` lock with
#     stale-owner reclaim. A held lock makes this run exit quietly: the
#     holder's pass will pick up the same diff.
#   - PUSH GUARD: pushes only when EVERY commit ahead of the upstream touches
#     memory paths alone. Otherwise the memory commit stays local, the refusal
#     is printed on stderr, and the code owner decides when to push. The push
#     is explicit (`git push <remote> HEAD:<upstream-branch>`), never a bare
#     `git push` whose behaviour depends on push.default.
#   - No remote / no upstream (a fresh `git init`): commit locally, skip the
#     push, no error.
#   - Commit message: $PM_SYNC_MSG if set, else "chore(pm-memory): auto-sync".
#   - NEVER rebases or merges. Always exits 0 (a hook must not break the
#     session); the output says what actually happened.
#
# WHAT IT DOES NOT DO
#   - It does not detect a file being written at this very moment: the ledger
#     says WHO wrote a file, not that the write has finished. Run it from the
#     PostToolUse hook, after the tool call completed.
#   - It does not read exit codes of the optional doctor call below (that call
#     is advisory output only).
#
# CONFIG (pm-kit.conf; values may use $REPO_ROOT and $KIT_DIR)
#   PM_MEMORY_DIR         topic-file directory  (required)
#   PM_INDEX              always-read index file (required)
#   PM_SYNC_EXTRA_PATHS   optional, space-separated extra repo-relative paths
#                         to treat as memory (files or directories)
# ENVIRONMENT
#   PM_SYNC_MSG           commit message override
#   PM_SYNC_NO_DOCTOR=1   skip the advisory doctor call at the end
#   PM_SYNC_NO_FLOCK=1    use the mkdir lock even where flock exists (testing)
#   PM_KIT_CONF           alternative path of pm-kit.conf
set +e
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO" 2>/dev/null || exit 0

CONF="${PM_KIT_CONF:-$SCRIPT_DIR/pm-kit.conf}"
if [ ! -f "$CONF" ]; then
    echo "[pm-sync] no pm-kit.conf at $CONF — nothing to do (set PM_KIT_CONF?)" >&2
    exit 0
fi
KIT_DIR="${PM_KIT_DIR:-$SCRIPT_DIR/pm-kit}"
# shellcheck disable=SC1090
REPO_ROOT="$REPO" KIT_DIR="$KIT_DIR" . "$CONF" 2>/dev/null || exit 0

# ── memory paths, from configuration ─────────────────────────────────────────
MEM_PATHS=()
_add_mem() {
    local p="${1#"$REPO"/}"
    p="${p%/}"
    [ -n "$p" ] || return 0
    case "$p" in
        /*) echo "[pm-sync] memory path '$1' is outside the repo — ignored" >&2; return 0 ;;
    esac
    MEM_PATHS+=("$p")
}
_add_mem "${PM_MEMORY_DIR:-}"
_add_mem "${PM_INDEX:-}"
for _x in ${PM_SYNC_EXTRA_PATHS:-}; do _add_mem "$_x"; done
if [ "${#MEM_PATHS[@]}" -eq 0 ]; then
    echo "[pm-sync] PM_MEMORY_DIR / PM_INDEX not set in $CONF — nothing to do" >&2
    exit 0
fi

# 0 when $1 is one of the memory paths, or lives under one.
_is_mem() {
    local f="$1" m
    for m in ${MEM_PATHS[@]+"${MEM_PATHS[@]}"}; do
        case "$f" in
            "$m"|"$m"/*) return 0 ;;
        esac
    done
    return 1
}

# ── mode ─────────────────────────────────────────────────────────────────────
SWEEP_ALL=0
for arg in "$@"; do
    case "$arg" in
        --all) SWEEP_ALL=1 ;;
        *) echo "[pm-sync] unknown argument '$arg' (only --all is recognised)" >&2 ;;
    esac
done

# ── learn our own session id from the hook's stdin JSON ──────────────────────
# Never read a terminal: a bare invocation has no pipe, and reading a tty would
# hang. --all needs no session at all.
SESSION_ID=""
if [ "$SWEEP_ALL" -eq 0 ] && [ ! -t 0 ]; then
    if command -v jq >/dev/null 2>&1; then
        HOOK_JSON="$(cat 2>/dev/null)"
        if [ -n "$HOOK_JSON" ]; then
            SESSION_ID="$(printf '%s' "$HOOK_JSON" | jq -r '.session_id // empty' 2>/dev/null)"
        fi
    else
        echo "[pm-sync] jq not found — cannot read the session id, so nothing will be attributed (install jq, or use --all)" >&2
    fi
fi
# A session id becomes a file name: refuse anything that is not a plain token.
case "$SESSION_ID" in
    *[!A-Za-z0-9._-]*) echo "[pm-sync] session id has unexpected characters — ignored" >&2; SESSION_ID="" ;;
esac

# git common dir: a worktree's own .git is a stub; locks and ledgers must live
# where every worktree sharing this repo can see them.
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$COMMON_DIR" in
    /*) : ;;
    "") echo "[pm-sync] not inside a git repository" >&2; exit 0 ;;
    *) COMMON_DIR="$REPO/$COMMON_DIR" ;;
esac

# ── what changed under the memory paths? tracked edits AND untracked files ──
CHANGED="$( {
    git -c core.quotepath=false diff --name-only -- "${MEM_PATHS[@]}" 2>/dev/null
    git -c core.quotepath=false diff --cached --name-only -- "${MEM_PATHS[@]}" 2>/dev/null
    git -c core.quotepath=false ls-files --others --exclude-standard -- "${MEM_PATHS[@]}" 2>/dev/null
} | sort -u )"

[ -n "$CHANGED" ] || exit 0   # memory unchanged: stay silent

# ── decide what this run may commit ──────────────────────────────────────────
TO_COMMIT=""
ORPHANS=""
if [ "$SWEEP_ALL" -eq 1 ]; then
    TO_COMMIT="$CHANGED"
elif [ -n "$SESSION_ID" ]; then
    LEDGER_FILE="$COMMON_DIR/pm-ledger/$SESSION_ID.paths"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if [ -f "$LEDGER_FILE" ] && grep -Fxq -- "$path" "$LEDGER_FILE" 2>/dev/null; then
            TO_COMMIT="$TO_COMMIT
$path"
        else
            ORPHANS="$ORPHANS
$path"
        fi
    done <<EOF
$CHANGED
EOF
else
    ORPHANS="$CHANGED"
fi
TO_COMMIT="$(printf '%s\n' "$TO_COMMIT" | grep -v '^$')"
ORPHANS="$(printf '%s\n' "$ORPHANS" | grep -v '^$')"

if [ -n "$ORPHANS" ]; then
    ORPHAN_COUNT="$(printf '%s\n' "$ORPHANS" | grep -c .)"
    if [ -z "$SESSION_ID" ] && [ "$SWEEP_ALL" -eq 0 ]; then
        echo "[pm-sync] $ORPHAN_COUNT changed memory file(s) but NO known session (manual run, or hook without a usable stdin) — nothing committed. Re-run with --all for a deliberate sweep:"
    else
        echo "[pm-sync] $ORPHAN_COUNT changed memory file(s) belong to another session or have unknown authorship — not committed:"
    fi
    printf '%s\n' "$ORPHANS" | sed 's/^/[pm-sync]   /'
fi

[ -n "$TO_COMMIT" ] || exit 0

# ── lock ─────────────────────────────────────────────────────────────────────
LOCKFILE="$COMMON_DIR/pm-sync.lock"
LOCKDIR="$COMMON_DIR/pm-sync.lock.d"
_release_lock() { rm -rf "$LOCKDIR" 2>/dev/null; }
if [ -z "${PM_SYNC_NO_FLOCK:-}" ] && command -v flock >/dev/null 2>&1; then
    # The 2>/dev/null must wrap the exec in a group: written on the exec itself
    # it would redirect this shell's stderr for the rest of the script and
    # swallow every later message, including the push refusal.
    if { exec 9>"$LOCKFILE"; } 2>/dev/null; then
        if ! flock -n 9 2>/dev/null; then
            echo "[pm-sync] lock held by another session — stepping aside, its pass will do the work"
            exit 0
        fi
    else
        echo "[pm-sync] cannot open $LOCKFILE — continuing WITHOUT a lock" >&2
    fi
else
    # No flock(1) (macOS): mkdir is atomic. A stale lock (owner pid gone) is
    # reclaimed once; the reclaim itself is not race-free, which is acceptable
    # for a hook that only ever loses a pass, never data.
    GOT_LOCK=0
    if mkdir "$LOCKDIR" 2>/dev/null; then
        GOT_LOCK=1
    else
        OWNER="$(cat "$LOCKDIR/pid" 2>/dev/null)"
        if [ -n "$OWNER" ] && ! kill -0 "$OWNER" 2>/dev/null; then
            rm -rf "$LOCKDIR" 2>/dev/null
            mkdir "$LOCKDIR" 2>/dev/null && GOT_LOCK=1
        fi
    fi
    if [ "$GOT_LOCK" -ne 1 ]; then
        echo "[pm-sync] lock held by another session — stepping aside, its pass will do the work"
        exit 0
    fi
    printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null
    trap _release_lock EXIT
fi

# ── step aside when a commit sequence is in flight ───────────────────────────
# Non-memory paths already staged mean a session is mid-sequence. It will
# commit the memory itself, or this hook will run again with a clean index.
STAGED_FOREIGN=""
while IFS= read -r p; do
    [ -n "$p" ] || continue
    _is_mem "$p" || STAGED_FOREIGN="$STAGED_FOREIGN $p"
done <<EOF
$(git -c core.quotepath=false diff --cached --name-only 2>/dev/null)
EOF
if [ -n "$STAGED_FOREIGN" ]; then
    echo "[pm-sync] commit sequence in flight (non-memory paths staged) — stepping aside"
    exit 0
fi

# ── commit ───────────────────────────────────────────────────────────────────
MSG="${PM_SYNC_MSG:-chore(pm-memory): auto-sync}"
ADD_ARGS=()
while IFS= read -r path; do
    [ -n "$path" ] && ADD_ARGS+=("$path")
done <<EOF
$TO_COMMIT
EOF

git add -- "${ADD_ARGS[@]}" 2>/dev/null
git commit -q -m "$MSG" -- "${ADD_ARGS[@]}" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "[pm-sync] committed ${#ADD_ARGS[@]} PM-memory file(s): ${ADD_ARGS[*]}"
else
    echo "[pm-sync] commit failed (rc=$rc, a pre-commit hook may have refused) — memory left staged, nothing pushed" >&2
    exit 0
fi

# ── push guard: never push somebody else's work ──────────────────────────────
# A push sends the whole branch, not just the commit made here. Push only when
# every commit ahead of the upstream is memory-only.
BRANCH="$(git symbolic-ref -q --short HEAD 2>/dev/null)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
REMOTE=""
MERGEREF=""
if [ -n "$BRANCH" ]; then
    REMOTE="$(git config "branch.$BRANCH.remote" 2>/dev/null)"
    MERGEREF="$(git config "branch.$BRANCH.merge" 2>/dev/null)"
fi
if [ -z "$UPSTREAM" ] || [ -z "$REMOTE" ] || [ -z "$MERGEREF" ]; then
    echo "[pm-sync] no remote/upstream configured — committed locally, push skipped"
else
    FOREIGN=""
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if ! _is_mem "$p"; then
                FOREIGN="$FOREIGN $(git log -1 --format=%h "$sha")"
                break
            fi
        done < <(git -c core.quotepath=false show --name-only --format= "$sha" 2>/dev/null)
    done < <(git log --format=%H "$UPSTREAM..HEAD" 2>/dev/null)
    if [ -n "$FOREIGN" ]; then
        echo "[pm-sync] PUSH REFUSED — unpushed commit(s) touching non-memory paths:$FOREIGN" >&2
        echo "[pm-sync] memory is committed locally; push yourself when you have decided to publish that code" >&2
    else
        git push -q "$REMOTE" "HEAD:$MERGEREF" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "[pm-sync] pushed PM memory"
        else
            echo "[pm-sync] PM memory committed locally; push failed (rc=$rc) — pull and push when ready"
        fi
    fi
fi

# ── advisory health check (output only, never blocks) ────────────────────────
if [ -z "${PM_SYNC_NO_DOCTOR:-}" ] && [ -x "$KIT_DIR/doctor.sh" ]; then
    "$KIT_DIR/doctor.sh" 2>/dev/null | grep -E "WARN|FAIL" | sed 's/^/[pm-sync] /'
fi
exit 0
