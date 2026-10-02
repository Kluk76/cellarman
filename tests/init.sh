#!/usr/bin/env bash
# tests/init.sh — pm-kit/init.sh: dry run, idempotence, refusal, validation, and
# that what it installs is healthy. Every case builds a throw-away repository and
# a throw-away HOME under $TMPDIR. Exit codes are captured outside pipes.
#
# Run:  bash tests/init.sh
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
C="$(cd "$HERE/.." && pwd)"
INIT="$C/pm-kit/init.sh"
SB="$(mktemp -d "${TMPDIR:-/tmp}/init-sandbox.XXXXXX")" || { echo "cannot create sandbox" >&2; exit 3; }
SB="$(cd "$SB" && pwd)"
trap 'rm -rf "$SB"' EXIT

# Offline by default (PM_OFFLINE=1), with a recording fake ssh/scp/curl/wget/nc
# first on PATH: a suite that reaches for the network fails at its last assertion.
# A case that deliberately exercises a remote leg (against a local bare repo or a
# stubbed target) unsets the switch itself and says so in its name.
NETLOG="$SB/net-calls.log"; : > "$NETLOG"; FAKENET="$SB/fakenet"; mkdir -p "$FAKENET"
for _t in ssh scp curl wget nc; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 255\n' "$_t" "$NETLOG" > "$FAKENET/$_t"; chmod +x "$FAKENET/$_t"
done
export PM_OFFLINE=1; PATH="$FAKENET:$PATH"

export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com
export GIT_CONFIG_NOSYSTEM=1
unset PM_DEV PM_PROFILE PM_REPO_ROOT ACME_DEV ZETA_CO_DEV CLAUDE_CODE_SESSION_ID 2>/dev/null

NPASS=0; NFAIL=0
pass() { NPASS=$((NPASS+1)); echo "PASS  $1"; }
fail() { NFAIL=$((NFAIL+1)); echo "FAIL  $1${2:+ — $2}"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2' got '$3'"; fi; }
ok() { if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; fi; }   # ok <name> <rc of a condition>
LOGN=0
# run <env HOME dir> <cmd...>: output in $OUT, rc in $RC
run() { LOGN=$((LOGN+1)); OUT="$SB/log.$LOGN"; "$@" > "$OUT" 2>&1; RC=$?; }
has()   { grep -q -- "$1" "$OUT"; }
lacks() { ! grep -q -- "$1" "$OUT"; }
# mkrepo <name>: an empty git repository (no remote) and an empty HOME next to it
mkrepo() {
  R="$SB/$1"; H="$SB/$1.home"; mkdir -p "$R" "$H"
  git -C "$R" init -q -b main
  git -C "$R" config user.name "Test Dev"; git -C "$R" config user.email dev@example.com
}
init() { (cd "$R" && HOME="$H" bash "$INIT" "$@"); }
treesum() { (cd "$1" && find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r f; do printf '%s ' "$f"; cksum < "$f"; done | cksum); }

echo "== syntax =="
bash -n "$INIT" > "$SB/syn" 2>&1; check "bash -n pm-kit/init.sh" 0 "$?"

echo "== dry run =="
mkrepo dry
run init --name acme --dev a --dry-run
check "dry run exits 0" 0 "$RC"
ok "dry run says it writes nothing and lists the plan" "$(has 'nothing will be written' && has 'create .*claude-brain/agents/acme-pm.md' && echo 0 || echo 1)"
check "dry run left the repository empty" "" "$(cd "$R" && find . -path ./.git -prune -o -type f -print | head -1)"
check "dry run left HOME empty" "" "$(find "$H" -type f | head -1)"

echo "== install =="
mkrepo inst
run init --name acme --dev a
check "install exits 0" 0 "$RC"
for f in claude-brain/pm-kit/doctor.sh claude-brain/pm-kit/profiles/acme.conf claude-brain/pm-kit.conf claude-brain/agents/acme-pm.md \
         claude-brain/agents/acme-pm-memory.md claude-brain/agents/acme-pm-memory/shipped-arcs-register.md \
         claude-brain/agents/acme-pm-memory/dev-handoff-register.md claude-brain/CLAIMS.tsv claude-brain/OWNERSHIP.map \
         claude-brain/pm-sync.sh bin/pm-preflight.sh docs/PLAN.md .claude/settings.json .claude/hooks/pm-consult-nudge.sh \
         .gitattributes .gitignore CLAUDE.md; do
  [ -f "$R/$f" ]; ok "created $f" "$?"
done
[ -f "$H/.claude/agents/acme-pm.md" ]; ok "installed the agent file under HOME/.claude/agents" "$?"
[ -x "$R/bin/pm-preflight.sh" ] && [ -x "$R/claude-brain/pm-kit/kernel/pm-preflight.sh" ] && [ -x "$R/claude-brain/pm-sync.sh" ] && [ -x "$R/.claude/hooks/pm-consult-nudge.sh" ]; ok "launcher, kernel, sync and hook scripts are executable" "$?"
grep -q '^DEVS="a"' "$R/claude-brain/pm-kit/profiles/acme.conf" && grep -q '^DEV_ENV_VAR="ACME_DEV"' "$R/claude-brain/pm-kit/profiles/acme.conf" && grep -q '^PF_SESSION_PREFIX="acme-"' "$R/claude-brain/pm-kit/profiles/acme.conf"; ok "profile: DEVS, developer variable and session prefix are set" "$?"
grep -q '^PF_QUEUE_DIR=""' "$R/claude-brain/pm-kit/profiles/acme.conf" && grep -q '^PF_TARGET_HOST=""' "$R/claude-brain/pm-kit/profiles/acme.conf"; ok "profile: no fictional queue or deploy host is declared" "$?"
grep -q '^own   a  \*  \*' "$R/claude-brain/OWNERSHIP.map" && ! grep -q 'tax-seal' "$R/claude-brain/OWNERSHIP.map"; ok "ownership map: a solo catch-all, none of the template's fictional lanes" "$?"
grep -q 'PASTE-KERNEL-HERE' "$R/claude-brain/agents/acme-pm.md"; check "agent file: the kernel is pasted (no placeholder)" 1 "$?"
cmp -s "$R/claude-brain/agents/acme-pm.md" "$H/.claude/agents/acme-pm.md"; ok "installed agent file equals the repository copy" "$?"
grep -q '^## Project manager' "$R/CLAUDE.md" && ! grep -q '<!--' "$R/CLAUDE.md"; ok "CLAUDE.md: the consultation rule is appended without the template comment" "$?"

echo "== second run is a no-op =="
before="$(treesum "$R")"
run init --name acme --dev a
check "second run exits 0" 0 "$RC"
ok "second run reports unchanged, creates nothing" "$(has 'done (0 file(s) created)' && lacks 'create ' && echo 0 || echo 1)"
check "second run changed no byte" "$before" "$(treesum "$R")"
check "CLAUDE.md carries the rule once" 1 "$(grep -c '^## Project manager' "$R/CLAUDE.md")"
check ".gitignore carries the block once" 1 "$(grep -c 'claude-brain/agents/.pm-load-log.tsv' "$R/.gitignore")"

echo "== never overwrites =="
echo "# my edit" >> "$R/claude-brain/pm-kit.conf"
rm -f "$R/docs/PLAN.md"
mine="$(cksum < "$R/claude-brain/pm-kit.conf")"
run init --name acme --dev a
check "a differing existing file: refused, exit 2" 2 "$RC"
ok "the refusal names the file and says nothing was written" "$(has 'REFUSED' && has 'claude-brain/pm-kit.conf' && has 'nothing was written' && echo 0 || echo 1)"
check "the edited file is intact" "$mine" "$(cksum < "$R/claude-brain/pm-kit.conf")"
[ ! -e "$R/docs/PLAN.md" ]; ok "a refused run created nothing else (the deleted docs/PLAN.md is still absent)" "$?"
mkrepo agent
mkdir -p "$H/.claude/agents"; echo "someone else's agent" > "$H/.claude/agents/acme-pm.md"
run init --name acme --dev a
check "a differing installed agent file: refused, exit 2" 2 "$RC"
ok "... and the repository was left empty" "$([ -z "$(cd "$R" && find . -path ./.git -prune -o -type f -print | head -1)" ] && echo 0 || echo 1)"
mkrepo noagent
run init --name acme --dev a --no-agent-install
check "--no-agent-install exits 0" 0 "$RC"
check "--no-agent-install leaves HOME empty" "" "$(find "$H" -type f | head -1)"

echo "== an existing CLAUDE.md, .gitignore and .gitattributes are appended to, not replaced =="
mkrepo app
printf '# My project\n\nExisting rules.\n' > "$R/CLAUDE.md"; printf 'node_modules/\n' > "$R/.gitignore"; printf '*.png binary' > "$R/.gitattributes"
run init --name acme --dev a
check "exit 0" 0 "$RC"
ok "CLAUDE.md keeps its text and gains the rule" "$(grep -q '^Existing rules\.' "$R/CLAUDE.md" && grep -q '^## Project manager' "$R/CLAUDE.md" && echo 0 || echo 1)"
ok ".gitignore keeps its line and gains the block" "$(grep -qx 'node_modules/' "$R/.gitignore" && grep -q 'claude-brain/agents/.pm-load-log.tsv' "$R/.gitignore" && echo 0 || echo 1)"
ok ".gitattributes (no trailing newline) keeps its line and gains merge=union on its own line" "$(grep -qx '\*.png binary' "$R/.gitattributes" && grep -q 'claude-brain/CLAIMS.tsv *merge=union' "$R/.gitattributes" && echo 0 || echo 1)"

echo "== validation (exit 3: did not run) =="
mkrepo val
run init --dev a;                          check "no --name" 3 "$RC"
run init --name acme;                      check "no --dev" 3 "$RC"
run init --name Acme --dev a;              check "uppercase name" 3 "$RC"
run init --name 9acme --dev a;             check "name starting with a digit" 3 "$RC"
run init --name 'a b' --dev a;             check "name with a space" 3 "$RC"
run init --name acme --dev 'A!';           check "bad developer initial" 3 "$RC"
run init --name acme --dev a --bogus;      check "unknown argument" 3 "$RC"
mkdir -p "$SB/notgit"; run bash -c "cd '$SB/notgit' && HOME='$H' bash '$INIT' --name acme --dev a"
check "not a git work tree" 3 "$RC"
ok "... and it says so" "$(has 'NOT RUN' && has 'not a git work tree' && echo 0 || echo 1)"
check "nothing written on a validation failure" "" "$(cd "$R" && find . -path ./.git -prune -o -type f -print | head -1)"

echo "== another project name and developer =="
mkrepo zeta
run init --name zeta-co --dev q
check "exit 0" 0 "$RC"
[ -f "$R/claude-brain/agents/zeta-co-pm.md" ] && [ -f "$R/claude-brain/agents/zeta-co-pm-memory.md" ] && [ -f "$R/claude-brain/pm-kit/profiles/zeta-co.conf" ]; ok "files are named after the project" "$?"
grep -q '^DEV_ENV_VAR="ZETA_CO_DEV"' "$R/claude-brain/pm-kit/profiles/zeta-co.conf" && grep -q '^PF_SESSION_PREFIX="zeta-co-"' "$R/claude-brain/pm-kit/profiles/zeta-co.conf"; ok "developer variable ZETA_CO_DEV and session prefix zeta-co-" "$?"
grep -rli 'acme' "$R" --exclude-dir=.git --exclude=LESSONS.md --exclude=KERNEL-MIGRATION.md --exclude=PROTOCOL.md --exclude=init.sh > "$SB/acme-left" 2>/dev/null
check "no 'acme' left in the generated files (outside the kit's own docs)" "" "$(cat "$SB/acme-left")"

echo "== what it installs is healthy =="
mkrepo health
run init --name acme --dev a
(cd "$R" && git add -A && git commit -q -m install)
git init -q --bare "$SB/health.remote.git"; git -C "$R" remote add origin "$SB/health.remote.git"; git -C "$R" push -q -u origin main
(cd "$R" && HOME="$H" bash claude-brain/pm-kit/kernel/rails-index.sh > "$SB/rails.log" 2>&1); check "rails-index on the seed: exit 0" 0 "$?"
(cd "$R" && HOME="$H" bash claude-brain/pm-kit/doctor.sh --strict > "$SB/doctor.log" 2>&1); check "doctor --strict: exit 0" 0 "$?"
(cd "$R" && env -u PM_OFFLINE HOME="$H" ACME_DEV=a bash bin/pm-preflight.sh > "$SB/pf.log" 2>&1); rc=$?
check "pre-flight on the committed, pushed install: exit 0 (CLEAR) [PM_OFFLINE unset: fetches the local remote]" 0 "$rc"
(cd "$R" && env -u PM_OFFLINE HOME="$H" ACME_DEV=a bash bin/pm-preflight.sh --paths src/new.php > "$SB/pf2.log" 2>&1); rc=$?
check "pre-flight with --paths for a new file in the solo lane: exit 0 [PM_OFFLINE unset]" 0 "$rc"

check "no test reached for the network (fake ssh/scp/curl/wget/nc never called)" "" "$(cat "$NETLOG")"
echo
echo "init.sh: $NPASS passed, $NFAIL failed"
[ "$NFAIL" -eq 0 ]
