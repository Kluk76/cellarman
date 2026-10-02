#!/usr/bin/env bash
# tests/smoke.sh — self-contained regression suite for the cellarman kit.
#
# Builds throwaway sandbox repos under $TMPDIR (mktemp -d), installs the kit
# into them the way README "Installing on a project" says, and asserts the
# FIXED behaviour of each audited defect. One PASS/FAIL/SKIP line per case;
# exit 0 only if no case failed.
#
# Usage:  bash tests/smoke.sh            (SMOKE_KEEP=1 keeps the sandbox)
# Needs:  bash, git, awk, sed, grep, find, cmp, mktemp. Optional: mawk (the
#         awk-flavour case prints a visible SKIP without it), zsh (B5), jq.
#
# Rules this file follows itself: no exit code is ever read through a pipe
# (`cmd > file 2>&1; rc=$?`), and no case reads state a previous case wrote
# except through the sandbox it builds for itself.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
C="$(cd "$HERE/.." && pwd)"
[ -f "$C/pm-kit/doctor.sh" ] || { echo "smoke: no cellarman checkout at $C" >&2; exit 64; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/cellarman-smoke.XXXXXX")" || exit 64
cleanup() { [ "${SMOKE_KEEP:-0}" = 1 ] && echo "smoke: sandbox kept at $SB" || rm -rf "$SB"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=Smoke GIT_AUTHOR_EMAIL=smoke@example.com
export GIT_COMMITTER_NAME=Smoke GIT_COMMITTER_EMAIL=smoke@example.com
export HOME="$SB/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset ACME_DEV PM_DEV PM_PROFILE PM_REPO_ROOT RATIFIED PF_CLAIM_STALE_DAYS CLAUDE_CODE_SESSION_ID 2>/dev/null

N_PASS=0; N_FAIL=0; N_SKIP=0
pass() { N_PASS=$((N_PASS+1)); printf 'PASS  %-8s %s\n' "$1" "$2"; }
fail() { N_FAIL=$((N_FAIL+1)); printf 'FAIL  %-8s %s\n' "$1" "$2"; }
skip() { N_SKIP=$((N_SKIP+1)); printf 'SKIP  %-8s %s\n' "$1" "$2"; }
# check <id> <desc> <rc-of-a-condition>   (0 = the fixed behaviour holds)
check() { if [ "$3" = 0 ]; then pass "$1" "$2"; else fail "$1" "$2"; fi; }

LOGN=0
# run <cmd...> : stdout+stderr to $OUT, exit code to $RC — never through a pipe.
run() { LOGN=$((LOGN+1)); OUT="$SB/log.$LOGN"; "$@" > "$OUT" 2>&1; RC=$?; }
has()   { grep -q -- "$1" "${2:-$OUT}"; }
lacks() { ! grep -q -- "$1" "${2:-$OUT}"; }
strip() { sed 's/\x1b\[[0-9;]*m//g' "${1:-$OUT}" > "${1:-$OUT}.txt"; OUTT="${1:-$OUT}.txt"; }

KITREL=claude-brain/pm-kit
MEMDIR=claude-brain/agents/acme-pm-memory
INDEX=claude-brain/agents/acme-pm-memory.md
PROFILE=$KITREL/profiles/acme.conf
TAB="$(printf '\t')"

# mk_proj <name> [remote|noremote]
# README "Installing on a project", literally: kit copied, pm-kit.conf from the
# example, profile copied to pm-kit/profiles/<project>.conf, launcher copied
# VERBATIM (never edited), agent file + seed index from the skeleton, step-7
# gitignore. Leaves cwd inside the new repo; PROJ and REMOTE are set.
mk_proj() {
  PROJ="$SB/$1"; REMOTE="$SB/$1.remote.git"
  mkdir -p "$PROJ" && cd "$PROJ" || exit 64
  git init -q -b main . && git commit -q --allow-empty -m init
  mkdir -p claude-brain bin "$MEMDIR"
  cp -r "$C/pm-kit" "$KITREL"
  cp "$C/pm-kit.conf.example" claude-brain/pm-kit.conf
  mkdir -p "$KITREL/profiles" && cp "$C/profiles/example.conf" "$PROFILE"
  cp "$C/skeleton/bin-pm-preflight.example.sh" bin/pm-preflight.sh && chmod +x bin/pm-preflight.sh
  cp "$C/skeleton/agent-example.md" claude-brain/agents/acme-pm.md
  cp "$C/skeleton/index-seed.md" "$INDEX"
  mkdir -p "$HOME/.claude/agents" && cp claude-brain/agents/acme-pm.md "$HOME/.claude/agents/acme-pm.md"
  printf 'claude-brain/agents/.pm-load-log.tsv\nclaude-brain/agents/pm-catalog.tsv\nclaude-brain/pm-kit/state/\n' > .gitignore
  git add -- .gitignore bin claude-brain && git commit -q -m "install kit"
  if [ "${2:-remote}" = remote ]; then
    git init -q --bare "$REMOTE" && git remote add origin "$REMOTE"
    git push -q -u origin main > "$SB/push.$1.log" 2>&1
  fi
}
# prof_set <VAR> <value>: later assignment wins when the profile is sourced.
prof_set() { printf '%s=%s\n' "$1" "$2" >> "$PROJ/$PROFILE"; }
commit_all() { git add -- . && git commit -q -m "${1:-state}" && { [ ! -d "$REMOTE" ] || git push -q > /dev/null 2>&1; }; }

###############################################################################
# 1.1 — the seed index is not a source of dangling links
###############################################################################
mk_proj p11 remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has '0 fail(s)'; }; check 1.1 "doctor --strict passes on the untouched seed index (rc=$RC)" $?

###############################################################################
printf '\nsmoke: %d passed, %d failed, %d skipped\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" = 0 ]; FINAL=$?
exit "$FINAL"
