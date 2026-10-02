#!/usr/bin/env bash
# tests/ports.sh — behavioural checks for pm-sync, session-ledger, claim.sh and
# the claims gate. Every case builds a throw-away git repo with a bare remote
# under $TMPDIR (set TMPDIR to choose where). Exit codes are captured outside
# pipes. PASS/FAIL per case; exits non-zero when any case fails.
#
# Run:  bash tests/ports.sh
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/ports-sandbox.XXXXXX")" || { echo "cannot create sandbox" >&2; exit 2; }
trap 'rm -rf "$SB"' EXIT

NPASS=0; NFAIL=0; NSKIP=0
pass() { NPASS=$((NPASS + 1)); echo "PASS  $1"; }
fail() { NFAIL=$((NFAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
skip() { NSKIP=$((NSKIP + 1)); echo "SKIP  $1${2:+ — $2}"; }
# check <name> <want> <got>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2' got '$3'"; fi; }
# contains <name> <file> <fixed string>
contains() { if grep -Fq -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "'$3' not in $2"; fi; }
lacks() { if grep -Fq -- "$3" "$2" 2>/dev/null; then fail "$1" "'$3' unexpectedly in $2"; else pass "$1"; fi; }

# ── sandbox builder ──────────────────────────────────────────────────────────
# mkproj <name> [noremote]: repo at $SB/<name> with the kit installed under
# claude-brain/, memory dir + index committed, upstream tracking a bare remote.
mkproj() {
  local name="$1" mode="${2:-}" p="$SB/p-$1"
  mkdir -p "$p"
  git -C "$p" init -q -b main
  git -C "$p" config user.name "Test Dev"
  git -C "$p" config user.email "dev@example.com"
  mkdir -p "$p/claude-brain/agents/test-pm-memory" "$p/claude-brain/pm-kit/profiles" "$p/src"
  cp -R "$ROOT/pm-kit/." "$p/claude-brain/pm-kit/"
  cp "$ROOT/skeleton/pm-sync.example.sh" "$p/claude-brain/pm-sync.sh"
  cp "$ROOT/skeleton/CLAIMS.tsv.example" "$p/claude-brain/CLAIMS.tsv"
  cat > "$p/claude-brain/pm-kit.conf" <<'EOF'
PM_INDEX="$REPO_ROOT/claude-brain/agents/test-pm.md"
PM_MEMORY_DIR="$REPO_ROOT/claude-brain/agents/test-pm-memory"
EOF
  cat > "$p/claude-brain/pm-kit/profiles/test.conf" <<'EOF'
DEVS="a b"
DEV_ENV_VAR="T_DEV"
PF_SESSION_ENV_VAR="T_SESSION"
PF_SESSION_PREFIX="sess-"
PF_CLAIMS_FILE="claude-brain/CLAIMS.tsv"
EOF
  printf '# index\n' > "$p/claude-brain/agents/test-pm.md"
  printf '# journal\n' > "$p/claude-brain/agents/test-pm-memory/journal.md"
  printf 'x\n' > "$p/src/code.txt"
  git -C "$p" add -A
  git -C "$p" commit -q -m "initial"
  if [ "$mode" != "noremote" ]; then
    git init -q --bare -b main "$SB/$name-remote.git"
    git -C "$p" remote add origin "$SB/$name-remote.git"
    git -C "$p" push -q -u origin main
  fi
  echo "$p"
}

remote_head() { git --git-dir="$SB/$1-remote.git" rev-parse refs/heads/main; }

# ledger <proj> <session> <repo-relative path>: record a write like the hook does
ledger() {
  printf '{"session_id":"%s","tool_input":{"file_path":"%s/%s"}}' "$2" "$1" "$3" \
    | (cd "$1" && bash claude-brain/pm-kit/kernel/session-ledger.sh)
}
# sync <proj> <session|-> [args...]: run pm-sync as that session; "-" = no stdin.
# Output lands in $SB/out and $SB/err; rc in SYNC_RC.
sync_run() {
  local p="$1" s="$2"; shift 2
  if [ "$s" = "-" ]; then
    (cd "$p" && PM_SYNC_NO_DOCTOR=1 bash claude-brain/pm-sync.sh "$@" < /dev/null) > "$SB/out" 2> "$SB/err"
  else
    (cd "$p" && printf '{"session_id":"%s"}' "$s" | PM_SYNC_NO_DOCTOR=1 bash claude-brain/pm-sync.sh "$@") > "$SB/out" 2> "$SB/err"
  fi
  SYNC_RC=$?
}
nlog() { git -C "$1" rev-list --count HEAD; }

echo "== syntax =="
for f in skeleton/pm-sync.example.sh skeleton/githooks-pre-commit.example pm-kit/kernel/session-ledger.sh \
         pm-kit/kernel/claim.sh pm-kit/kernel/profile-lib.sh pm-kit/lint-claims-session.sh tests/ports.sh; do
  bash -n "$ROOT/$f" > "$SB/syn" 2>&1; rc=$?
  check "bash -n $f" 0 "$rc"
done
if command -v shellcheck > /dev/null 2>&1; then
  shellcheck -S error "$ROOT/skeleton/pm-sync.example.sh" "$ROOT/pm-kit/kernel/session-ledger.sh" \
    "$ROOT/pm-kit/kernel/claim.sh" "$ROOT/pm-kit/lint-claims-session.sh" > "$SB/sc" 2>&1; rc=$?
  check "shellcheck (errors only) on the new scripts" 0 "$rc"
else
  skip "shellcheck" "not installed"
fi

echo "== pm-sync =="
# (i) unrelated unpushed code commit + memory edit => memory commit, push refused
P="$(mkproj i)"; before="$(remote_head i)"
echo "wip" >> "$P/src/code.txt"; git -C "$P" commit -q -am "WIP do not push"
echo "note" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
n0="$(nlog "$P")"; sync_run "$P" s1
check "(i) rc 0" 0 "$SYNC_RC"
check "(i) memory commit made" "$((n0 + 1))" "$(nlog "$P")"
contains "(i) PUSH REFUSED said on stderr" "$SB/err" "PUSH REFUSED"
check "(i) remote unchanged" "$before" "$(remote_head i)"
check "(i) the code commit was not pushed" "no" "$(git --git-dir="$SB/i-remote.git" log --format=%s refs/heads/main | grep -q 'WIP do not push' && echo yes || echo no)"

# (i-b) same shape, clean branch => pushed
P="$(mkproj ib)"; before="$(remote_head ib)"
echo "note" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
sync_run "$P" s1
check "(i-b) rc 0" 0 "$SYNC_RC"
check "(i-b) memory-only branch IS pushed" "$(git -C "$P" rev-parse HEAD)" "$(remote_head ib)"

# (ii) only a new untracked topic file
P="$(mkproj ii)"
echo "# new arc" > "$P/claude-brain/agents/test-pm-memory/new-arc.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/new-arc.md
n0="$(nlog "$P")"; sync_run "$P" s1
check "(ii) untracked topic file committed" "$((n0 + 1))" "$(nlog "$P")"
check "(ii) file is tracked in HEAD" "claude-brain/agents/test-pm-memory/new-arc.md" "$(git -C "$P" ls-tree --name-only -r HEAD | grep new-arc)"

# (iii) non-memory path staged => steps aside
P="$(mkproj iii)"
echo "note" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
echo "change" >> "$P/src/code.txt"; git -C "$P" add src/code.txt
n0="$(nlog "$P")"; sync_run "$P" s1
check "(iii) rc 0" 0 "$SYNC_RC"
check "(iii) nothing committed" "$n0" "$(nlog "$P")"
contains "(iii) says a sequence is in flight" "$SB/out" "in flight"
check "(iii) memory edit still uncommitted" " M claude-brain/agents/test-pm-memory/journal.md" "$(git -C "$P" status --porcelain claude-brain/agents)"

# (iv) no remote => local commit, rc 0
P="$(mkproj iv noremote)"
echo "note" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
n0="$(nlog "$P")"; sync_run "$P" s1
check "(iv) rc 0" 0 "$SYNC_RC"
check "(iv) committed locally" "$((n0 + 1))" "$(nlog "$P")"
contains "(iv) push skipped, said so" "$SB/out" "push skipped"

# (v) a file written by another session
P="$(mkproj v)"
echo "theirs" > "$P/claude-brain/agents/test-pm-memory/theirs.md"
ledger "$P" other claude-brain/agents/test-pm-memory/theirs.md
n0="$(nlog "$P")"; sync_run "$P" s1
check "(v) another session's file NOT committed" "$n0" "$(nlog "$P")"
contains "(v) the orphan is named" "$SB/out" "theirs.md"
sync_run "$P" - ; check "(v) no stdin: nothing committed" "$n0" "$(nlog "$P")"
contains "(v) no stdin: says so and names --all" "$SB/out" "--all"
sync_run "$P" s1 --all
check "(v) --all commits it" "$((n0 + 1))" "$(nlog "$P")"

# message override, and the mkdir lock (the macOS path)
P="$(mkproj msg)"
echo "n" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
(cd "$P" && printf '{"session_id":"s1"}' | PM_SYNC_MSG="docs(pm): custom why" PM_SYNC_NO_DOCTOR=1 bash claude-brain/pm-sync.sh) > "$SB/out" 2> "$SB/err"
check "PM_SYNC_MSG overrides the commit message" "docs(pm): custom why" "$(git -C "$P" log -1 --format=%s)"

P="$(mkproj lk)"
echo "n" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
mkdir "$P/.git/pm-sync.lock.d"; printf '%s\n' "$$" > "$P/.git/pm-sync.lock.d/pid"
n0="$(nlog "$P")"
(cd "$P" && printf '{"session_id":"s1"}' | PM_SYNC_NO_FLOCK=1 PM_SYNC_NO_DOCTOR=1 bash claude-brain/pm-sync.sh) > "$SB/out" 2> "$SB/err"
check "mkdir lock held by a live pid: steps aside" "$n0" "$(nlog "$P")"
contains "mkdir lock: says the lock is held" "$SB/out" "lock held"
sleep 0 & deadpid=$!; wait "$deadpid" 2>/dev/null
printf '%s\n' "$deadpid" > "$P/.git/pm-sync.lock.d/pid"
(cd "$P" && printf '{"session_id":"s1"}' | PM_SYNC_NO_FLOCK=1 PM_SYNC_NO_DOCTOR=1 bash claude-brain/pm-sync.sh) > "$SB/out" 2> "$SB/err"
check "mkdir lock owned by a dead pid: reclaimed, commit made" "$((n0 + 1))" "$(nlog "$P")"
check "mkdir lock released on exit" "no" "$([ -d "$P/.git/pm-sync.lock.d" ] && echo yes || echo no)"

if command -v flock > /dev/null 2>&1; then
  P="$(mkproj fl)"
  echo "n" >> "$P/claude-brain/agents/test-pm-memory/journal.md"
  ledger "$P" s1 claude-brain/agents/test-pm-memory/journal.md
  n0="$(nlog "$P")"
  ( exec 8> "$P/.git/pm-sync.lock"; flock -n 8; sleep 4 ) &
  holder=$!; sleep 1
  sync_run "$P" s1
  check "flock held elsewhere: steps aside" "$n0" "$(nlog "$P")"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
else
  skip "flock-held case" "flock not installed (the mkdir path above is what runs here)"
fi

echo "== session-ledger =="
P="$(mkproj led)"
ledger "$P" sL claude-brain/agents/test-pm-memory/journal.md
ledger "$P" sL claude-brain/agents/test-pm-memory/journal.md
ledger "$P" sL src/code.txt
check "ledger: de-duplicated, memory-only" "claude-brain/agents/test-pm-memory/journal.md" "$(cat "$P/.git/pm-ledger/sL.paths")"
ln -s "$P" "$SB/led-link"
printf '{"session_id":"sL","tool_input":{"file_path":"%s/claude-brain/agents/test-pm.md"}}' "$SB/led-link" | (cd "$P" && bash claude-brain/pm-kit/kernel/session-ledger.sh)
check "ledger: a path reached through a symlink resolves to the repo path" "2" "$(grep -c . "$P/.git/pm-ledger/sL.paths")"
printf '{"session_id":"../evil","tool_input":{"file_path":"%s/claude-brain/agents/test-pm.md"}}' "$P" | (cd "$P" && bash claude-brain/pm-kit/kernel/session-ledger.sh)
check "ledger: a session id with path characters is ignored" "no" "$([ -e "$P/.git/evil.paths" ] && echo yes || echo no)"

echo "== claim.sh =="
CLAIM() { # CLAIM <proj> <args...>   (env: T_DEV, T_SESSION as set by the caller)
  local p="$1"; shift
  (cd "$p" && bash claude-brain/pm-kit/kernel/claim.sh "$@") > "$SB/cout" 2> "$SB/cerr"
  CRC=$?
}
P="$(mkproj cl)"; CF="$P/claude-brain/CLAIMS.tsv"; base="$(grep -vc '^#' "$CF")"
export T_DEV=a T_SESSION=abcdef1234567890
CLAIM "$P" open demo-slug --surfaces "src/x/* table:t" --intent "build x"
check "claim open: rc 0" 0 "$CRC"
row="$(grep -v '^#' "$CF" | tail -n 1)"
check "claim open: 7 fields" 7 "$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
check "claim open: session field = prefix + first 8 chars" "sess-abcdef12" "$(printf '%s' "$row" | cut -f7)"
check "claim open: status/dev/slug" "open|a|demo-slug" "$(printf '%s' "$row" | awk -F'\t' '{print $1 "|" $3 "|" $4}')"
check "claim open: committed" "chore(claims): open demo-slug" "$(git -C "$P" log -1 --format=%s | sed 's/ — .*//')"
CLAIM "$P" restate demo-slug --intent "build x, wider"
check "claim restate: rc 0" 0 "$CRC"
check "claim restate: status restated, 7 fields" "restated|7" "$(grep -v '^#' "$CF" | tail -n 1 | awk -F'\t' '{print $1 "|" NF}')"
CLAIM "$P" close demo-slug
check "claim close: rc 0" 0 "$CRC"
check "claim close: status closed, 7 fields" "closed|7" "$(grep -v '^#' "$CF" | tail -n 1 | awk -F'\t' '{print $1 "|" NF}')"
check "claim round trip appended exactly 3 rows" "$((base + 3))" "$(grep -vc '^#' "$CF")"
check "claim: default is NOT pushed (opt-in)" "no" "$([ "$(git -C "$P" rev-parse HEAD)" = "$(remote_head cl)" ] && echo yes || echo no)"
contains "claim: says push is opt-in" "$SB/cout" "opt-in"

tab="$(printf '\t')"
CLAIM "$P" open tabbed --surfaces "a${tab}b" --intent "has${tab}a tab"
check "claim: TAB in intent/surfaces keeps 7 fields" 7 "$(grep -v '^#' "$CF" | tail -n 1 | awk -F'\t' '{print NF}')"
contains "claim: sanitising is announced on stderr" "$SB/cerr" "TAB/newline replaced"

sum0="$(cksum < "$CF")"; n0="$(nlog "$P")"
CLAIM "$P" open dry --intent "nope" --dry-run
check "claim --dry-run: rc 0" 0 "$CRC"
check "claim --dry-run: file untouched" "$sum0" "$(cksum < "$CF")"
check "claim --dry-run: nothing committed" "$n0" "$(nlog "$P")"
contains "claim --dry-run: prints the composed row" "$SB/cout" "dry"

( unset T_DEV; CLAIM "$P" open nodev --intent x; echo "$CRC" > "$SB/rc"; cp "$SB/cerr" "$SB/cerr-nodev" )
check "claim: missing dev env var => refusal rc 2" 2 "$(cat "$SB/rc")"
contains "claim: refusal names the profile's dev variable" "$SB/cerr-nodev" 'T_DEV'
check "claim: refusal wrote nothing" "$sum0" "$(cksum < "$CF")"
( unset T_SESSION; CLAIM "$P" open nosess --intent x; echo "$CRC" > "$SB/rc" )
check "claim: open without a session => refusal rc 2" 2 "$(cat "$SB/rc")"
( unset T_SESSION; CLAIM "$P" close demo-slug; echo "$CRC" > "$SB/rc"; cp "$SB/cerr" "$SB/cerr-nosess" )
check "claim: close without a session is tolerated" 0 "$(cat "$SB/rc")"
contains "claim: ...but says field 7 is empty" "$SB/cerr-nosess" "EMPTY"
check "claim: that closed row has an empty field 7" "" "$(grep -v '^#' "$CF" | tail -n 1 | cut -f7)"
( export T_DEV=zz; CLAIM "$P" open stranger --intent x; echo "$CRC" > "$SB/rc" )
check "claim: dev not in the profile's DEVS => refusal rc 2" 2 "$(cat "$SB/rc")"
CLAIM "$P" open "bad slug" --intent x
check "claim: slug with a space => refusal rc 2" 2 "$CRC"
CLAIM "$P" open
check "claim: missing slug => usage rc 2" 2 "$CRC"

# no trailing newline in the claims file must not glue rows together
P="$(mkproj nl)"; CF="$P/claude-brain/CLAIMS.tsv"
printf 'closed\t2026-01-01\ta\told\ts\ti\tsess-1' >> "$CF"; git -C "$P" commit -q -am "no trailing newline"
CLAIM "$P" open fresh --intent x
check "claim: file without trailing newline: two distinct rows" "2" "$(grep -v '^#' "$CF" | grep -c .)"

# opt-in push, and the guard
P="$(mkproj push1)"; before="$(remote_head push1)"
CLAIM "$P" open pushed --intent x --push
check "claim --push on a clean branch: rc 0" 0 "$CRC"
check "claim --push: remote advanced to HEAD" "$(git -C "$P" rev-parse HEAD)" "$(remote_head push1)"
P="$(mkproj push2)"; before="$(remote_head push2)"
echo "wip" >> "$P/src/code.txt"; git -C "$P" commit -q -am "unrelated unpushed work"
CLAIM "$P" open pushed --intent x --push
check "claim --push with other work ahead: refused (rc 1)" 1 "$CRC"
contains "claim --push refusal says so on stderr" "$SB/cerr" "PUSH REFUSED"
check "claim --push refusal: remote unchanged" "$before" "$(remote_head push2)"
P="$(mkproj push3 noremote)"
CLAIM "$P" open local --intent x --push
check "claim --push with no remote: rc 0, skipped" 0 "$CRC"
contains "claim --push with no remote: says so" "$SB/cout" "push skipped"

# the session field is what ownership-lint derives for "mine"
P="$(mkproj ol)"
cp "$ROOT/skeleton/OWNERSHIP.map.example" "$P/claude-brain/OWNERSHIP.map"
cat >> "$P/claude-brain/pm-kit/profiles/test.conf" <<'EOF'
PF_OWNERSHIP_MAP="claude-brain/OWNERSHIP.map"
PF_CONCERNS="logic schema style nav access fiscal environment-constant"
EOF
CLAIM "$P" open billing --surfaces "src/billing/*" --intent x
( cd "$P" && T_DEV=a T_SESSION=abcdef1234567890 PM_PROFILE=test bash claude-brain/pm-kit/kernel/ownership-lint.sh src/billing/invoice.php ) > "$SB/ol-same" 2>&1
lacks "ownership-lint recognises the claim as mine (same session)" "$SB/ol-same" "ANOTHER SESSION"
( cd "$P" && T_DEV=a T_SESSION=ffffffff00000000 PM_PROFILE=test bash claude-brain/pm-kit/kernel/ownership-lint.sh src/billing/invoice.php ) > "$SB/ol-other" 2>&1
contains "ownership-lint flags the same claim from another session of the same dev" "$SB/ol-other" "ANOTHER SESSION"

echo "== claims gate =="
bash "$ROOT/pm-kit/lint-claims-session.sh" --self-test > "$SB/st" 2>&1; rc=$?
check "lint --self-test passes" 0 "$rc"
contains "lint --self-test exercises both polarities" "$SB/st" "(refuse)"
contains "lint --self-test exercises both polarities (accept)" "$SB/st" "(accept)"

# the example hook, in a sandbox with core.hooksPath set
P="$(mkproj hk)"
mkdir -p "$P/.githooks"; cp "$ROOT/skeleton/githooks-pre-commit.example" "$P/.githooks/pre-commit"; chmod +x "$P/.githooks/pre-commit"
git -C "$P" config core.hooksPath .githooks
CF="$P/claude-brain/CLAIMS.tsv"
printf 'open\t2026-09-01\ta\thand\tsrc/x\ttyped by hand\n' >> "$CF"   # 6 fields
git -C "$P" add claude-brain/CLAIMS.tsv
(cd "$P" && git commit -q -m "hand-written 6-field open row") > "$SB/hk" 2>&1; rc=$?
check "hook refuses a hand-written 6-field open row" 1 "$rc"
contains "hook output names the missing session" "$SB/hk" "without a 7th field"
git -C "$P" reset -q HEAD claude-brain/CLAIMS.tsv; git -C "$P" checkout -q -- claude-brain/CLAIMS.tsv

printf 'open\t2026-09-01\ta\tok\tsrc/x\tproper\tsess-abcdef12\n' >> "$CF"
git -C "$P" add claude-brain/CLAIMS.tsv
(cd "$P" && git commit -q -m "7-field row") > "$SB/hk" 2>&1; rc=$?
check "hook accepts a 7-field open row" 0 "$rc"

printf '\n' >> "$CF"; git -C "$P" add claude-brain/CLAIMS.tsv
(cd "$P" && git commit -q -m "blank row") > "$SB/hk" 2>&1; rc=$?
check "hook refuses a blank row" 1 "$rc"
git -C "$P" reset -q HEAD claude-brain/CLAIMS.tsv; git -C "$P" checkout -q -- claude-brain/CLAIMS.tsv

printf 'open\t2026-09-01\ta\tok\tsrc/y\tdup of fields 1..4\tsess-99999999\n' >> "$CF"
git -C "$P" add claude-brain/CLAIMS.tsv
(cd "$P" && git commit -q -m "duplicate fields 1..4") > "$SB/hk" 2>&1; rc=$?
check "hook only WARNS on duplicate fields 1..4 (commit goes through)" 0 "$rc"
contains "hook prints the duplicate warning" "$SB/hk" "WARNING"
check "gate never dedupes: both rows are still in the file" 2 "$(grep -c "$(printf 'open\t2026-09-01\ta\tok\t')" "$CF")"
( cd "$P" && bash claude-brain/pm-kit/lint-claims-session.sh --dupes ) > "$SB/dp" 2>&1; rc=$?
check "lint --dupes exits 0" 0 "$rc"
contains "lint --dupes reports the group" "$SB/dp" "1 duplicate group"

# a non-claims commit is untouched by the gate
echo "more" >> "$P/src/code.txt"; git -C "$P" add src/code.txt
(cd "$P" && git commit -q -m "unrelated change") > "$SB/hk" 2>&1; rc=$?
check "hook lets an unrelated commit through" 0 "$rc"

# unresolved config must be 'not measured', never a pass
mkdir -p "$SB/bare"; git -C "$SB/bare" init -q
(cd "$SB/bare" && bash "$ROOT/pm-kit/lint-claims-session.sh") > "$SB/nc" 2>&1; rc=$?
check "lint with no claims path configured: rc 2 (not measured)" 2 "$rc"
contains "lint says NOT MEASURED" "$SB/nc" "NOT MEASURED"

echo
echo "ports.sh: $NPASS passed, $NFAIL failed, $NSKIP skipped"
[ "$NFAIL" -eq 0 ]
