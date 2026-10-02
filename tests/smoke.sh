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
COMMON_TOOLS="bash sh env cmp find sort wc date head tail grep sed tr cut awk mktemp rm cat dirname basename readlink printf mv cp ls comm uniq stat touch git jq"
# ago_stamp <days>: touch -t stamp (YYYYMMDDhhmm) for N days ago, GNU or BSD date.
ago_stamp() { date -d "-$1 days" +%Y%m%d%H%M 2>/dev/null || date -v "-${1}d" +%Y%m%d%H%M; }
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
mk_toolpath "$SB/nofind" $(for t in $COMMON_TOOLS; do [ "$t" = find ] || printf '%s ' "$t"; done)
run env PATH="$SB/nofind" "$(command -v bash)" "$KITREL/doctor.sh"
{ has "check (6) UNMEASURED — required tool 'find'" && lacks 'no topic file over'; }; check B1 "a missing find is UNMEASURED, never 'ok — no topic file over' (rc=$RC)" $?
rm -rf "$MEMDIR/big-topic.md" "$MEMDIR/index-relocated-detail"

###############################################################################
# B2 — agent-copy drift by content compare, no md5sum on the machine
###############################################################################
mk_proj pb2 remote
mk_toolpath "$SB/nomd5" $COMMON_TOOLS
{ [ ! -e "$SB/nomd5/md5sum" ]; }; check B2 "fixture PATH really has no md5sum" $?
run env PATH="$SB/nomd5" "$(command -v bash)" "$KITREL/doctor.sh"
{ has 'agent definition copies in sync'; }; check B2 "identical agent copies read in sync without md5sum" $?
printf '\nlocally edited\n' >> "$HOME/.claude/agents/acme-pm.md"
run env PATH="$SB/nomd5" "$(command -v bash)" "$KITREL/doctor.sh"
{ has 'agent definition drift:' && lacks 'copies in sync'; }; check B2 "a differing installed copy is flagged without md5sum" $?
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
UTF8_LOC=""; for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do locale -a 2>/dev/null | grep -qx "$l" && { UTF8_LOC="$l"; break; }; done
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
  LEFT="$(ls "$SB/tmpd" | wc -l | tr -d ' ')"
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
  && has 'ok   mig-draft.*n/a (no queue declared)' "$OUTT" && has 'ok   mig-vps.*n/a (no queue declared)' "$OUTT" \
  && has 'ok   namespace.*n/a (no queue declared)' "$OUTT" && has 'ok   slug-drift.*n/a (no queue declared)' "$OUTT" \
  && lacks 'no migration on' "$OUTT" && lacks 'no unpushed migration' "$OUTT"; }; check A16 "empty PF_QUEUE_DIR: every queue phase says n/a and measures nothing" $?
mk_proj p16b remote
prof_set PF_TARGET_HOST '""'
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'ok   mig-vps.*n/a (no deploy target declared)' "$OUTT" && lacks 'WARN mig-vps' "$OUTT" && has 'ok   mig-upstream.*no migration on' "$OUTT"; }; check 1.6 "empty PF_TARGET_HOST: the target leg is n/a, the queue is still measured" $?
mk_proj p16c remote
run env ACME_DEV=a bash bin/pm-preflight.sh --no-fetch; strip
{ has 'WARN mig-vps.*UNMEASURED' "$OUTT"; }; check 1.6 "a declared target without --probe-db stays an honest WARN" $?

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
{ has 'arbitration.*H-20260101-a-old-question' "$OUTT" && lacks 'no open handoff items' "$OUTT"; }; check A1 "an item by dev 'a' (profile declares a/b) is seen" $?
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
printf '\nsmoke: %d passed, %d failed, %d skipped\n' "$N_PASS" "$N_FAIL" "$N_SKIP"
[ "$N_FAIL" = 0 ]; FINAL=$?
exit "$FINAL"
