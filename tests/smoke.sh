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
SB="$(cd "$SB" && pwd)"
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
ESC="$(printf '\033')"   # BSD sed has no \x1b
strip() { sed "s/${ESC}\[[0-9;]*m//g" "${1:-$OUT}" > "${1:-$OUT}.txt"; OUTT="${1:-$OUT}.txt"; }

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
  # the agent file, kernel pasted between its markers exactly as the README does
  awk '/^<!-- cellarman kernel: begin/{k=1} k; /^<!-- cellarman kernel: end/{k=0}' "$KITREL/PROTOCOL.md" > "$SB/kernel.$1.md"
  awk -v kf="$SB/kernel.$1.md" '
    /^<!-- cellarman kernel: begin/ { while ((getline l < kf) > 0) print l; skip=1; next }
    /^<!-- cellarman kernel: end/   { skip=0; next }
    !skip' "$C/skeleton/agent-example.md" > claude-brain/agents/acme-pm.md
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
COMMON_TOOLS="bash sh env cmp find sort wc date head tail grep sed tr cut awk mktemp rm cat dirname basename readlink printf mv cp ls comm uniq stat touch git jq"
# ago_stamp <days>: touch -t stamp (YYYYMMDDhhmm) for N days ago, GNU or BSD date.
ago_stamp() { date -d "-$1 days" +%Y%m%d%H%M 2>/dev/null || date -v "-${1}d" +%Y%m%d%H%M; }
# ago_ymd <days>: YYYYMMDD for N days ago (UTC, as the pre-flight computes ages), GNU or BSD date.
ago_ymd() { date -u -d "-$1 days" +%Y%m%d 2>/dev/null || date -u -v "-${1}d" +%Y%m%d; }
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
{ [ "$RC" = 3 ] && has "--conf '$SB/does-not-exist.conf' does not exist" && lacks 'no profile found'; }; check 1.4 "a missing --conf path is named as missing, exit 3 (rc=$RC)" $?
run tmo bash "$KITREL/kernel/rails-index.sh" --conf "$SB/does-not-exist.conf"
{ [ "$RC" = 3 ] && has 'does not exist'; }; check 1.4 "rails-index: missing --conf is named as missing, exit 3 (rc=$RC)" $?
run tmo bash "$KITREL/catalog.sh" --grep
{ [ "$RC" = 64 ] && has 'needs a pattern'; }; check A11 "catalog --grep without a pattern: usage error, no hang (rc=$RC)" $?
run tmo bash "$KITREL/kernel/pm-preflight.sh" --conf
{ [ "$RC" = 3 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "pm-preflight --conf without a value: usage error, exit 3 (rc=$RC)" $?
run tmo bash "$KITREL/kernel/ownership-lint.sh" --dev
{ [ "$RC" = 3 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "ownership-lint --dev without a value: usage error, exit 3 (rc=$RC)" $?
run tmo bash "$KITREL/kernel/rails-index.sh" --conf
{ [ "$RC" = 3 ] && has 'needs a value' && lacks 'unbound'; }; check A11 "rails-index --conf without a value: usage error, exit 3 (rc=$RC)" $?

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
# shellcheck disable=SC2086  # COMMON_TOOLS is a word list
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
# B1 — doctor sizes without `find -printf`; a missing tool is UNMEASURED, not ok
###############################################################################
mk_proj pb1 remote
mkdir -p "$SB/noprintf" "$MEMDIR/index-relocated-detail"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -printf ] && { echo "find: unknown primary or operator" >&2; exit 1; }; done\nexec %s "$@"\n' "$(command -v find)" > "$SB/noprintf/find"; chmod +x "$SB/noprintf/find"
printf '# t\n' > "$MEMDIR/journal.md"
head -c 92160 /dev/zero | tr '\0' 'x' > "$MEMDIR/big-topic.md"; printf '\nbig-topic.md\n' >> "$INDEX"
for i in 1 2 3 4; do head -c 10240 /dev/zero | tr '\0' 'x' > "$MEMDIR/index-relocated-detail/index-verbatim-$i.md"; done
run env PATH="$SB/noprintf:$PATH" bash "$KITREL/doctor.sh"
{ has 'topic file(s) over 80 KB' && has '90 KB  big-topic.md'; }; check B1 "check 6 reports an oversized topic file with a printf-less find" $?
{ has '4 archived snapshot' && has '40 KB'; }; check B1 "check 7 reports archive size with a printf-less find" $?
# shellcheck disable=SC2046  # the tool list is a word list
mk_toolpath "$SB/nofind" $(for t in $COMMON_TOOLS; do [ "$t" = find ] || printf '%s ' "$t"; done)
run env PATH="$SB/nofind" "$(command -v bash)" "$KITREL/doctor.sh"
{ has "check (6) UNMEASURED — required tool 'find'" && lacks 'no topic file over'; }; check B1 "a missing find is UNMEASURED, never 'ok — no topic file over' (rc=$RC)" $?
rm -rf "$MEMDIR/big-topic.md" "$MEMDIR/index-relocated-detail"

###############################################################################
# B2 — agent-copy drift by content compare, no md5sum on the machine
###############################################################################
mk_proj pb2 remote
# shellcheck disable=SC2086  # COMMON_TOOLS is a word list
mk_toolpath "$SB/nomd5" $COMMON_TOOLS
{ [ ! -e "$SB/nomd5/md5sum" ]; }; check B2 "fixture PATH really has no md5sum" $?
run env PATH="$SB/nomd5" "$(command -v bash)" "$KITREL/doctor.sh"
{ has 'agent definition copies in sync'; }; check B2 "identical agent copies read in sync without md5sum" $?
printf '\nlocally edited\n' >> "$HOME/.claude/agents/acme-pm.md"
run env PATH="$SB/nomd5" "$(command -v bash)" "$KITREL/doctor.sh"
{ has 'agent definition drift:' && lacks 'copies in sync'; }; check B2 "a differing installed copy is flagged without md5sum" $?
# shellcheck disable=SC2046  # the tool list is a word list
mk_toolpath "$SB/nocmp" $(for t in $COMMON_TOOLS; do [ "$t" = cmp ] || printf '%s ' "$t"; done)
run env PATH="$SB/nocmp" "$(command -v bash)" "$KITREL/doctor.sh"
{ has "check (8) UNMEASURED — required tool 'cmp'" && lacks 'copies in sync'; }; check B2 "a missing cmp is UNMEASURED, never 'in sync'" $?
cp claude-brain/agents/acme-pm.md "$HOME/.claude/agents/acme-pm.md"

###############################################################################
# A14 — dormancy only for files older than PM_DORMANT_DAYS
###############################################################################
mk_proj pa14 remote
printf '# J\n' > "$MEMDIR/journal.md"
printf '# old\n' > "$MEMDIR/old-never-loaded.md"; touch -t "$(ago_stamp 120)" "$MEMDIR/old-never-loaded.md"
printf '# new\n' > "$MEMDIR/new-arc.md"
printf 'old-never-loaded.md new-arc.md\n' >> "$INDEX"
printf '%s\tjournal.md\n' "$(date +%F)" > claude-brain/agents/.pm-load-log.tsv
run bash "$KITREL/doctor.sh"
{ has 'older than 90 days' && has '^    old-never-loaded.md' && ! grep -q '^    new-arc.md' "$OUT"; }; check A14 "only the 120-day-old unloaded file is dormant; today's new-arc.md is not" $?
rm -f "$MEMDIR/old-never-loaded.md" "$MEMDIR/new-arc.md"

###############################################################################
# A8 — rail severity is identical under gawk UTF-8, gawk LC_ALL=C and mawk
###############################################################################
mk_proj pa8 remote
cat >> "$INDEX" <<'EOF'
- ⛔ never edit `app/db.php` by hand · 🔴 `ref_users` is read by two views · ⛔ `fin_ledger.amount` is sealed
- 🆕 ⛔ badge-led rail on `scripts/deploy.sh`
EOF
sev() { awk -F'\t' -v a="$1" '$1==a {print $2; exit}' "$PROJ/$KITREL/state/RAILS-BY-ARTEFACT.tsv"; }
sevline() { printf 'db.php=%s ref_users=%s fin_ledger.amount=%s deploy.sh=%s' "$(sev app/db.php)" "$(sev ref_users)" "$(sev fin_ledger.amount)" "$(sev scripts/deploy.sh)"; }
EXPECT_SEV='db.php=STOP ref_users=WARN fin_ledger.amount=STOP deploy.sh=STOP'
locale -a > "$SB/locales.txt" 2>/dev/null
UTF8_LOC=""; for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do grep -qx "$l" "$SB/locales.txt" && { UTF8_LOC="$l"; break; }; done
AWKSHIM="$SB/awkshim"; mkdir -p "$AWKSHIM"
if command -v gawk >/dev/null 2>&1; then
  ln -sf "$(command -v gawk)" "$AWKSHIM/awk"
  if [ -n "$UTF8_LOC" ]; then
    run env PATH="$AWKSHIM:$PATH" LC_ALL="$UTF8_LOC" bash "$KITREL/kernel/rails-index.sh"; got="$(sevline)"
    [ "$got" = "$EXPECT_SEV" ]; check A8 "gawk + $UTF8_LOC: $got" $?
  else skip A8 "gawk UTF-8 (no UTF-8 locale installed)"; fi
  run env PATH="$AWKSHIM:$PATH" LC_ALL=C bash "$KITREL/kernel/rails-index.sh"; got="$(sevline)"
  [ "$got" = "$EXPECT_SEV" ]; check A8 "gawk + LC_ALL=C: $got" $?
else skip A8 "gawk not installed"; fi
if command -v mawk >/dev/null 2>&1; then
  ln -sf "$(command -v mawk)" "$AWKSHIM/awk"
  run env PATH="$AWKSHIM:$PATH" bash "$KITREL/kernel/rails-index.sh"; got="$(sevline)"
  [ "$got" = "$EXPECT_SEV" ]; check A8 "mawk: $got" $?
else skip A8 "mawk not installed (awk-flavour case)"; fi

###############################################################################
# A7 — no graph cache configured (or a cache without edges) is UNMEASURED
###############################################################################
mk_proj pa7 remote
printf -- '- 🔴 `ref_users` is read by two views\n' >> "$INDEX"
prof_set PF_ARTEFACT_GRAPH_CACHE '""'
run bash "$KITREL/kernel/rails-index.sh"; strip
{ [ "$RC" = 1 ] && has 'UNMEASURED' "$OUTT" && lacks 'MEASURED (graph cache' "$OUTT" && lacks 'edges=0' "$OUTT"; }; check A7 "PF_ARTEFACT_GRAPH_CACHE unset: UNMEASURED, rc=1 (rc=$RC)" $?
prof_set PF_ARTEFACT_GRAPH_CACHE '"claude-brain/pm-kit/state/artefact-graph.tsv"'
mkdir -p "$KITREL/state"; printf '\n\n' > "$KITREL/state/artefact-graph.tsv"
run bash "$KITREL/kernel/rails-index.sh"; strip
{ [ "$RC" = 1 ] && has '0 usable edges' "$OUTT" && lacks 'MEASURED (graph cache' "$OUTT"; }; check A7 "a cache with no edge is UNMEASURED (rc=$RC)" $?
printf 'ref_users\tv_users_summary\n' > "$KITREL/state/artefact-graph.tsv"
run bash "$KITREL/kernel/rails-index.sh"; strip
{ [ "$RC" = 0 ] && has 'expansion  *: MEASURED' "$OUTT" && has 'v_users_summary' "$KITREL/state/RAILS-BY-ARTEFACT.tsv"; }; check A7 "a cache with an edge is MEASURED and expands (rc=$RC)" $?

###############################################################################
# B6 — scratch space is a private mktemp -d directory, removed on exit
###############################################################################
mk_proj pb6 remote
mkdir -p "$SB/tmpd"
for tool in pm-preflight rails-index; do
  if [ "$tool" = pm-preflight ]; then XARGS=--no-fetch; else XARGS=""; fi
  run env TMPDIR="$SB/tmpd" bash -x "$KITREL/kernel/$tool.sh" $XARGS
  LEFT="$(find "$SB/tmpd" -mindepth 1 | wc -l | tr -d ' ')"
  { has "mktemp -d $SB/tmpd/" && [ "$LEFT" = 0 ]; }; check B6 "$tool uses mktemp -d under \$TMPDIR and leaves nothing behind" $?
done

###############################################################################
# B7 — core.hooksPath is compared as a path, not as a string
###############################################################################
mk_proj pb7 remote
mkdir -p .githooks && printf '#!/bin/sh\nexit 0\n' > .githooks/pre-commit && chmod +x .githooks/pre-commit
commit_all "hooks"
for hp in ".githooks" "./.githooks" ".githooks/" "$PROJ/.githooks"; do
  git config core.hooksPath "$hp"; case "$hp" in /*) lbl="(absolute path)" ;; *) lbl="'$hp'" ;; esac
  run bash bin/pm-preflight.sh --no-fetch; strip
  { has 'ok   hooks' "$OUTT" && lacks 'NO pre-commit gate' "$OUTT"; }; check B7 "core.hooksPath $lbl is recognised as .githooks" $?
done
git config core.hooksPath "other-hooks"
run bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN hooks' "$OUTT"; }; check B7 "a different hooks path still warns" $?
git config --unset core.hooksPath
run bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN hooks.*<unset>' "$OUTT"; }; check B7 "an unset hooks path still warns" $?

###############################################################################
# 1.5 — no remote / no upstream ref: WARN "single-clone mode", never STOP
###############################################################################
mk_proj p15 noremote
run bash bin/pm-preflight.sh; strip
{ [ "$RC" = 1 ] && has 'WARN upstream.*no shared reference — single-clone mode' "$OUTT" && lacks 'STOP' "$OUTT"; }; check 1.5 "a repo with no remote: WARN, not STOP (rc=$RC)" $?
{ has 'ok   mig-upstream.*n/a' "$OUTT" && has 'ok   mig-local.*n/a' "$OUTT" && lacks 'WARN fetch' "$OUTT"; }; check 1.5 "queue-vs-reference checks are n/a, no fetch noise" $?
mk_proj p15b remote
prof_set PF_REF_NAME '"origin/trunk"'
run bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 1 ] && has 'WARN upstream.*single-clone mode.*does not exist on remote' "$OUTT" && lacks 'STOP' "$OUTT"; }; check 1.5 "a remote without the named branch: WARN, not STOP (rc=$RC)" $?

###############################################################################
# 1.6 / A16 — queue and target legs are n/a when undeclared; CLEAR is reachable
###############################################################################
mk_proj p16 remote
prof_set PF_QUEUE_DIR '""'; prof_set PF_QUEUE_STAGING '""'; prof_set PF_TARGET_HOST '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   mig-upstream.*n/a (no queue declared)' "$OUTT" && has 'ok   mig-local.*n/a (no queue declared)' "$OUTT" \
  && has 'ok   mig-draft.*n/a (no queue declared)' "$OUTT" && has 'ok   queue-target.*n/a (no queue declared)' "$OUTT" \
  && has 'ok   namespace.*n/a (no queue declared)' "$OUTT" && has 'ok   slug-drift.*n/a (no queue declared)' "$OUTT" \
  && lacks 'no migration on' "$OUTT" && lacks 'no unpushed migration' "$OUTT"; }; check A16 "empty PF_QUEUE_DIR: every queue phase says n/a and measures nothing" $?
mk_proj p16b remote
prof_set PF_TARGET_HOST '""'; prof_set PF_QUEUE_TARGET '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   queue-target.*n/a (no deploy target declared)' "$OUTT" && lacks 'WARN queue-target' "$OUTT" && has 'ok   mig-upstream.*no migration on' "$OUTT"; }; check 1.6 "empty PF_TARGET_HOST: the target leg is n/a, the queue is still measured" $?
mk_proj p16c remote
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'UNMEASURED queue-target' "$OUTT" && [ "$RC" = 1 ]; }; check 1.6 "a declared target without --probe-db is UNMEASURED and keeps exit 1" $?

# CLEAR: everything declared is measured and clean
mk_proj p16d remote
prof_set PF_QUEUE_DIR '""'; prof_set PF_QUEUE_STAGING '""'; prof_set PF_TARGET_HOST '""'; prof_set PF_ALWAYS_PATHS '""'
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map
printf '# register\n' > "$MEMDIR/dev-handoff-register.md"
mkdir -p "$KITREL/state"; printf 'ref_users\tv_users_summary\n' > "$KITREL/state/artefact-graph.tsv"
printf -- '- 🔴 `ref_users` is read by two views · register: `dev-handoff-register.md`\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
commit_all "clear fixture"
run env ACME_DEV=a bash bin/pm-preflight.sh; strip
{ [ "$RC" = 0 ] && has 'CLEAR' "$OUTT"; }; check 1.6 "exit 0 (CLEAR) is reachable on a clean, fully-measured state (rc=$RC)" $?
{ has 'info *ownership.*NOT measured for this build' "$OUTT" && has 'info *rails.*NOT measured for this build' "$OUTT" && lacks 'ok   ownership' "$OUTT" && lacks 'ok   rails' "$OUTT"; }; check amb-b "no --paths and a clean tree: ownership and rails are reported NOT measured, never ok" $?

###############################################################################
# A2 — slug drift consumes PF_DRIFT_SLUG_RE (default: any [a-z] initial)
###############################################################################
mk_proj pa2 remote
mkdir -p db/migrations
printf 'CREATE TABLE billing_invoices (id INT);\n' > db/migrations/202601011200_a_billing_invoices.sql
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   slug-drift' "$OUTT" && lacks "slug '202601011200'" "$OUTT"; }; check A2 "a profile-conform '_a_' migration raises no false slug-drift (rc=$RC)" $?
printf 'CREATE TABLE crm_contacts (id INT);\n' > db/migrations/202601011201_a_billing_other.sql
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has "WARN slug-drift.*slug 'billing' creates table 'crm_contacts'" "$OUTT"; }; check A2 "a real divergence (slug billing, table crm_*) still warns" $?
printf 'CREATE TABLE ledger_rows (id INT);\n' > db/migrations/20260101__ledger_rows.sql
rm -f db/migrations/2026010112*.sql
prof_set PF_DRIFT_SLUG_RE "'s/^[0-9]*__//; s/[-_].*\$//'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   slug-drift' "$OUTT"; }; check A2 "a custom PF_DRIFT_SLUG_RE is honoured" $?

###############################################################################
# A4 / A5 — newline-safe candidate and shared-tool matching
###############################################################################
mk_proj pa4 remote
mkdir -p db/migrations bin src
printf 'ALTER TABLE a ADD CONSTRAINT fk_base FOREIGN KEY (x) REFERENCES b(id);\n' > db/migrations/202501010000_a_base.sql
printf '#!/bin/sh\n' > bin/deploy.sh; printf '<?php\n' > src/billing.php
commit_all "baseline migrations and tools"
printf 'ALTER TABLE a ADD CONSTRAINT fk_one FOREIGN KEY (x) REFERENCES b(id);\n' > db/migrations/202610020900_a_one.sql
printf 'ALTER TABLE a ADD CONSTRAINT fk_two FOREIGN KEY (y) REFERENCES b(id);\n' > db/migrations/202610020901_a_two.sql
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'STOP namespace' "$OUTT" && has 'WARN namespace.*2 name(s) clear of the repo corpus' "$OUTT"; }; check A4 "two new migrations with distinct constraints raise no false STOP (rc=$RC)" $?
printf 'ALTER TABLE a ADD CONSTRAINT fk_base FOREIGN KEY (z) REFERENCES b(id);\n' > db/migrations/202610020902_a_three.sql
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP namespace.*already declared elsewhere' "$OUTT" && has 'fk_base' "$OUTT"; }; check A4 "a name already declared in a committed migration still STOPs" $?
rm -f db/migrations/202610020900_a_one.sql db/migrations/202610020901_a_two.sql db/migrations/202610020902_a_three.sql
echo x >> bin/deploy.sh; echo y >> src/billing.php
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN shared-tool.*bin/deploy.sh' "$OUTT"; }; check A5 "a dirty shared tool is reported when another path is dirty too" $?
git checkout -q -- bin/deploy.sh src/billing.php

###############################################################################
# A6 — P7 parses the doctor's own WARN/FAIL lines and names the real failure
###############################################################################
mk_proj pa6 remote
printf '# failover\n' > "$MEMDIR/FAILOVER-notes.md"
run bash "$KITREL/doctor.sh" --strict; DRC=$RC; DOUTF="$OUT"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$DRC" = 0 ] && has '0 fail(s)' "$DOUTF" && lacks 'STOP memory' "$OUTT" && has 'WARN memory' "$OUTT"; }; check A6 "doctor reports 0 fails (orphan named FAILOVER-*): no STOP (doctor rc=$DRC)" $?
rm -f "$MEMDIR/FAILOVER-notes.md"
printf '\nsee [ghost](acme-pm-memory/ghost.md)\n' >> "$INDEX"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP memory.*doctor.sh FAIL: index links to missing topic files' "$OUTT" && lacks 'over hard budget' "$OUTT"; }; check A6 "a real doctor FAIL STOPs and quotes the actual failure (rc=$RC)" $?
rm -f "$INDEX"; cp "$C/skeleton/index-seed.md" "$INDEX"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'STOP memory' "$OUTT"; }; check A6 "restoring the seed index clears the STOP" $?

###############################################################################
# A1 — P6 consumes PF_ARB_ID_RE (default: any [a-z] initial), no hardcoded [kl]
###############################################################################
mk_proj pa1 remote
HR="$MEMDIR/dev-handoff-register.md"
printf '# register\n\n### H-20260101-a-old-question\n\n### H-20260102-k-foreign-initial\n' > "$HR"
printf '\nregister: dev-handoff-register.md\n' >> "$INDEX"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'arbitration.*H-20260101-a-old-question' "$OUTT" && lacks 'no open items' "$OUTT"; }; check A1 "an item by dev 'a' (profile declares a/b) is seen" $?
{ lacks 'H-20260102-k-foreign-initial' "$OUTT"; }; check A1 "PF_ARB_ID_RE is consumed: an initial outside [ab] is not read" $?
prof_set PF_ARB_ID_RE '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'H-20260101-a-old-question' "$OUTT" && has 'H-20260102-k-foreign-initial' "$OUTT"; }; check A1 "without PF_ARB_ID_RE the default accepts any [a-z] initial" $?
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$SB/awkshim-a1"; ln -sf "$(command -v mawk)" "$SB/awkshim-a1/awk"
  run env PATH="$SB/awkshim-a1:$PATH" ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
  { has 'H-20260101-a-old-question' "$OUTT" && has 'H-20260102-k-foreign-initial' "$OUTT"; }; check A1 "the same register is read under mawk (no {n} intervals)" $?
else skip A1 "mawk not installed (awk-flavour case)"; fi

###############################################################################
# A15 — one closure vocabulary (PF_ARB_CLOSED_RE), read by preflight AND doctor
###############################################################################
mk_proj pa15 remote
HR="$MEMDIR/dev-handoff-register.md"; HD="$MEMDIR/dev-handoff-register"; mkdir -p "$HD"
printf '# register\n\n### H-20260101-a-open-thing · waiting on a reply\n### H-20260101-a-done-thing · DONE\n### H-20260101-a-res-thing · RESOLVED 2026-01-03\n### H-20260101-a-closed-thing · CLOSED\n### H-20260101-a-ans-thing · ANSWERED\n### H-20260101-a-obs-thing · OBSOLETE\n### H-20260101-a-deco-thing · ✅ DONE\n### H-20260101-a-sus-thing - DONE somewhere\n' > "$HR"
printf '# bodies\n\n### H-20260101-a-open-thing · waiting on a reply\n### H-20260101-a-done-thing · DONE\n### H-20260101-a-res-thing · RESOLVED 2026-01-03\n### H-20260101-a-closed-thing · CLOSED\n### H-20260101-a-ans-thing · ANSWERED\n### H-20260101-a-obs-thing · OBSOLETE\n### H-20260101-a-deco-thing · ✅ DONE\n### H-20260101-a-sus-thing - DONE somewhere\n' > "$HD/open.md"
printf '\nregister: dev-handoff-register.md dev-handoff-register/open.md\n' >> "$INDEX"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'arbitration.*a-open-thing' "$OUTT" && lacks 'arbitration.*a-done-thing.* [0-9]* d open' "$OUTT" && lacks 'arbitration.*a-res-thing — [0-9]* d open' "$OUTT" \
  && lacks 'arbitration.*a-closed-thing — [0-9]* d open' "$OUTT" && lacks 'arbitration.*a-ans-thing — [0-9]* d open' "$OUTT" && lacks 'arbitration.*a-obs-thing — [0-9]* d open' "$OUTT"; }; check A15 "DONE / RESOLVED / CLOSED / ANSWERED / OBSOLETE items are closed in preflight" $?
{ has 'a-deco-thing(OFF-TEMPLATE)' "$OUTT" && has 'a-sus-thing(SUSPECT)' "$OUTT"; }; check A15 "decorated and off-separator closures are flagged, not silently counted" $?
run bash "$KITREL/doctor.sh"
{ has 'a-deco-thing' && has 'a-sus-thing' && lacks 'DIVERGENT\|a-done-thing'; }; check A15 "doctor section 12 reads the same vocabulary (no divergence on DONE)" $?
prof_set PF_ARB_CLOSED_RE "'FINI|BOUCLE'"
printf '### H-20260101-a-fini-thing · FINI\n' >> "$HR"; printf '### H-20260101-a-fini-thing · FINI\n' >> "$HD/open.md"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'arbitration.*a-fini-thing.* [0-9]* d open' "$OUTT" && has 'arbitration.*a-done-thing.* [0-9]* d open' "$OUTT"; }; check A15 "a profile-supplied vocabulary replaces the default" $?
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$SB/awkshim-a15"; ln -sf "$(command -v mawk)" "$SB/awkshim-a15/awk"
  run env PATH="$SB/awkshim-a15:$PATH" ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
  { lacks 'arbitration.*a-fini-thing.* [0-9]* d open' "$OUTT" && has 'arbitration.*a-done-thing.* [0-9]* d open' "$OUTT"; }; check A15 "same verdicts under mawk" $?
  LC_ALL=C run bash bin/pm-preflight.sh --no-fetch; strip
  { lacks 'arbitration.*a-fini-thing.* [0-9]* d open' "$OUTT" && has 'arbitration.*a-done-thing.* [0-9]* d open' "$OUTT"; }; check A15 "same verdicts under LC_ALL=C" $?
else skip A15 "mawk not installed (awk-flavour case)"; fi

###############################################################################
# A17 — PF_ARB_STOP_DAYS is honoured as a STOP
###############################################################################
mk_proj pa17 remote
HR="$MEMDIR/dev-handoff-register.md"
printf '# register\n\n### H-%s-a-ageing-item\n' "$(ago_ymd 4)" > "$HR"
printf '\nregister: dev-handoff-register.md\n' >> "$INDEX"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" != 2 ] && has 'WARN arbitration.*ageing-item — 4 d open' "$OUTT" && lacks 'STOP arbitration' "$OUTT"; }; check A17 "an item 4 days old (past WARN_DAYS=3) only WARNs (rc=$RC)" $?
printf '### H-%s-a-overdue-item\n' "$(ago_ymd 10)" >> "$HR"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 1 ] && has 'WARN arbitration.*\[ambient\].*overdue-item — 10 d open, past the 7d stop threshold' "$OUTT" && lacks 'STOP' "$OUTT"; }; check A17 "an item 10 days old (past STOP_DAYS=7) is an ambient WARN, exit 1, never a STOP (rc=$RC)" $?
{ has 'ambient' "$OUTT" && has '1 ambient' "$OUTT"; }; check A17 "the verdict line counts ambient warnings separately" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --json
{ has '"check":"arbitration","msg":"\[ambient\][^"]*overdue-item[^"]*","ambient":true' && has '"stop":0' && has '"ambient_warn":1'; }; check A17 "--json: the overdue item row carries ambient:true; stop=0; ambient_warn counted in the summary object" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths src/x.php; strip
{ [ "$RC" = 1 ] && has 'overdue-item' "$OUTT"; }; check A17 "an overdue item does not raise the exit code to 2 for an unrelated build either (rc=$RC)" $?

###############################################################################
# A3 — a live claim stays live unless its last row is closed/abandoned
###############################################################################
mk_proj pa3 remote
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map
TODAY_ISO="$(date -u +%F)"; LINT="$KITREL/kernel/ownership-lint.sh"
CL=claude-brain/CLAIMS.tsv
printf 'open\t%s\tb\tbilling-rework\tsrc/billing*\tnote\ts-deadbeef\n' "$TODAY_ISO" > $CL
run bash $LINT --dev a src/billing.php
{ [ "$RC" = 2 ] && has "under an OPEN CLAIM by 'b'"; }; check A3 "an open claim by the other dev blocks (rc=$RC)" $?
printf 'restated\t%s\tb\tbilling-rework\tsrc/billing*\tstill on it\ts-deadbeef\n' "$TODAY_ISO" >> $CL
run bash $LINT --dev a src/billing.php
{ [ "$RC" = 2 ] && has "under an OPEN CLAIM by 'b'"; }; check A3 "a restated row keeps the claim live (rc=$RC)" $?
printf 'closed\t%s\tb\tbilling-rework\tsrc/billing*\tdone\ts-deadbeef\n' "$TODAY_ISO" >> $CL
run bash $LINT --dev a src/billing.php
{ [ "$RC" = 0 ] && lacks 'CLAIM'; }; check A3 "a closed last row releases it (rc=$RC)" $?
printf 'open\t%s\tb\tother\tsrc/other*\tn\ts-1\nabandoned\t%s\tb\tother\tsrc/other*\tn\ts-1\n' "$TODAY_ISO" "$TODAY_ISO" >> $CL
run bash $LINT --dev a src/other.php
{ [ "$RC" = 0 ] && lacks 'CLAIM'; }; check A3 "an abandoned last row releases it (rc=$RC)" $?
printf 'restated\t%s\tb\treopened\tsrc/billing*\tn\ts-2\n' "$TODAY_ISO" >> $CL
run bash $LINT --dev a src/billing.php
{ [ "$RC" = 2 ] && has "'reopened'"; }; check A3 "a slug whose only row is restated is live (rc=$RC)" $?

###############################################################################
# A19 — PF_CLAIM_STALE_DAYS is consumed (default 3)
###############################################################################
mk_proj pa19 remote
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map
LINT="$KITREL/kernel/ownership-lint.sh"; CL=claude-brain/CLAIMS.tsv
printf 'open\t%s-%s-%s\ta\tmine\tsrc/other*\tnote\n' "$(ago_ymd 7 | cut -c1-4)" "$(ago_ymd 7 | cut -c5-6)" "$(ago_ymd 7 | cut -c7-8)" > $CL
prof_set PF_CLAIM_STALE_DAYS '"30"'
run bash $LINT --dev a src/billing.php
{ lacks 'days old'; }; check A19 "a 7-day claim is not flagged with PF_CLAIM_STALE_DAYS=30" $?
prof_set PF_CLAIM_STALE_DAYS '"3"'
run bash $LINT --dev a src/billing.php
{ has 'claim mine by a is 7 days old'; }; check A19 "a 7-day claim is flagged with PF_CLAIM_STALE_DAYS=3" $?
prof_set PF_CLAIM_STALE_DAYS '""'
run bash $LINT --dev a src/billing.php
{ has 'is 7 days old'; }; check A19 "an empty PF_CLAIM_STALE_DAYS falls back to 3" $?

###############################################################################
# (a) — --claim-exempt waives the CLAIM check in BOTH branches, keeps the LANE check
###############################################################################
mk_proj pca remote
printf 'own a ops claude-brain/*\nfrozen * fiscal claude-brain/frozen.md\n' > claude-brain/OWNERSHIP.map
LINT="$KITREL/kernel/ownership-lint.sh"; CL=claude-brain/CLAIMS.tsv; GOV=claude-brain/CLAIMS.tsv
printf 'open\t%s\tb\tgov-edit\tclaude-brain/*\tnote\ts-bbbbbbbb\n' "$TODAY_ISO" > $CL
run bash $LINT --dev a $GOV
{ [ "$RC" = 2 ] && has "under an OPEN CLAIM by 'b'"; }; check claim-exempt "baseline: another dev's claim blocks the governance path (rc=$RC)" $?
run bash $LINT --dev a --claim-exempt "$GOV" $GOV
{ [ "$RC" = 0 ] && has 'claim-exempt' && lacks '⛔'; }; check claim-exempt "cross-dev branch: exempt path is not blocked (rc=$RC)" $?
run bash $LINT --dev a --claim-exempt "$GOV" claude-brain/other.md
{ [ "$RC" = 2 ] && has "under an OPEN CLAIM by 'b'"; }; check claim-exempt "a NON-exempt path under the same claim still blocks (rc=$RC)" $?
printf 'open\t%s\ta\tmine\tclaude-brain/*\tnote\tacme-aaaaaaaa\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=cccccccc-0000-4000-8000-000000000000 bash $LINT --dev a $GOV
{ [ "$RC" = 2 ] && has 'ANOTHER SESSION of the same dev'; }; check claim-exempt "baseline: same dev, other session blocks the governance path (rc=$RC)" $?
run env CLAUDE_CODE_SESSION_ID=cccccccc-0000-4000-8000-000000000000 bash $LINT --dev a --claim-exempt "$GOV" $GOV
{ [ "$RC" = 0 ] && has 'claim-exempt' && lacks 'ANOTHER SESSION'; }; check claim-exempt "same-dev/other-session branch: exempt path is not blocked (rc=$RC)" $?
run bash $LINT --dev a --claim-exempt claude-brain/frozen.md claude-brain/frozen.md
{ [ "$RC" = 2 ] && has 'FROZEN lane'; }; check claim-exempt "the LANE check still applies to an exempt path (frozen, rc=$RC)" $?

###############################################################################
# A18 — paths with spaces, untracked directories and renames are judged whole
###############################################################################
mk_proj pa18 remote
mkdir -p src
prof_set PF_ALWAYS_PATHS '""'   # isolate the dirty-path population (the always-checked set is exercised by case (b))
printf 'own a logic src/*\nfrozen * fiscal src/my?file.php\nfrozen * fiscal newdir/frozen*\n' > claude-brain/OWNERSHIP.map
LINT="$KITREL/kernel/ownership-lint.sh"
run bash $LINT --dev a 'src/my file.php'
{ [ "$RC" = 2 ] && has 'src/my file.php — FROZEN lane' && lacks 'src/my — UNMAPPED' && lacks 'file.php — UNMAPPED'; }; check A18 "ownership-lint judges 'src/my file.php' as one path (rc=$RC)" $?
printf 'x\n' > "src/my file.php"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT"; }; check A18 "pre-flight passes a dirty path with a space to the lint whole (rc=$RC)" $?
rm -f "src/my file.php"
mkdir -p newdir; printf 'x\n' > newdir/frozenx.php
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT"; }; check A18 "a file inside an untracked directory is judged, not just 'newdir/' (rc=$RC)" $?
rm -rf newdir
printf 'frozen * fiscal src/old.php\nfrozen * fiscal src/frozen?file.php\n' >> claude-brain/OWNERSHIP.map
printf 'x\n' > src/old.php; printf 'y\n' > src/old2.php; commit_all "old"
git mv src/old.php "src/plain name.php"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'STOP ownership' "$OUTT"; }; check A18 "a staged rename: the OLD path (frozen lane) is not judged (rc=$RC)" $?
git mv "src/plain name.php" src/old.php
git mv src/old2.php "src/frozen file.php"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT"; }; check A18 "a staged rename: the NEW path with a space is judged whole (rc=$RC)" $?
git mv "src/frozen file.php" src/old2.php

###############################################################################
# A12 — an unset dev variable gets its own message, not "SHARED lane"
###############################################################################
mk_proj pa12 remote
prof_set PF_ALWAYS_PATHS '""'
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map; mkdir -p src; printf '# state\topened\tdev\tslug\tglobs\tnote\tsession\n' > claude-brain/CLAIMS.tsv
run env -u ACME_DEV bash bin/pm-preflight.sh --no-fetch --paths src/billing.php; strip
{ has 'UNMEASURED ownership.*ACME_DEV is unset.*CANNOT be judged' "$OUTT" && lacks 'SHARED' "$OUTT"; }; check A12 "ACME_DEV unset: named as such and UNMEASURED, not a shared lane" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths src/billing.php; strip
{ has 'ok   ownership.*within the acting dev' "$OUTT"; }; check A12 "ACME_DEV set: the lane verdict is given" $?

###############################################################################
# (a) pre-flight side — always-checked paths go to the lint as claim-exempt
###############################################################################
mk_proj pcb remote
prof_set PF_ALWAYS_PATHS '"claude-brain/CLAIMS.tsv"'
printf 'own a logic src/*\nown a ops claude-brain/*\n' > claude-brain/OWNERSHIP.map; mkdir -p src
printf 'open\t%s\tb\tgov-edit\tclaude-brain/*\tnote\ts-bbbbbbbb\n' "$(date -u +%F)" > claude-brain/CLAIMS.tsv
commit_all "claim fixture"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths src/billing.php; strip
{ lacks 'STOP ownership' "$OUTT"; }; check claim-exempt "another dev's claim over an always-checked path does not STOP an unrelated build (rc=$RC)" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths claude-brain/other.md; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT"; }; check claim-exempt "the same claim still STOPs a build that really touches the surface (rc=$RC)" $?

###############################################################################
# (b) — a STOP arising only from an always-checked path is ambient: WARN, labelled
###############################################################################
mk_proj pcc remote
prof_set PF_ALWAYS_PATHS '"claude-brain/FROZEN.md"'
printf 'own a logic src/*\nfrozen * fiscal claude-brain/FROZEN.md\n' > claude-brain/OWNERSHIP.map; mkdir -p src
printf '# state\topened\tdev\tslug\tglobs\tnote\tsession\n' > claude-brain/CLAIMS.tsv
printf '# frozen\n' > claude-brain/FROZEN.md
printf -- '- ⛔ never edit `claude-brain/FROZEN.md` by hand\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
commit_all "ambient fixture"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths src/billing.php; strip
{ lacks 'STOP' "$OUTT" && has 'WARN ownership.*\[ambient\]' "$OUTT" && has 'WARN rails.*\[ambient\]' "$OUTT"; }; check amb-b "frozen + STOP-rail always-checked path, clean build: WARN labelled ambient, no STOP (rc=$RC)" $?
{ [ "$RC" = 1 ]; }; check amb-b "the run exits 1, not 2 (rc=$RC)" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'STOP' "$OUTT" && has 'WARN ownership.*\[ambient\]' "$OUTT"; }; check amb-b "no --paths, clean tree: still ambient WARN, never STOP (rc=$RC)" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths claude-brain/FROZEN.md; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT" && has 'STOP rails' "$OUTT" && lacks '\[ambient\]' "$OUTT"; }; check amb-b "the caller passing the same path itself: real STOPs (rc=$RC)" $?
echo edit >> claude-brain/FROZEN.md
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 2 ] && has 'STOP ownership' "$OUTT" && has 'STOP rails' "$OUTT"; }; check amb-b "the same path DIRTY in the worktree is the build's own: real STOPs (rc=$RC)" $?
git checkout -q -- claude-brain/FROZEN.md

###############################################################################
# A2 — exit 3 means "did not run"; 0/1/2 stay verdicts
###############################################################################
mk_proj pa2x remote
run bash bin/pm-preflight.sh --bogus-flag
{ [ "$RC" = 3 ] && has "unknown arg"; }; check A2x "pm-preflight: a bad argument did not run, exit 3 (rc=$RC)" $?
rm -rf "$KITREL/profiles"
run bash bin/pm-preflight.sh
{ [ "$RC" = 3 ] && has 'NOT RUN' && has 'no profile found'; }; check A2x "pm-preflight: no profile did not run, exit 3, says NOT RUN (rc=$RC)" $?
run bash "$KITREL/kernel/ownership-lint.sh" --dev a src/x
{ [ "$RC" = 3 ] && has 'NOT RUN'; }; check A2x "ownership-lint: no profile did not run, exit 3 (rc=$RC)" $?
run bash "$KITREL/kernel/rails-index.sh"
{ [ "$RC" = 3 ] && has 'NOT RUN'; }; check A2x "rails-index: no profile did not run, exit 3 (rc=$RC)" $?
mk_proj pa2y remote
# shellcheck disable=SC2046  # the tool list is a word list
mk_toolpath "$SB/nocomm" $(for t in $COMMON_TOOLS; do [ "$t" = comm ] || printf '%s ' "$t"; done)
run env PATH="$SB/nocomm" "$(command -v bash)" "$KITREL/kernel/pm-preflight.sh" --no-fetch
{ [ "$RC" = 3 ] && has "NOT RUN — required tool 'comm'"; }; check A2x "pm-preflight: a missing tool did not run, exit 3 (rc=$RC)" $?
mv "$KITREL/kernel/pm-preflight.sh" "$KITREL/kernel/pm-preflight.sh.away"
run bash bin/pm-preflight.sh
{ [ "$RC" = 3 ] && has 'NOT RUN — kernel not found'; }; check A2x "launcher: a missing kernel is exit 3, not the shell's 126/127 (rc=$RC)" $?
mv "$KITREL/kernel/pm-preflight.sh.away" "$KITREL/kernel/pm-preflight.sh"
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map
run bash "$KITREL/kernel/ownership-lint.sh" --dev a --map "$SB/no-such-map" src/x
{ [ "$RC" = 3 ] && has 'NOT RUN — no ownership map'; }; check A2x "ownership-lint: no map is 'cannot judge', exit 3, not a shared-lane 1 (rc=$RC)" $?
run bash "$KITREL/kernel/ownership-lint.sh" --quiet src/x
{ [ "$RC" = 3 ] && has 'NOT RUN.*unset'; }; check A2x "ownership-lint --quiet: unknown dev still says so, exit 3 (rc=$RC)" $?
printf '# state\topened\tdev\tslug\tglobs\tnote\tsession\n' > claude-brain/CLAIMS.tsv
run bash "$KITREL/kernel/ownership-lint.sh" --dev a --quiet src/x
{ [ "$RC" = 0 ]; }; check A2x "ownership-lint: an own-lane path is still exit 0 (rc=$RC)" $?
# rails-index: expansion not declared at all is n/a (0); declared and unread is unmeasured (1)
mk_proj pa2z remote
printf -- '- 🔴 `ref_users` is read by two views\n' >> "$INDEX"
prof_set PF_ARTEFACT_EXPAND '""'; prof_set PF_ARTEFACT_GRAPH_CACHE '""'
run bash "$KITREL/kernel/rails-index.sh"; strip
{ [ "$RC" = 0 ] && has 'expansion  *: n/a' "$OUTT" && lacks 'UNMEASURED' "$OUTT"; }; check A2x "rails-index: no view graph declared is n/a, exit 0 (rc=$RC)" $?
prof_set PF_ARTEFACT_EXPAND "'echo declared'"
run bash "$KITREL/kernel/rails-index.sh"; strip
{ [ "$RC" = 1 ] && has 'UNMEASURED' "$OUTT"; }; check A2x "rails-index: a declared expansion with no cache stays unmeasured, exit 1 (rc=$RC)" $?

###############################################################################
# A1 / A3 — the ambient marker and the unmeasured level, in text and in --json
###############################################################################
# (the "pcc" fixture above leaves the ambient STOPs in place on a clean build)
mk_proj pam remote
prof_set PF_ALWAYS_PATHS '"claude-brain/FROZEN.md"'
printf 'own a logic src/*\nfrozen * fiscal claude-brain/FROZEN.md\n' > claude-brain/OWNERSHIP.map; mkdir -p src
printf '# state\topened\tdev\tslug\tglobs\tnote\tsession\n' > claude-brain/CLAIMS.tsv
printf '# frozen\n' > claude-brain/FROZEN.md
printf -- '- ⛔ never edit `claude-brain/FROZEN.md` by hand\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
commit_all "ambient json fixture"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --json --paths src/billing.php
{ has '"check":"ownership","msg":"\[ambient\][^"]*","ambient":true' && has '"check":"rails","msg":"\[ambient\][^"]*","ambient":true'; }; check A1 "--json: ambient rows carry \"ambient\":true and the [ambient] marker" $?
{ ! has '"check":"ownership","msg":"[^"]*"}' ; }; check A1 "--json: no ownership row lacks the flag when it is ambient" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths claude-brain/FROZEN.md --json
{ ! has '"ambient":true'; }; check A1 "--json: a build's own STOP is not marked ambient" $?
# A3 — unmeasured is its own level
mk_proj pun remote
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --json
{ has '"level":"unmeasured","check":"queue-target"' && has '"unmeasured":[1-9]'; }; check A3 "--json: a declared-but-unreached target is level \"unmeasured\", counted in the summary object" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'UNMEASURED queue-target' "$OUTT" && has '[0-9]* unmeasured' "$OUTT" && [ "$RC" = 1 ]; }; check A3 "text: UNMEASURED line, counted separately in the verdict, exit 1 (rc=$RC)" $?
{ lacks 'WARN queue-target' "$OUTT" && lacks 'info *queue-target' "$OUTT"; }; check A3 "text: unmeasured is neither WARN nor info" $?
# undeclared => n/a, never unmeasured
prof_set PF_QUEUE_DIR '""'; prof_set PF_QUEUE_STAGING '""'; prof_set PF_TARGET_HOST '""'; prof_set PF_ALWAYS_PATHS '""'
prof_set PF_OWNERSHIP_MAP '""'; prof_set PF_ARB_FILE '""'; prof_set PF_RAILS_OUTPUT '""'; prof_set PM_DOCTOR '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --json
{ ! has '"level":"unmeasured"'; }; check A3 "every undeclared target is n/a: no unmeasured row" $?
# declared but absent => unmeasured, exit 1
prof_set PF_OWNERSHIP_MAP '"claude-brain/NO-SUCH.map"'; prof_set PF_ARB_FILE '"claude-brain/no-such-register.md"'
prof_set PF_RAILS_OUTPUT '"claude-brain/pm-kit/state/none.tsv"'; prof_set PM_DOCTOR '"claude-brain/pm-kit/no-such-doctor.sh"'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'UNMEASURED ownership' "$OUTT" && has 'UNMEASURED arbitration' "$OUTT" && has 'UNMEASURED rails' "$OUTT" && has 'UNMEASURED memory' "$OUTT" && [ "$RC" = 1 ]; }; check A3 "declared-but-absent map/register/rails/doctor are each UNMEASURED, exit 1 (rc=$RC)" $?

###############################################################################
# A4 — N code commits since the last memory commit
###############################################################################
mk_proj pa4m remote
prof_set PF_MEMORY_COMMIT_WARN '"3"'; prof_set PF_ALWAYS_PATHS '"claude-brain/CLAIMS.tsv"'
mkdir -p src; printf '# state\topened\tdev\tslug\tglobs\tnote\tsession\n' > claude-brain/CLAIMS.tsv
printf '\nbaseline\n' >> "$INDEX"
commit_all "memory commit (also carries the profile and the claims file)"
printf 'a\n' > src/a.txt; commit_all "code 1"
printf 'b\n' > src/b.txt; commit_all "code 2"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   memory-fresh.*2 code commit(s) since the last memory commit' "$OUTT" && lacks 'WARN memory-fresh' "$OUTT"; }; check A4 "2 code commits (< threshold 3): ok, counted" $?
printf 'c\n' > src/c.txt; commit_all "code 3"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN memory-fresh.*3 code commit(s) since the last memory commit' "$OUTT"; }; check A4 "3 code commits (= threshold): WARN" $?
printf 'claim\n' >> claude-brain/CLAIMS.tsv; commit_all "claims only"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN memory-fresh.*3 code commit(s)' "$OUTT"; }; check A4 "a commit touching only an always-checked governance path is not a code commit" $?
printf '\nnote\n' >> "$INDEX"; commit_all "memory"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   memory-fresh.*0 code commit(s)' "$OUTT"; }; check A4 "a memory commit resets the count" $?
prof_set PF_MEMORY_PATHS '"claude-brain/never-committed.md"'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   memory-fresh.*n/a (no commit has touched the memory paths yet)' "$OUTT"; }; check A4 "no memory commit yet: n/a, never a count against the whole history" $?
prof_set PF_MEMORY_COMMIT_WARN '"0"'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   memory-fresh.*n/a (PF_MEMORY_COMMIT_WARN=0' "$OUTT"; }; check A4 "PF_MEMORY_COMMIT_WARN=0 turns the check off" $?

###############################################################################
# 6 — the rails table older than its sources is a WARN, never silently used
###############################################################################
mk_proj prs remote
printf -- '- 🔴 `ref_users` is read by two views\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths ref_users; strip
{ lacks 'rails-stale' "$OUTT"; }; check rails-fresh "a table generated after the index is not stale" $?
touch -t "$(ago_stamp 1)" "$KITREL/state/RAILS-BY-ARTEFACT.tsv"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths ref_users; strip
{ has 'WARN rails-stale.*acme-pm-memory.md is newer than' "$OUTT"; }; check rails-fresh "an index newer than the table WARNs and names the file" $?
run bash "$KITREL/kernel/rails-index.sh"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths ref_users; strip
{ lacks 'rails-stale' "$OUTT"; }; check rails-fresh "regenerating clears the warning" $?

###############################################################################
# A5 — P6 prints id and title of every open item; header, declared age and
#      escalation wording come from the profile, nothing is hardcoded
###############################################################################
mk_proj pa5 remote
HR="$MEMDIR/dev-handoff-register.md"
printf '# register\n\n### H-%s-a-fresh-item · Which importer for the CSV feed?\n### H-%s-a-old-item · Rename the billing table? · 1 d\n### H-%s-a-late-item · Pick the tax rounding mode\n### H-%s-a-shut-item · DONE\n' "$(ago_ymd 0)" "$(ago_ymd 5)" "$(ago_ymd 12)" "$(ago_ymd 30)" > "$HR"
prof_set PF_ARB_DECLARED_AGE_RE '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   arbitration.*a-fresh-item — Which importer for the CSV feed? — 0 d open' "$OUTT" \
  && has 'WARN arbitration.*a-old-item — Rename the billing table?.* — 5 d open' "$OUTT" \
  && has 'WARN arbitration.*\[ambient\].*a-late-item — Pick the tax rounding mode — 12 d open, past the 7d stop threshold' "$OUTT"; }; check A5 "every open item is listed with its id and title, at its own level" $?
{ lacks 'a-shut-item' "$OUTT"; }; check A5 "a closed item is not listed" $?
{ lacks 'STALE' "$OUTT" && lacks 'escalation' "$OUTT" && lacks ' j ' "$OUTT"; }; check A5 "no declared-age field is read and the pre-flight carries no escalation wording" $?
prof_set PF_ARB_DECLARED_AGE_RE "'· [0-9]+ d'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'a-old-item.*\[declared 1d — STALE\]' "$OUTT" && lacks 'escalation' "$OUTT"; }; check A5 "PF_ARB_DECLARED_AGE_RE flags a stale declared age, in English" $?
# a register with another header shape and another id shape
printf '# questions\n\n## Q-%s-x-pricing · Which tier names?\n### H-%s-a-ignored-item · not a header here\n' "$(ago_ymd 9)" "$(ago_ymd 9)" > "$HR"
prof_set PF_ARB_HEADER_RE "'^## Q-'"
prof_set PF_ARB_ID_RE "'Q-[0-9]+-[a-z]-[a-z]+'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ [ "$RC" = 1 ] && has 'WARN arbitration.*\[ambient\].*Q-[0-9]*-x-pricing — Which tier names? — 9 d open' "$OUTT" && lacks 'ignored-item' "$OUTT"; }; check A5 "PF_ARB_HEADER_RE selects the header lines; the date is read from the id whatever its prefix (rc=$RC)" $?
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$SB/awkshim-a5"; ln -sf "$(command -v mawk)" "$SB/awkshim-a5/awk"
  run env PATH="$SB/awkshim-a5:$PATH" ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
  { has 'WARN arbitration.*\[ambient\].*Q-[0-9]*-x-pricing — Which tier names? — 9 d open' "$OUTT"; }; check A5 "same listing under mawk" $?
else skip A5 "mawk not installed (awk-flavour case)"; fi

###############################################################################
# A13 — a claim's session field is recognised in any rendering of MY id, or
#       rejected by name with the expected form
###############################################################################
mk_proj pa13 remote
printf 'own a logic src/*\n' > claude-brain/OWNERSHIP.map
LINT="$KITREL/kernel/ownership-lint.sh"; CL=claude-brain/CLAIMS.tsv
SID=abcd1234-0000-4000-8000-000000000000
printf 'open\t%s\ta\tmine\tsrc/billing*\tn\tacme-abcd1234\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/billing.php
{ [ "$RC" = 0 ] && has "under YOUR open claim 'mine'" && lacks 'canonical'; }; check A13 "the canonical field is mine (rc=$RC)" $?
printf 'open\t%s\ta\tfullid\tsrc/full*\tn\t%s\n' "$TODAY_ISO" "$SID" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/full.php
{ [ "$RC" = 0 ] && has "under YOUR open claim 'fullid'" && has 'not in the canonical form' && has 'acme-abcd1234'; }; check A13 "a hand-typed FULL session id is recognised as mine, and the canonical form is named (rc=$RC)" $?
printf 'open\t%s\ta\tbare\tsrc/bare*\tn\tabcd1234\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/bare.php
{ [ "$RC" = 0 ] && has "under YOUR open claim 'bare'" && has 'not in the canonical form'; }; check A13 "the 8 characters without the prefix are recognised as mine (rc=$RC)" $?
printf 'open\t%s\ta\tgarbled\tsrc/garbled*\tn\tsession one\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/garbled.php
{ [ "$RC" = 2 ] && has 'MALFORMED session field' && has "expected 'acme-' followed by the first 8 characters" && lacks 'ANOTHER SESSION'; }; check A13 "a malformed field is rejected by name, with the expected form (rc=$RC)" $?
printf 'open\t%s\ta\tother\tsrc/other*\tn\tacme-ffffffff\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/other.php
{ [ "$RC" = 2 ] && has 'ANOTHER SESSION' && lacks 'MALFORMED'; }; check A13 "a well-formed field of ANOTHER session is still another session (rc=$RC)" $?
printf 'open\t%s\ta\tother\tsrc/other*\tn\tffffffff-0000-4000-8000-000000000000\n' "$TODAY_ISO" > $CL
run env CLAUDE_CODE_SESSION_ID=$SID bash $LINT --dev a src/other.php
{ [ "$RC" = 2 ] && has 'MALFORMED' && has 'treated as another session'; }; check A13 "another session's FULL id is not mine: rejected as malformed (rc=$RC)" $?
# the pre-commit gate refuses the hand-typed form at write time
mk_proj pa13g remote
printf '# claims\n' > claude-brain/CLAIMS.tsv; commit_all "claims baseline"
printf 'open\t%s\ta\tfullid\tsrc/full*\tn\t%s\n' "$TODAY_ISO" "$SID" >> claude-brain/CLAIMS.tsv
git add -- claude-brain/CLAIMS.tsv
run bash "$KITREL/lint-claims-session.sh"
{ [ "$RC" = 1 ] && has 'not in the canonical form' && has "Expected: 'acme-'"; }; check A13 "the claims gate refuses a live row whose session is not prefix+8 (rc=$RC)" $?
git reset -q -- claude-brain/CLAIMS.tsv; git checkout -q -- claude-brain/CLAIMS.tsv
printf 'open\t%s\ta\tcanon\tsrc/c*\tn\tacme-abcd1234\n' "$TODAY_ISO" >> claude-brain/CLAIMS.tsv
git add -- claude-brain/CLAIMS.tsv
run bash "$KITREL/lint-claims-session.sh"
{ [ "$RC" = 0 ] && has 'OK'; }; check A13 "the claims gate accepts the canonical form (rc=$RC)" $?
git reset -q -- claude-brain/CLAIMS.tsv; git checkout -q -- claude-brain/CLAIMS.tsv
{ ! grep -q '^PF_CLAIMS_FORMAT="state' "$C/profiles/example.conf"; }; check A13 "the stale 6-field PF_CLAIMS_FORMAT line is gone from the example profile" $?

###############################################################################
# A9 — leftovers: UTF-8-safe truncation, backslash paths, PF_QUEUE_TARGET,
#      solo-mode doctor, `--` path terminator
###############################################################################
# (a) a rail truncated at PF_RAILS_TRUNCATE is cut on a character boundary in every awk
mk_proj pa9a remote
EACC="$(printf '\303\251')"; LONGE=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do LONGE="$LONGE$EACC"; done
printf -- '- 🔴 `ref_users` %s\n' "$LONGE" >> "$INDEX"
if command -v iconv >/dev/null 2>&1; then
  mkdir -p "$SB/awk9g" "$SB/awk9m"
  command -v gawk >/dev/null 2>&1 && ln -sf "$(command -v gawk)" "$SB/awk9g/awk"
  command -v mawk >/dev/null 2>&1 && ln -sf "$(command -v mawk)" "$SB/awk9m/awk"
  for T in 19 20 21 22; do
    prof_set PF_RAILS_TRUNCATE "\"$T\""
    for cfg in gawk-C mawk gawk-utf8; do
      case $cfg in
        gawk-C)    [ -x "$SB/awk9g/awk" ] || continue; run env PATH="$SB/awk9g:$PATH" LC_ALL=C bash "$KITREL/kernel/rails-index.sh" ;;
        mawk)      [ -x "$SB/awk9m/awk" ] || continue; run env PATH="$SB/awk9m:$PATH" bash "$KITREL/kernel/rails-index.sh" ;;
        gawk-utf8) [ -x "$SB/awk9g/awk" ] && [ -n "$UTF8_LOC" ] || continue; run env PATH="$SB/awk9g:$PATH" LC_ALL="$UTF8_LOC" bash "$KITREL/kernel/rails-index.sh" ;;
      esac
      iconv -f UTF-8 -t UTF-8 "$KITREL/state/RAILS-BY-ARTEFACT.tsv" > /dev/null 2>&1; irc=$?
      { [ "$irc" = 0 ]; }; check A9a "truncation at $T ($cfg): the table is valid UTF-8 (iconv rc=$irc)" $?
    done
  done
else
  skip A9a "iconv not installed"
fi
# (b) a path containing a backslash matches its own rail row
mk_proj pa9b remote
printf -- '- 🔴 `src/a\\tb.php` is sealed\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths 'src/a\tb.php'; strip
{ has 'WARN rails.*src/a.tb.php' "$OUTT"; }; check A9b "a backslash in a path is not rewritten by awk -v (the rail is found)" $?
# (c) PF_QUEUE_TARGET is the target leg
mk_proj pa9c remote
mkdir -p db/migrations
printf 'SELECT 1;\n' > db/migrations/202601010000_a_one.sql; printf 'SELECT 2;\n' > db/migrations/202601010001_a_two.sql
commit_all "two queued changes"
prof_set PF_TARGET_HOST '"nobody@host.invalid"'
prof_set PF_QUEUE_TARGET "'printf \"202601010000_a_one.sql\\n202601010001_a_two.sql\\n\"'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --probe-db; strip
{ has 'ok   queue-target.*deploy target == ' "$OUTT"; }; check A9c "PF_QUEUE_TARGET is used, not an ssh to PF_TARGET_HOST (target == reference)" $?
prof_set PF_QUEUE_TARGET "'printf \"202601010000_a_one.sql\\n\"'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --probe-db; strip
{ has 'WARN queue-target.*not yet on the deploy target' "$OUTT" && has '202601010001_a_two.sql' "$OUTT"; }; check A9c "a queued change missing from the target is named" $?
prof_set PF_QUEUE_TARGET "'printf \"202601010000_a_one.sql\\n202601010001_a_two.sql\\n202601010099_a_rogue.sql\\n\"'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --probe-db; strip
{ [ "$RC" = 2 ] && has 'STOP queue-target.*on the deploy target and NOT on' "$OUTT" && has 'rogue' "$OUTT"; }; check A9c "a change on the target that git does not have STOPs (rc=$RC)" $?
prof_set PF_QUEUE_TARGET "'false'"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --probe-db; strip
{ has 'UNMEASURED queue-target.*PF_QUEUE_TARGET command failed' "$OUTT"; }; check A9c "a failing PF_QUEUE_TARGET command is UNMEASURED" $?
prof_set PF_QUEUE_TARGET '""'; prof_set PF_TARGET_HOST '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --probe-db; strip
{ has 'ok   queue-target.*n/a (no deploy target declared)' "$OUTT"; }; check A9c "neither declared: n/a" $?
# (d) doctor: a repository with no remote has nothing to fetch
mk_proj pa9d noremote
run bash "$KITREL/doctor.sh"
{ lacks 'never fetched' && has 'fetch age: n/a (no remote configured'; }; check A9d "doctor on a no-remote repo: fetch age is n/a, not 'never fetched'" $?
mk_proj pa9d2 remote
rm -f .git/FETCH_HEAD
run bash "$KITREL/doctor.sh"
{ has 'never fetched'; }; check A9d "doctor on a repo WITH a remote that never fetched still says so" $?
# (e) `--` ends the option list
mk_proj pa9e remote
printf -- '- 🔴 `--odd.php` is sealed\n' >> "$INDEX"
run bash "$KITREL/kernel/rails-index.sh"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths -- --odd.php; strip
{ has 'WARN rails.*--odd.php' "$OUTT" && lacks 'unknown arg' "$OUTT"; }; check A9e "--paths -- --odd.php carries a path that starts with --" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch --paths src/x.php -- --odd.php; strip
{ has 'WARN rails.*--odd.php' "$OUTT"; }; check A9e "paths before and after the -- are both read" $?

###############################################################################
# 7 — doctor: agent file vs kernel (tokens, drift, placeholder), hook wiring,
#     rails outside list items, one index in two configs, register path from
#     the profile. Each check is run in both polarities.
###############################################################################
AGENT=claude-brain/agents/acme-pm.md
# a doctor with no conf did not run: exit 3 in both modes (it used to exit 0 or 1 after printing a FAIL)
mk_proj pd7z remote
run bash "$KITREL/doctor.sh" "$SB/no-such.conf"
{ [ "$RC" = 3 ] && has 'NOT RUN — conf not found'; }; check 7z "doctor with a missing conf did not run: exit 3 (rc=$RC)" $?
run bash "$KITREL/doctor.sh" "$SB/no-such.conf" --strict
{ [ "$RC" = 3 ]; }; check 7z "... and also under --strict (rc=$RC)" $?
mv claude-brain/pm-kit.conf "$SB/pm-kit.conf.away"
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'UNMEASURED memory.*doctor.sh did not run' "$OUTT" && lacks 'doctor.sh clean' "$OUTT"; }; check 7z "the pre-flight reports a doctor that did not run as UNMEASURED, not 'clean'" $?
mv "$SB/pm-kit.conf.away" claude-brain/pm-kit.conf
# (a) tokens <-> bindings rows
mk_proj pd7a remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has 'kernel tokens and bindings rows agree' && has 'kernel block identical to pm-kit/PROTOCOL.md' && has 'no paste placeholder'; }; check 7a "a freshly pasted agent file passes tokens, drift and placeholder (rc=$RC)" $?
grep -v '^| `${CATALOG_CMD}`' "$AGENT" > "$SB/agent.tmp" && cp "$SB/agent.tmp" "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 1 ] && has 'FAIL.*NO row in the bindings table.*CATALOG_CMD'; }; check 7a "a kernel token with no bindings row is a FAIL (rc=$RC)" $?
printf '| `${NOT_IN_KERNEL}` | stale |\n' >> "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh"
{ has 'WARN.*never uses.*NOT_IN_KERNEL'; }; check 7a "a bindings row for a token the kernel never uses is a WARN" $?
# (b) drift against PROTOCOL.md
mk_proj pd7b remote
sed 's/You advise; orchestrators build\./You advise; orchestrators build, often./' "$AGENT" > "$SB/agent.tmp" && cp "$SB/agent.tmp" "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh"
{ has 'WARN.*kernel drift'; }; check 7b "an edited kernel block is reported as kernel drift" $?
# (c) placeholder
mk_proj pd7c remote
cp "$C/skeleton/agent-example.md" "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 1 ] && has 'FAIL.*PASTE-KERNEL-HERE'; }; check 7c "an agent file still carrying PASTE-KERNEL-HERE is a FAIL (rc=$RC)" $?
# (d) hook wiring: info, never a failure
mk_proj pd7d remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has 'info — hooks not wired.*load-telemetry.sh.*session-ledger.sh.*pm-sync.sh' && lacks 'WARN.*hooks' && lacks 'FAIL.*hooks'; }; check 7d "no settings.json: hooks reported 'not wired' as info, strict still passes (rc=$RC)" $?
mkdir -p .claude; cp "$C/skeleton/settings.example.json" .claude/settings.json
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has 'ok   — hooks wired in settings: load-telemetry.sh session-ledger.sh pm-sync.sh pm-consult-nudge.sh'; }; check 7d "the shipped settings.example.json counts as fully wired (rc=$RC)" $?
printf '{"hooks":{"PostToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"x/load-telemetry.sh"}]}]}}\n' > .claude/settings.json
run bash "$KITREL/doctor.sh"
{ has 'info — hooks not wired.*session-ledger.sh.*pm-sync.sh' && lacks 'optional):[^;]*load-telemetry' && has 'wired: load-telemetry.sh'; }; check 7d "a partial wiring names only the missing hooks" $?
# (e) rails outside list items
mk_proj pd7e remote
printf '\n🔴 never edit `app/db.php` by hand\n\n> ⛔ `ref_users` is read by two views\n\n- ⛔ `app/ok.php` is sealed\n  🔴 continuation about `app/ok2.php` stays a rail\n' >> "$INDEX"
run bash "$KITREL/doctor.sh"
{ has 'WARN.*2 line(s) of the index look like rails.*not list items'; }; check 7e "a paragraph rail and a blockquote rail are found; the list item and its continuation are not (2)" $?
mk_proj pd7e2 remote
printf '\n- 🔴 `app/db.php` never edit by hand\n- ⛔ `ref_users` is read by two views\n\nplain prose about `app/db.php` with no severity marker\n' >> "$INDEX"
run bash "$KITREL/doctor.sh"
{ has 'no rail-like line outside list items'; }; check 7e "rails as list items, and prose without a marker, raise nothing" $?
if command -v mawk >/dev/null 2>&1; then
  mk_proj pd7e3 remote
  printf '\n🔴 never edit `app/db.php` by hand\n' >> "$INDEX"
  mkdir -p "$SB/awk7"; ln -sf "$(command -v mawk)" "$SB/awk7/awk"
  run env PATH="$SB/awk7:$PATH" bash "$KITREL/doctor.sh"
  { has 'WARN.*1 line(s) of the index look like rails'; }; check 7e "same finding under mawk" $?
else skip 7e "mawk not installed"; fi
# (f) PF_PM_INDEX vs PM_INDEX
mk_proj pd7f remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has 'PM_INDEX (pm-kit.conf) and PF_PM_INDEX (profile) name the same file'; }; check 7f "the shipped configs agree on the index (rc=$RC)" $?
prof_set PF_PM_INDEX '"claude-brain/agents/other-pm-memory.md"'
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 1 ] && has "FAIL.*PM_INDEX in pm-kit.conf is 'claude-brain/agents/acme-pm-memory.md' but PF_PM_INDEX.*other-pm-memory.md"; }; check 7f "two different index paths are a FAIL naming both (rc=$RC)" $?
# (g) the register is the profile's PF_ARB_FILE, not a hardcoded name
mk_proj pd7g remote
prof_set PF_ARB_FILE '"claude-brain/agents/acme-pm-memory/open-questions.md"'
mkdir -p "$MEMDIR/open-questions" "$MEMDIR/dev-handoff-register"
printf '### H-20260101-a-split · waiting\n' > "$MEMDIR/open-questions.md"
printf '### H-20260101-a-split · DONE\n' > "$MEMDIR/open-questions/b.md"
printf '### H-20260101-a-old · waiting\n' > "$MEMDIR/dev-handoff-register.md"
printf '### H-20260101-a-old · DONE\n' > "$MEMDIR/dev-handoff-register/b.md"
printf '\nregister: open-questions.md open-questions/b.md dev-handoff-register.md dev-handoff-register/b.md\n' >> "$INDEX"
run bash "$KITREL/doctor.sh"
{ has 'FAIL.*STATES DIVERGE' && has 'a-split' && lacks 'a-old'; }; check 7g "section 12 follows PF_ARB_FILE: the declared register is compared, the old hardcoded name is not" $?
prof_set PF_ARB_FILE '""'
run bash "$KITREL/doctor.sh"
{ has 'register router vs bodies: n/a' && lacks 'STATES DIVERGE'; }; check 7g "no PF_ARB_FILE: section 12 is n/a" $?

###############################################################################
# 10 — scripts, skeleton and profile carry no French and no origin-project noun
###############################################################################
cd "$C" || exit 64
SCAN="pm-kit/doctor.sh pm-kit/catalog.sh pm-kit/load-telemetry.sh pm-kit/lint-claims-session.sh pm-kit/kernel skeleton profiles pm-kit.conf.example .github tests/ports.sh"
# accented Latin letters (UTF-8 lead bytes C3 and C5), anywhere in a script or template
# shellcheck disable=SC2086
LC_ALL=C grep -rln "$(printf '\303')\|$(printf '\305')" $SCAN > "$SB/accents.txt" 2>/dev/null
[ ! -s "$SB/accents.txt" ]; arc=$?   # the verdict is taken BEFORE the description's command substitution: $? after it would be tr's
check 10 "no accented character in any script, skeleton file or profile ($(tr '\n' ' ' < "$SB/accents.txt"))" "$arc"
# shellcheck disable=SC2086
grep -rnE 'VPS|tailnet|tsk_|next-migration|00-audit|H-<date>|<k\|l>|\[kl\]|k\+l|HORS-|CLE-RESOLUTION|OUVERT|aucun|\(1826\)|error 1[0-9][0-9][0-9]' $SCAN > "$SB/nouns.txt" 2>/dev/null
[ ! -s "$SB/nouns.txt" ]; nrc=$?
check 10 "no origin-project noun (VPS, tailnet, tsk_, next-migration, 00-audit, [kl], k+l, HORS-, CLE-RESOLUTION, MySQL error numbers) in the scripts ($(head -1 "$SB/nouns.txt" | cut -c1-80))" "$nrc"
# the old closure words were English-only checks of French vocabulary; none may be hardcoded
# shellcheck disable=SC2086
grep -rnE 'CLOS\||RÉPONDU|CADUQUE|RESOLVED\|' pm-kit/doctor.sh pm-kit/kernel/pm-preflight.sh | grep -v 'PF_ARB_CLOSED_RE\|ARB_CLOSED_RE=' > "$SB/closure.txt" 2>/dev/null
{ [ ! -s "$SB/closure.txt" ]; }; check 10 "the closure vocabulary appears only as the PF_ARB_CLOSED_RE default" $?
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 11 — the example profile and the scripts agree about what is configurable
###############################################################################
cd "$C" || exit 64
run bash tests/conf-surface.sh
{ [ "$RC" = 0 ] && has 'conf-surface: OK'; }; check 11 "every variable in profiles/example.conf is read by a script, every name a script reads is documented (rc=$RC)" $?
cp profiles/example.conf "$SB/conf-unread.conf"; printf 'DOMAIN_RULER_billing="a"\nPF_BOGUS_UNREAD="x"\n' >> "$SB/conf-unread.conf"
run bash tests/conf-surface.sh --conf "$SB/conf-unread.conf"
{ [ "$RC" = 1 ] && has 'UNREAD DOMAIN_RULER_billing' && has 'UNREAD PF_BOGUS_UNREAD'; }; check 11 "a variable nothing reads (PF_ and DOMAIN_) fails the surface test (rc=$RC)" $?
cp profiles/example.conf "$SB/conf-agent.conf"
insert_after_marker() { awk -v add="$2" '{print} /--- agent-read: begin ---/{print add}' "$1"; }
insert_after_marker "$SB/conf-agent.conf" 'PF_FOR_THE_AGENT="read by the PM agent"' > "$SB/conf-agent2.conf"
run bash tests/conf-surface.sh --conf "$SB/conf-agent2.conf"
{ [ "$RC" = 0 ]; }; check 11 "a variable inside the agent-read block is exempt (rc=$RC)" $?
cp profiles/example.conf "$SB/conf-fam.conf"; printf 'DEV_c="Cy Dube|^Cy Dube$"\n' >> "$SB/conf-fam.conf"
run bash tests/conf-surface.sh --conf "$SB/conf-fam.conf"
{ [ "$RC" = 0 ]; }; check 11 "a DEV_<id> family member counts as read (expanded by prefix) (rc=$RC)" $?
rm -rf "$SB/kitcopy"; mkdir -p "$SB/kitcopy"; cp -R pm-kit skeleton "$SB/kitcopy/"; cp pm-kit.conf.example "$SB/kitcopy/"
printf ': "${NEW_THING:=${PF_NEW_THING:-}}"\n' >> "$SB/kitcopy/pm-kit/kernel/pm-preflight.sh"
run bash tests/conf-surface.sh --conf profiles/example.conf --kitconf pm-kit.conf.example --kit "$SB/kitcopy"
{ [ "$RC" = 1 ] && has 'UNDOCUMENTED PF_NEW_THING'; }; check 11 "a script reading a variable the profile never mentions fails the surface test (rc=$RC)" $?
cp pm-kit.conf.example "$SB/kitconf-unread.example"; printf 'PM_BOGUS_KNOB=1\n' >> "$SB/kitconf-unread.example"
run bash tests/conf-surface.sh --kitconf "$SB/kitconf-unread.example"
{ [ "$RC" = 1 ] && has 'UNREAD PM_BOGUS_KNOB.*pm-kit.conf'; }; check 11 "pm-kit.conf.example is held to the same rule: an unread PM_ variable fails (rc=$RC)" $?
rm -rf "$SB/kitcopy2"; mkdir -p "$SB/kitcopy2"; cp -R pm-kit skeleton "$SB/kitcopy2/"; cp pm-kit.conf.example "$SB/kitcopy2/"
printf ': "${PM_NEW_KNOB:-}"\n' >> "$SB/kitcopy2/pm-kit/catalog.sh"
run bash tests/conf-surface.sh --conf profiles/example.conf --kitconf pm-kit.conf.example --kit "$SB/kitcopy2"
{ [ "$RC" = 1 ] && has 'UNDOCUMENTED PM_NEW_KNOB.*pm-kit.conf'; }; check 11 "a script reading a pm-kit.conf variable the example never mentions fails (rc=$RC)" $?
run bash tests/conf-surface.sh --conf "$SB/no-such.conf"
{ [ "$RC" = 3 ]; }; check 11 "no profile: did not run, exit 3 (rc=$RC)" $?
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 12 — the seed index agrees with the kernel
###############################################################################
cd "$C" || exit 64
SEED=skeleton/index-seed.md
{ ! grep -qiE '^#+ .*(BUILD-STATE|RESUME|CHANGE-LOG|HEAD|NEXT-FREE|QUEUE STATE)' "$SEED" && ! grep -qE 'HEAD = <' "$SEED"; }; check 12 "the seed has no section for a moving quantity (build-state, resume point, change-log head, next-free)" $?
{ grep -qE '^- (⛔|🔴) `<surface>`' "$SEED" && ! grep -E '^(⛔|🔴)' "$SEED" | grep -q .; }; check 12 "the seed's rails are list items naming a surface in backticks" $?
mk_proj p12 remote
git fetch -q origin
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has '0 fail(s), 0 warning(s)'; }; check 12 "the seed index passes doctor --strict with zero warnings (rc=$RC)" $?
run bash "$KITREL/kernel/rails-index.sh"
{ lacks 'WARN —' && [ "$RC" != 2 ]; }; check 12 "the rails miner reads the seed without a self-check warning (rc=$RC)" $?
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ lacks 'STOP' "$OUTT" && has 'ok   memory .*doctor.sh clean' "$OUTT"; }; check 12 "the pre-flight reads the doctor as clean on the seed, no STOP (rc=$RC)" $?
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 13 / CI — the workflow names only suites that exist, and names every suite
###############################################################################
cd "$C" || exit 64
WF=.github/workflows/smoke.yml
missing=""
# shellcheck disable=SC2013  # file names here contain no whitespace
for f in $(grep -oE 'tests/[A-Za-z0-9_.-]+\.sh' "$WF" | sort -u); do [ -f "$f" ] || missing="$missing $f"; done
{ [ -z "$missing" ]; }; check 13 "every tests/*.sh the workflow names exists ($missing)" $?
unnamed=""; for f in tests/*.sh; do [ "$f" = tests/conf-surface.sh ] && continue; grep -q "$f" "$WF" || unnamed="$unnamed $f"; done
{ [ -z "$unnamed" ]; }; check 13 "every suite under tests/ is run by the workflow (conf-surface.sh is run by smoke.sh) ($unnamed)" $?
for j in smoke mawk; do
  n="$(awk -v j="$j" '/^  [a-z]+:$/{cur=$1} cur==j":" && /tests\/quickstart.sh/{c++} END{print c+0}' "$WF")"
  { [ "$n" -ge 1 ]; }; check 13 "workflow job '$j' runs tests/quickstart.sh" $?
done
# the quickstart test is not decoration: a README whose stated outcome or commands are wrong fails it
printf '%s\n' "$(sed 's/| the install block: nothing committed, no remote | 0 | 1 | 0 |/| the install block: nothing committed, no remote | 0 | 0 | 0 |/' README.md)" > "$SB/README.wrong-outcome"
run env QS_README="$SB/README.wrong-outcome" bash tests/quickstart.sh
{ [ "$RC" = 1 ] && has 'FAIL  pass 1: pre-flight exit as the README states'; }; check 13 "a README that states the wrong exit code fails tests/quickstart.sh (rc=$RC)" $?
printf '%s\n' "$(sed 's/--name acme --dev a/--name acme/' README.md)" > "$SB/README.wrong-command"
run env QS_README="$SB/README.wrong-command" bash tests/quickstart.sh
{ [ "$RC" = 1 ] && has 'FAIL'; }; check 13 "a README whose command block is broken fails tests/quickstart.sh (rc=$RC)" $?
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 16 — VERSION and CHANGELOG agree, and the changelog lists the behaviour changes
###############################################################################
cd "$C" || exit 64
V="$(tr -d ' \n' < VERSION)"
{ [ "$V" = 0.2.0 ]; }; check 16 "VERSION is 0.2.0 (got '$V')" $?
{ grep -q "^## \[$V\] - " CHANGELOG.md && ! grep -q '^## \[Unreleased\]' CHANGELOG.md; }; check 16 "CHANGELOG has a dated entry for the VERSION and no Unreleased section" $?
for w in 'Exit code 3 means' 'past `PF_ARB_STOP_DAYS` are an ambient WARN' 'does not push unless asked' 'ambient' 'Solo mode'; do
  grep -qF "$w" CHANGELOG.md; check 16 "CHANGELOG 'Behaviour changes' mentions: $w" $?
done
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 17 — kernel text: the exit-code sentence names 3, and every KERNEL-MIGRATION row still finds its string
###############################################################################
cd "$C" || exit 64
tr -s '\n ' '  ' < pm-kit/PROTOCOL.md > "$SB/protocol.flat"
grep -qF -- 'The exit code means: 0, nothing found; 1, warnings or unmeasured checks; 2, at least one STOP; 3, the pre-flight did not run and nothing was measured.' "$SB/protocol.flat"; check 17 "the kernel's exit-code sentence names unmeasured checks and exit 3" $?
lost=0; rows=0
sed -n 's/^| [0-9][0-9]* |.*| PROTOCOL\.md (kernel): "\(.*\)" |$/\1/p' pm-kit/KERNEL-MIGRATION.md > "$SB/mig.strings"
while IFS= read -r str; do rows=$((rows+1)); [ "$(grep -cF -- "$str" "$SB/protocol.flat")" -ge 1 ] || { lost=$((lost+1)); echo "  lost: $str"; }; done < "$SB/mig.strings"
{ [ "$lost" = 0 ] && [ "$rows" -ge 50 ]; }; check 17 "every KERNEL-MIGRATION row's string is found in the kernel ($rows rows, $lost lost)" $?
cd "$PROJ" 2>/dev/null || true

###############################################################################
# 7h — the session prefix bound in the agent file equals the profile's
###############################################################################
AGENT=claude-brain/agents/acme-pm.md
mk_proj pd7h remote
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has "SESSION_PREFIX} binding equals PF_SESSION_PREFIX ('acme-')"; }; check 7h "the shipped agent file and profile agree on the prefix (rc=$RC)" $?
prof_set PF_SESSION_PREFIX '"other-"'
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 1 ] && has "FAIL.*SESSION_PREFIX} is 'acme-' in .*PF_SESSION_PREFIX is 'other-'.*another session"; }; check 7h "a different prefix in the profile is a FAIL naming both values (rc=$RC)" $?
prof_set PF_SESSION_PREFIX '""'
sed 's/^| `${SESSION_PREFIX}` | .*$/| `${SESSION_PREFIX}` | empty (same value as `PF_SESSION_PREFIX`) |/' "$AGENT" > "$SB/agent.tmp" && cp "$SB/agent.tmp" "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has "binding equals PF_SESSION_PREFIX ('')"; }; check 7h "an empty prefix on both sides agrees (rc=$RC)" $?
sed 's/^| `${SESSION_PREFIX}` | .*$/| `${SESSION_PREFIX}` | the usual one |/' "$AGENT" > "$SB/agent.tmp" && cp "$SB/agent.tmp" "$AGENT"; cp "$AGENT" "$HOME/.claude/agents/acme-pm.md"
run bash "$KITREL/doctor.sh"
{ has 'WARN.*session prefix check (13) UNMEASURED'; }; check 7h "a binding with no readable value is UNMEASURED, never a pass" $?

###############################################################################
# leftovers — catalog --grep display cuts on a character boundary; the doctor
#             finds a kernel whose marker lines carry leading whitespace
###############################################################################
mk_proj plo remote
EACC="$(printf '\303\251')"; LONGE=""; for i in $(seq 1 450); do LONGE="$LONGE$EACC"; done
printf '# Accents\n\n> Trigger: %s needle\n' "$LONGE" > "$MEMDIR/accents.md"
if command -v iconv >/dev/null 2>&1; then
  mkdir -p "$SB/awkcg" "$SB/awkcm"
  command -v gawk >/dev/null 2>&1 && ln -sf "$(command -v gawk)" "$SB/awkcg/awk"
  command -v mawk >/dev/null 2>&1 && ln -sf "$(command -v mawk)" "$SB/awkcm/awk"
  for cfg in gawk-C mawk gawk-utf8; do
    case $cfg in
      gawk-C)    [ -x "$SB/awkcg/awk" ] || continue; run env PATH="$SB/awkcg:$PATH" LC_ALL=C bash "$KITREL/catalog.sh" --grep needle ;;
      mawk)      [ -x "$SB/awkcm/awk" ] || continue; run env PATH="$SB/awkcm:$PATH" bash "$KITREL/catalog.sh" --grep needle ;;
      gawk-utf8) [ -x "$SB/awkcg/awk" ] && [ -n "$UTF8_LOC" ] || continue; run env PATH="$SB/awkcg:$PATH" LC_ALL="$UTF8_LOC" bash "$KITREL/catalog.sh" --grep needle ;;
    esac
    iconv -f UTF-8 -t UTF-8 "$OUT" > /dev/null 2>&1; irc=$?
    { [ "$irc" = 0 ] && has 'accents.md' && has '…'; }; check leftover "catalog --grep display of a long multi-byte trigger is valid UTF-8 ($cfg, iconv rc=$irc)" $?
  done
else skip leftover "iconv not installed"; fi
rm -f "$MEMDIR/accents.md"
mk_proj pmk remote
sed -E 's/^<!-- cellarman kernel: (begin|end) -->$/    <!-- cellarman kernel: \1 -->/' claude-brain/agents/acme-pm.md > "$SB/agent.tmp"
{ grep -q '^    <!-- cellarman kernel: begin' "$SB/agent.tmp" && grep -q '^    <!-- cellarman kernel: end' "$SB/agent.tmp"; }; check leftover "fixture: both marker lines are indented" $?
cp "$SB/agent.tmp" claude-brain/agents/acme-pm.md; cp "$SB/agent.tmp" "$HOME/.claude/agents/acme-pm.md"
git fetch -q origin
run bash "$KITREL/doctor.sh" --strict
{ [ "$RC" = 0 ] && has 'agent file carries a kernel block' && has 'kernel tokens and bindings rows agree' && has 'kernel block identical to pm-kit/PROTOCOL.md' && lacks 'no kernel block'; }; check leftover "an agent file whose marker lines are indented still has its kernel found, checked and equal to PROTOCOL.md (rc=$RC)" $?

###############################################################################
###############################################################################
# Portability guards: two bash 3.2 (macOS) traps that no Linux run can show
###############################################################################
# bash 3.2 reads any byte >= 0x80 as part of a variable name, so "$VAR— text"
# is "unbound variable" under set -u. Braces are required before non-ASCII text.
cd "$C" || exit 64
HIB="$(LC_ALL=C grep -n -E '\$[A-Za-z_][A-Za-z0-9_]*[^ -~	]' pm-kit/*.sh pm-kit/kernel/*.sh skeleton/*.sh skeleton/hooks/*.sh 2>/dev/null | LC_ALL=C grep -v -E '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
{ [ -z "$HIB" ]; }; check portability "no unbraced \$VAR is followed by a non-ASCII byte (bash 3.2 reads it as part of the name) $HIB" $?
# In a UTF-8 locale a bash glob range follows the collation order: [a-z] also
# matches A-Y on macOS. init.sh validates the project name with explicit letters.
RNG="$(grep -n -E '^[[:space:]]*(\*)?\[!?a-z' pm-kit/init.sh || true)"
{ [ -z "$RNG" ]; }; check portability "init.sh validates names with explicit letters, not an [a-z] glob range $RNG" $?

printf '\nsmoke: %d passed, %d failed, %d skipped\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" = 0 ]; FINAL=$?
exit "$FINAL"
