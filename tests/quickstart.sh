#!/usr/bin/env bash
# tests/quickstart.sh — runs the README quickstart LITERALLY and asserts the
# outcome the README states.
#
# What is mechanical here: the command blocks are not copied into this file. They
# are extracted from README.md, the fenced ```bash block between each pair of
# markers
#     <!-- quickstart:install:begin -->  ...  <!-- quickstart:install:end -->
#     <!-- quickstart:publish:begin -->  ...  <!-- quickstart:publish:end -->
# and run as they stand, in an empty sandbox repository, with a throw-away HOME.
# The expected exit codes are read from the table between
#     <!-- quickstart:expect:begin -->  ...  <!-- quickstart:expect:end -->
# (one row whose first cell mentions "install", one that mentions "publish";
# columns rails-index, pre-flight, doctor; an empty cell asserts nothing).
# The only thing this test supplies is what the README tells the reader to fill
# in: the two lines `K=<kit checkout>` and `cd <repository>`.
#
# If the README's stated outcome is wrong, fix the README. This test is never
# loosened to match it.
#
# Pass 1: the repository has no remote.
# Pass 2: the repository has a bare remote called origin with nothing pushed yet
#         (the README's publish block is what pushes).
#
# Run:  bash tests/quickstart.sh
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
C="$(cd "$HERE/.." && pwd)"
README="${QS_README:-$C/README.md}"   # QS_README: a mutated copy, for the negative controls in tests/smoke.sh
SB="$(mktemp -d "${TMPDIR:-/tmp}/quickstart-sandbox.XXXXXX")" || { echo "cannot create sandbox" >&2; exit 3; }
SB="$(cd "$SB" && pwd)"
trap 'rm -rf "$SB"' EXIT

export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com
export GIT_CONFIG_NOSYSTEM=1
unset PM_DEV PM_PROFILE PM_REPO_ROOT ACME_DEV CLAUDE_CODE_SESSION_ID 2>/dev/null

NPASS=0; NFAIL=0
pass() { NPASS=$((NPASS+1)); echo "PASS  $1"; }
fail() { NFAIL=$((NFAIL+1)); echo "FAIL  $1${2:+ — $2}"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want '$2' got '$3'"; fi; }

# block <name> <file>: the fenced bash block between the name's two markers.
block() {
  awk -v b="<!-- quickstart:$1:begin -->" -v e="<!-- quickstart:$1:end -->" '
    $0 == b { inside = 1; next }
    $0 == e { inside = 0 }
    inside && /^```bash[[:space:]]*$/ { infence = 1; next }
    inside && /^```[[:space:]]*$/ { infence = 0; next }
    inside && infence { print }' "$README"
}
# expect <row word> <column 1..3>: a cell of the expectation table.
expect() {
  awk -F'|' -v word="$1" -v col="$2" '
    $0 == "<!-- quickstart:expect:begin -->" { inside = 1; next }
    $0 == "<!-- quickstart:expect:end -->"   { inside = 0 }
    inside && index($0, "|") == 1 && index($2, word) > 0 { c = $(col + 2); gsub(/[[:space:]]/, "", c); print c; exit }' "$README"
}

echo "== the README carries the blocks and the table =="
block install > "$SB/install.sh"; block publish > "$SB/publish.sh"
[ -s "$SB/install.sh" ]; check "install block extracted" 0 "$?"
[ -s "$SB/publish.sh" ]; check "publish block extracted" 0 "$?"
grep -q 'init.sh' "$SB/install.sh"; check "the install block runs init.sh" 0 "$?"
! grep -qE '<[a-z]+>|/path/to' "$SB/install.sh" "$SB/publish.sh"; check "the blocks hold no placeholder to fill in" 0 "$?"
EXP_RAILS="$(expect install 1)"; EXP_PF1="$(expect install 2)"; EXP_DOC="$(expect install 3)"; EXP_PF2="$(expect publish 2)"
# (the table's VALUES are the README's to state; here they only have to be readable numbers)
for v in "$EXP_RAILS" "$EXP_PF1" "$EXP_DOC" "$EXP_PF2"; do
  case "$v" in ''|*[!0-9]*) fail "the expectation table has a readable number in every cell this test uses" "got '$v'" ;; *) pass "table cell '$v' is a number" ;; esac
done

# mk <name> <remote|noremote>: an empty repository (and an empty HOME) for one pass.
mk() {
  R="$SB/$1"; H="$SB/$1.home"; mkdir -p "$R" "$H" "$SB/$1.tmp"
  git -C "$R" init -q -b main
  git -C "$R" config user.name "Test Dev"; git -C "$R" config user.email dev@example.com
  if [ "$2" = remote ]; then
    git init -q --bare -b main "$SB/$1.remote.git"; git -C "$R" remote add origin "$SB/$1.remote.git"
  fi
}
# exitline <log> <label>: the number after "<label> exit: "
exitline() { sed -n "s/^$2 exit: //p" "$1" | head -1; }

echo "== pass 1: empty repository, no remote =="
mk p1 noremote
cat "$SB/install.sh" > "$SB/run1.sh"
(cd "$R" && K="$C" HOME="$H" TMPDIR="$SB/p1.tmp" bash "$SB/run1.sh" > "$SB/out1" 2>&1); rc=$?
check "the install block itself ends cleanly" 0 "$rc"
check "pass 1: rails-index exit as the README states" "$EXP_RAILS" "$(exitline "$SB/out1" rails)"
check "pass 1: pre-flight exit as the README states" "$EXP_PF1" "$(exitline "$SB/out1" pre-flight)"
check "pass 1: doctor exit as the README states" "$EXP_DOC" "$(exitline "$SB/out1" doctor)"
grep -q 'single-clone mode' "$SB/p1.tmp/pf.log"; check "pass 1: the pre-flight log names the missing shared reference" 0 "$?"
grep -q 'uncommitted' "$SB/p1.tmp/pf.log"; check "pass 1: the pre-flight log names the uncommitted install" 0 "$?"
! grep -qE 'STOP|NOT RUN' "$SB/p1.tmp/pf.log"; check "pass 1: no STOP and nothing that did not run" 0 "$?"
grep -q '0 fail(s)' "$SB/p1.tmp/doctor.log"; check "pass 1: the doctor log says 0 fail(s)" 0 "$?"

echo "== pass 2: a remote that has nothing yet; the publish block pushes =="
mk p2 remote
cat "$SB/install.sh" "$SB/publish.sh" > "$SB/run2.sh"
(cd "$R" && K="$C" HOME="$H" TMPDIR="$SB/p2.tmp" bash "$SB/run2.sh" > "$SB/out2" 2>&1); rc=$?
check "the install and publish blocks end cleanly together" 0 "$rc"
check "pass 2: rails-index exit as the README states" "$EXP_RAILS" "$(exitline "$SB/out2" rails)"
check "pass 2: doctor exit as the README states" "$EXP_DOC" "$(exitline "$SB/out2" doctor)"
PFS="$(sed -n 's/^pre-flight exit: //p' "$SB/out2" | tr '\n' ' ')"
check "pass 2: the pre-flight exit after publishing, as the README states" "$EXP_PF2" "$(printf '%s' "$PFS" | awk '{print $NF}')"
check "pass 2: the working tree is clean after the publish block" "" "$(git -C "$R" status --porcelain)"
check "pass 2: the remote holds exactly HEAD" "$(git -C "$R" rev-parse HEAD)" "$(git --git-dir="$SB/p2.remote.git" rev-parse refs/heads/main)"
sed "s/$(printf '\033')\[[0-9;]*m//g" "$SB/p2.tmp/pf.log" | grep -q 'CLEAR'; check "pass 2: the final pre-flight log says CLEAR" 0 "$?"

echo "== the README's own words about the outcome are true =="
grep -q 'single-clone mode' "$README"; check "README names single-clone mode" 0 "$?"
grep -q 'Exit 3' "$README"; check "README explains exit 3" 0 "$?"

echo
echo "quickstart.sh: $NPASS passed, $NFAIL failed"
[ "$NFAIL" -eq 0 ]
