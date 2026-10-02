#!/usr/bin/env bash
# lint-claims-session.sh — pre-commit gate for the claims file. Three duties,
# applied ONLY to lines the commit ADDS (a long history of older rows must
# never fail a commit that does not touch them).
#
#   (1) BLOCKING — an added row whose status is a LIVE state (default: open,
#       restated) and which has no 7th field (session), or an empty one, is
#       refused. claim.sh is the only writer meant to hold a live row; a row
#       typed by hand recreates the defect the session field exists to close.
#
#   (2) ADVISORY — an added row whose fields 1..4 (status, date, dev, slug)
#       match ANOTHER row anywhere in the staged file is a likely duplicate.
#       WARN, never a refusal: a same-day restate of a slug is legitimate.
#       The check exists because a union-merged file DUPLICATES instead of
#       conflicting, at merge AND at rebase, and a per-session 7th field makes
#       every duplicate-in-substance differ byte-for-byte, so a whole-line
#       `sort | uniq -d` stops seeing it. Keying on the 4 fields that identify
#       the LOGICAL row restores a mechanical detector.
#
#   (3) BLOCKING — an added row that is empty or whitespace-only is refused.
#       A blank row is the shape a half-written append leaves behind, and a
#       union merge carries it forward forever. Only emptiness is refused, not
#       an unexpected field count, so a future column needs no lint change.
#
# NEVER DEDUPLICATES. The file is append-only; nobody's row is removed by a
# lint. It names both colliding rows and a human decides.
#
# USAGE
#   lint-claims-session.sh                 pre-commit mode: reads the staged diff
#   lint-claims-session.sh --dupes         census of duplicates (fields 1..4) in
#                                          the WHOLE working-tree file; exit 0
#   lint-claims-session.sh --self-test     polarity control: each duty must flag
#                                          its bad fixture AND pass its good one
#   options:  --conf <profile>   --claims <repo-relative path>
#
# EXIT CODES   0 clean (warnings allowed) · 1 refused (or self-test failed) ·
#              3 did not run (no repository, no claims path, bad argument, no
#              temp dir): nothing was checked. 3 is the kit-wide code for
#              "did not run"; a hook must treat it as a failure, never a pass.
#
# PROFILE VARIABLES
#   PF_CLAIMS_FILE         claims file, repo-relative (or --claims)
#   PF_CLAIM_LIVE_STATES   space-separated states that require a session
#                          (default: "open restated")
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-claims-session.XXXXXX")" || { echo "lint-claims-session: cannot create a temp dir" >&2; exit 3; }

LIVE_STATES="open restated"

# ── duty (1): live row without a session ─────────────────────────────────────
# $1 = file of candidate rows. Prints offenders, exits 1 iff any.
_claims_check_missing_session() {
  awk -F'\t' -v live="$LIVE_STATES" '
    BEGIN { n = split(live, arr, " "); for (i = 1; i <= n; i++) isl[arr[i]] = 1 }
    $0 ~ /^#/ { next }
    NF < 4    { next }
    ($1 in isl) { if (NF < 7 || $7 == "") { print; bad = 1 } }
    END { exit (bad ? 1 : 0) }
  ' "$1"
}

# ── duty (3): blank rows ─────────────────────────────────────────────────────
# Prints the 1-based index of each blank row within the candidate file (the
# staged diff cannot give a file row number). Exits 1 iff any.
_claims_check_blank_lines() {
  awk '
    /^[[:space:]]*$/ { printf "added row %d: blank\n", FNR; bad = 1 }
    END { exit (bad ? 1 : 0) }
  ' "$1"
}

# ── duty (2): fields 1..4 duplicated against the WHOLE file ──────────────────
# $1 = full file, $2 = candidate (added) rows. One block per colliding key.
_claims_check_dupes_against() {
  awk -F'\t' '
    FILENAME == ARGV[1] {
      if ($0 !~ /^#/ && NF >= 4) {
        key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
        count[key]++
        if (count[key] <= 4) { lines[key SUBSEP count[key]] = $0 }
      }
      next
    }
    {
      if ($0 !~ /^#/ && NF >= 4) {
        key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
        if (count[key] > 1 && !(key in reported)) {
          reported[key] = 1
          print "DUPLICATE fields 1..4: status=" $1 " date=" $2 " dev=" $3 " slug=" $4
          for (i = 1; i <= count[key] && i <= 4; i++) print "  -> " lines[key SUBSEP i]
          bad = 1
        }
      }
    }
    END { exit (bad ? 1 : 0) }
  ' "$1" "$2"
}

# Whole-file census for --dupes.
_claims_scan_whole_file() {
  awk -F'\t' '
    $0 !~ /^#/ && NF >= 4 {
      key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
      count[key]++
      if (count[key] <= 5) { lines[key SUBSEP count[key]] = $0 }
    }
    END {
      n = 0
      for (k in count) {
        if (count[k] > 1) {
          n++
          split(k, parts, SUBSEP)
          print "DUPLICATE (" count[k] "x) status=" parts[1] " date=" parts[2] " dev=" parts[3] " slug=" parts[4]
          for (i = 1; i <= count[k] && i <= 5; i++) print "  -> " substr(lines[k SUBSEP i], 1, 220)
        }
      }
      print n " duplicate group(s) on fields 1..4"
    }
  ' "$1"
}

# Added rows of a unified diff (read on stdin), without the '+' marker. Only
# lines inside a hunk count, so the '+++ b/path' header is skipped by position
# and a row whose own text starts with '++' is not lost.
_added_rows_from_diff() {
  awk '
    /^@@/ { inhunk = 1; next }
    inhunk && /^\+/ { print substr($0, 2) }
  '
}

# ── --self-test ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  bad_n=0
  T="$TMP/selftest"; mkdir -p "$T"
  TAB="$(printf '\t')"
  row() { printf '%s\t%s\t%s\t%s\tsurf\tintent\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

  # duty 1
  { row open 2026-01-01 a one ""; printf 'open\t2026-01-01\ta\tsix\tsurf\tintent\n'; } > "$T/d1-bad"
  # (the first line has an EMPTY 7th field, the second has only 6 fields)
  row open 2026-01-01 a one sess-1 > "$T/d1-good"
  printf 'closed\t2026-01-01\ta\tone\tsurf\tintent\n' > "$T/d1-closed"
  row restated 2026-01-01 a one "" > "$T/d1-restated-bad"
  printf '# a comment line\n' > "$T/d1-comment"

  # duty 3
  printf 'open\t2026-01-01\ta\tone\ts\ti\tsess-1\n\n' > "$T/d3-bad"
  printf 'open\t2026-01-01\ta\tone\ts\ti\tsess-1\n' > "$T/d3-good"
  printf 'open\t2026-01-01\ta\tone\ts\ti\tsess-1\n%s%s\n' "$TAB" "$TAB" > "$T/d3-tabs-bad"

  # duty 2
  { row open 2026-01-01 a one sess-1; row open 2026-01-01 a one sess-2; } > "$T/d2-full-bad"
  row open 2026-01-01 a one sess-2 > "$T/d2-added-bad"
  { row open 2026-01-01 a one sess-1; row open 2026-01-01 a two sess-2; } > "$T/d2-full-good"
  row open 2026-01-01 a two sess-2 > "$T/d2-added-good"

  # diff extraction: header skipped, a '++'-leading row kept
  printf '%s\n' 'diff --git a/c.tsv b/c.tsv' '--- a/c.tsv' '+++ b/c.tsv' '@@ -1,0 +2,2 @@' \
    '+open	2026-01-01	a	x	s	i	sess-1' '++odd' > "$T/diff"
  _added_rows_from_diff < "$T/diff" > "$T/diff-rows"
  nrows="$(wc -l < "$T/diff-rows" | tr -d ' ')"

  labels=(); want=(); got=()
  add() { labels+=("$1"); want+=("$2"); got+=("$3"); }
  chk() { "$@" > /dev/null 2>&1; echo $?; }

  add "duty1 live row, empty 7th field + 6-field row (refuse)"  1 "$(chk _claims_check_missing_session "$T/d1-bad")"
  add "duty1 live row with a session (accept)"                  0 "$(chk _claims_check_missing_session "$T/d1-good")"
  add "duty1 closed row without session (tolerated)"            0 "$(chk _claims_check_missing_session "$T/d1-closed")"
  add "duty1 restated row, empty session (refuse)"              1 "$(chk _claims_check_missing_session "$T/d1-restated-bad")"
  add "duty1 comment line (skipped)"                            0 "$(chk _claims_check_missing_session "$T/d1-comment")"
  add "duty3 blank row (refuse)"                                1 "$(chk _claims_check_blank_lines "$T/d3-bad")"
  add "duty3 normal row (accept)"                               0 "$(chk _claims_check_blank_lines "$T/d3-good")"
  add "duty3 whitespace-only row of TABs (refuse)"              1 "$(chk _claims_check_blank_lines "$T/d3-tabs-bad")"
  add "duty2 same fields 1..4, other session (warn)"            1 "$(chk _claims_check_dupes_against "$T/d2-full-bad" "$T/d2-added-bad")"
  add "duty2 different slug (clean)"                            0 "$(chk _claims_check_dupes_against "$T/d2-full-good" "$T/d2-added-good")"
  add "diff extraction keeps '++' row, drops header (2 rows)"   2 "$nrows"

  i=0
  while [ "$i" -lt "${#labels[@]}" ]; do
    if [ "${got[$i]}" = "${want[$i]}" ]; then
      printf '  %-58s want=%s got=%s OK\n' "${labels[$i]}" "${want[$i]}" "${got[$i]}"
    else
      printf '  %-58s want=%s got=%s ** FAIL **\n' "${labels[$i]}" "${want[$i]}" "${got[$i]}"
      bad_n=$((bad_n + 1))
    fi
    i=$((i + 1))
  done
  if [ "$bad_n" -eq 0 ]; then
    echo "lint-claims-session --self-test: OK"
    exit 0
  fi
  echo "lint-claims-session --self-test: ${bad_n} FAILURE(S)"
  exit 1
fi

# ── resolve repo, profile, claims path ───────────────────────────────────────
# shellcheck disable=SC1091
. "$KIT_DIR/kernel/profile-lib.sh" || exit 3

CONF_ARG=""; CLAIMS_REL=""; MODE="gate"
while [ $# -gt 0 ]; do
  case "$1" in
    --dupes)  MODE="dupes"; shift ;;
    --conf)   [ $# -ge 2 ] || { echo "lint-claims-session: --conf needs a value" >&2; exit 3; }; CONF_ARG="$2"; shift 2 ;;
    --claims) [ $# -ge 2 ] || { echo "lint-claims-session: --claims needs a value" >&2; exit 3; }; CLAIMS_REL="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | grep -E '^#( |$)' | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "lint-claims-session: unknown argument '$1'" >&2; exit 3 ;;
  esac
done

if ! pm_repo_root; then
  echo "lint-claims-session: NOT MEASURED — not inside a git repository and PM_REPO_ROOT is not set" >&2
  exit 3
fi

if [ -n "$CONF_ARG" ] && [ ! -f "$CONF_ARG" ]; then
  echo "lint-claims-session: NOT MEASURED — --conf '$CONF_ARG' does not exist" >&2
  exit 3
fi
if pm_find_profile "$CONF_ARG"; then
  # shellcheck disable=SC1090
  . "$CONF" || { echo "lint-claims-session: NOT MEASURED — cannot source $CONF" >&2; exit 3; }
  [ -n "$CLAIMS_REL" ] || CLAIMS_REL="${PF_CLAIMS_FILE:-}"
  LIVE_STATES="${PF_CLAIM_LIVE_STATES:-$LIVE_STATES}"
fi
if [ -z "$CLAIMS_REL" ]; then
  echo "lint-claims-session: NOT MEASURED — no claims path (set PF_CLAIMS_FILE in the profile, or pass --claims)" >&2
  exit 3
fi
CLAIMS_REL="${CLAIMS_REL#"$REPO_ROOT"/}"
CLAIMS_ABS="$REPO_ROOT/$CLAIMS_REL"

if [ "$MODE" = "dupes" ]; then
  if [ ! -f "$CLAIMS_ABS" ]; then
    echo "lint-claims-session --dupes: $CLAIMS_REL not found" >&2
    exit 0
  fi
  echo "lint-claims-session --dupes: whole-file scan of $CLAIMS_REL (fields 1..4 = status/date/dev/slug)"
  _claims_scan_whole_file "$CLAIMS_ABS"
  exit 0
fi

# ── gate: the staged diff ────────────────────────────────────────────────────
diff_out="$(git -C "$REPO_ROOT" diff --cached --no-color --no-ext-diff -U0 -- "$CLAIMS_REL" 2>/dev/null)"
if [ -z "$diff_out" ]; then
  echo "lint-claims-session: nothing to check (no staged change to $CLAIMS_REL)"
  exit 0
fi

added="$TMP/added"
printf '%s\n' "$diff_out" | _added_rows_from_diff > "$added"
if [ ! -s "$added" ]; then
  echo "lint-claims-session: staged change to $CLAIMS_REL adds no rows (deletion/context only) — nothing to check"
  exit 0
fi

fail=0

miss_out="$(_claims_check_missing_session "$added")"
miss_rc=$?
if [ "$miss_rc" -ne 0 ]; then
  fail=1
  echo
  echo "lint-claims-session: REFUSED — added live row(s) without a 7th field (session):"
  printf '%s\n' "$miss_out" | sed 's/^/  /'
  echo "  A live row without a session recreates the defect that field exists to close."
  echo "  TO DO: post the row with kernel/claim.sh, never by hand."
fi

blank_out="$(_claims_check_blank_lines "$added")"
blank_rc=$?
if [ "$blank_rc" -ne 0 ]; then
  fail=1
  echo
  echo "lint-claims-session: REFUSED — blank row(s) added to $CLAIMS_REL:"
  printf '%s\n' "$blank_out" | sed 's/^/  /'
  echo "  A blank row is not a claim, and a union merge will carry it forever."
  echo "  TO DO: remove it from the staged diff; claim.sh never produces one."
fi

full_staged="$TMP/full-staged"
if git -C "$REPO_ROOT" show ":${CLAIMS_REL}" > "$full_staged" 2>/dev/null; then
  dupe_out="$(_claims_check_dupes_against "$full_staged" "$added")"
  dupe_rc=$?
  if [ "$dupe_rc" -ne 0 ]; then
    echo
    echo "lint-claims-session: WARNING (not blocking) — fields 1..4 duplicated by the added row(s):"
    printf '%s\n' "$dupe_out" | sed 's/^/  /'
    echo "  A union merge does not conflict: two rows agreeing on status/date/dev/slug are one logical row."
    echo "  Not a refusal (a same-day restate, or open+closed the same day, are legitimate) — check by eye."
  fi
else
  echo "lint-claims-session: WARNING — cannot read the staged content of $CLAIMS_REL; duplicate check SKIPPED" >&2
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "lint-claims-session: OK"
exit 0
