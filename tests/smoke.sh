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
# tmo <cmd...>: bounded run where a `timeout` exists (a hang must FAIL, not stall the suite).
tmo() { if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout 10 "$@"; else "$@"; fi; }
# A `grep` that rejects -P the way BSD grep does (the real one is found by absolute path).
mk_nopgrep() {
  mkdir -p "$SB/nopgrep"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in -P|-[a-zA-Z]*P*) echo "grep: invalid option -- P" >&2; exit 2 ;; esac; done\nexec %s "$@"\n' "$(command -v grep)" > "$SB/nopgrep/grep"
  chmod +x "$SB/nopgrep/grep"
}
# mk_toolpath <dir> <tool...>: a PATH holding ONLY the named tools (symlinks) — to prove what a
# kit script does when a tool is absent. Unknown/missing tools are skipped silently.
mk_toolpath() {
  local d="$1" t w; shift; rm -rf "$d"; mkdir -p "$d"
  for t in "$@"; do w="$(command -v "$t" 2>/dev/null)" && [ -x "$w" ] && ln -sf "$w" "$d/$t"; done
}
COMMON_TOOLS="bash sh env find sort wc date head tail grep sed tr cut awk mktemp rm cat dirname basename readlink printf mv cp ls comm uniq stat touch git jq"
commit_all() { git add -- . && git commit -q -m "${1:-state}" && { [ ! -d "$REMOTE" ] || git push -q > /dev/null 2>&1; }; }

###############################################################################
# 1.1 — the seed index is not a source of dangling links
###############################################################################
mk_proj p11 remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has '0 fail(s)'; }; check 1.1 "doctor --strict passes on the untouched seed index (rc=$RC)" $?

###############################################################################
# 1.2 / 1.3 — one index naming scheme; default extra corpus empty; per-pattern
###############################################################################
run bash "$KITREL/kernel/rails-index.sh"
{ [ "$RC" != 2 ] && lacks 'STOP'; }; check 1.2 "rails-index on the README install finds the index (rc=$RC)" $?
IDX_CONF="$(sed -n 's|^PM_INDEX=.*claude-brain/|claude-brain/|p' claude-brain/pm-kit.conf | tr -d '"')"
IDX_PROF="$(sed -n 's|^PF_PM_INDEX="\(.*\)".*|\1|p' "$PROFILE")"
{ [ -n "$IDX_PROF" ] && [ "$IDX_CONF" = "$IDX_PROF" ]; }; check 1.2 "pm-kit.conf PM_INDEX and profile PF_PM_INDEX name the same file" $?
{ grep -q '^PF_RAILS_EXTRA_CORPUS=""' "$PROFILE"; }; check 1.3 "default PF_RAILS_EXTRA_CORPUS is empty" $?
mkdir -p "$MEMDIR/rails-register"; printf -- '- 🔴 `app/x.php` is sealed\n' > "$MEMDIR/rails-register/a.md"
prof_set PF_RAILS_EXTRA_CORPUS "\"$MEMDIR/rails-register/*.md $MEMDIR/missing-register.md\""
run bash "$KITREL/kernel/rails-index.sh"
{ [ "$RC" = 2 ] && has 'missing-register.md".*matches no file'; }; check 1.3 "one unresolved pattern on a two-pattern line is reported (rc=$RC)" $?
prof_set PF_RAILS_EXTRA_CORPUS "\"$MEMDIR/rails-register/*.md\""
run bash "$KITREL/kernel/rails-index.sh"
{ [ "$RC" != 2 ] && has "CORPUS.*rails-register/a.md"; }; check 1.3 "a fully resolving extra corpus is mined (rc=$RC)" $?

###############################################################################
# B5 — a script started by zsh re-executes under bash
###############################################################################
if command -v zsh >/dev/null 2>&1; then
  mkdir -p "$MEMDIR"; printf '# t\n' > "$MEMDIR/journal.md"
  run zsh "$KITREL/doctor.sh"
  { lacks 'unknown predicate' && has 'no topic file over'; }; check B5 "doctor.sh run via zsh measures check 6 (rc=$RC)" $?
  rm -f "$MEMDIR/journal.md"
else
  skip B5 "zsh not installed"
fi

###############################################################################
# 1.4 / A11 — launcher without a hardcoded profile; honest --conf; usage errors
###############################################################################
mk_proj p14 remote
run bash bin/pm-preflight.sh --no-fetch
{ lacks 'no profile found'; }; check 1.4 "the verbatim launcher finds the single profile (rc=$RC)" $?
run bash bin/pm-preflight.sh --conf "$SB/does-not-exist.conf"
{ [ "$RC" = 2 ] && has "--conf '$SB/does-not-exist.conf' does not exist" && lacks 'no profile found'; }; check 1.4 "a missing --conf path is named as missing (rc=$RC)" $?
run tmo bash "$KITREL/kernel/rails-index.sh" --conf "$SB/does-not-exist.conf"
{ [ "$RC" = 2 ] && has 'does not exist'; }; check 1.4 "rails-index: missing --conf is named as missing (rc=$RC)" $?
run tmo bash "$KITREL/catalog.sh" --grep
{ [ "$RC" = 64 ] && has 'needs a pattern'; }; check A11 "catalog --grep without a pattern: usage error, no hang (rc=$RC)" $?
run tmo bash "$KITREL/kernel/pm-preflight.sh" --conf
{ [ "$RC" = 64 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "pm-preflight --conf without a value: usage error (rc=$RC)" $?
run tmo bash "$KITREL/kernel/ownership-lint.sh" --dev
{ [ "$RC" = 64 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "ownership-lint --dev without a value: usage error (rc=$RC)" $?
run tmo bash "$KITREL/kernel/rails-index.sh" --conf
{ [ "$RC" = 64 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "rails-index --conf without a value: usage error (rc=$RC)" $?

###############################################################################
# 1.12 / B3 — catalog: missing memory dir; load counts without `grep -P`
###############################################################################
mk_proj p112 remote
rmdir "$MEMDIR"
run bash "$KITREL/catalog.sh"
{ [ "$RC" != 0 ] && has 'memory dir not found' && lacks 'topic files ->'; }; check 1.12 "catalog on a missing memory dir: clear error, non-zero (rc=$RC)" $?
mkdir -p "$MEMDIR"; printf '# Journal\n\n> Trigger: history\n' > "$MEMDIR/journal.md"
printf '2026-10-01\tjournal.md\n2026-10-02\tjournal.md\n' > claude-brain/agents/.pm-load-log.tsv
mk_nopgrep
run env PATH="$SB/nopgrep:$PATH" bash "$KITREL/catalog.sh" --grep journal
{ [ "$RC" = 0 ] && has 'loads:2 last:2026-10-02'; }; check B3 "catalog reads load counts from the log with a -P-less grep (rc=$RC)" $?

###############################################################################
# B4 — no `realpath` on the machine: catalog and the telemetry hook still work
###############################################################################
mk_toolpath "$SB/norealpath" $COMMON_TOOLS
{ [ ! -e "$SB/norealpath/realpath" ]; }; check B4 "fixture PATH really has no realpath" $?
run env PATH="$SB/norealpath" "$(command -v bash)" "$KITREL/catalog.sh"
{ [ "$RC" = 0 ] && has 'topic files ->' && lacks 'not found'; }; check B4 "catalog works without realpath (rc=$RC)" $?
if [ -x "$SB/norealpath/jq" ]; then
  ln -sfn "$PROJ/$MEMDIR" "$SB/link-mem"; : > claude-brain/agents/.pm-load-log.tsv
  printf '{"tool_input":{"file_path":"%s/link-mem/journal.md"}}' "$SB" > "$SB/hook.json"
  run env PATH="$SB/norealpath" "$(command -v bash)" "$KITREL/load-telemetry.sh" < "$SB/hook.json"
  { [ "$RC" = 0 ] && grep -q "${TAB}journal.md\$" claude-brain/agents/.pm-load-log.tsv; }; check B4 "telemetry hook records a symlinked read without realpath (rc=$RC)" $?
else
  skip B4 "jq not installed (telemetry hook case)"
fi

###############################################################################
# (c) — catalog harvests every trigger line, never truncates the search haystack
###############################################################################
LONGW="$(printf 'filler%.0s ' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50)"
{ printf '# Many triggers\n\n'
  printf '> Trigger: alpha\n> Trigger: beta\n> Trigger: gamma\n> Trigger: fourthword\n'
  printf '> Trigger: %s tailword\n' "$LONGW"; } > "$MEMDIR/many-triggers.md"
run bash "$KITREL/catalog.sh" --grep fourthword
{ [ "$RC" = 0 ] && has 'many-triggers.md'; }; check cat-c "a 4th trigger line is searchable (rc=$RC)" $?
run bash "$KITREL/catalog.sh" --grep tailword
{ [ "$RC" = 0 ] && has 'many-triggers.md'; }; check cat-c "a word past byte 400 of the triggers is searchable (rc=$RC)" $?
{ has '…'; }; check cat-c "long triggers are displayed shortened with a visible ellipsis" $?
{ ! has 'tailword'; }; check cat-c "the shortened display does not carry the tail" $?
rm -f "$MEMDIR/many-triggers.md"

###############################################################################
printf '\nsmoke: %d passed, %d failed, %d skipped\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" = 0 ]; FINAL=$?
exit "$FINAL"
