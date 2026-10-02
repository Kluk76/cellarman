#!/usr/bin/env bash
# ownership-lint.sh — map touched paths to lanes, and to any live CLAIM.
#
# Two inputs, two different questions:
#   OWNERSHIP.map  — the DURABLE boundary: who owns this lane, at what concern.
#   CLAIMS.tsv     — the VOLATILE hold: who is building here RIGHT NOW.
# The map answers "am I allowed here?"; the claims file answers "is somebody
# already there?". A system with only the first re-ships features; a system with
# only the second re-litigates the boundary every week.
#
# The map is keyed on CONCERN, not on file, deliberately: a per-file map blocks
# a correct, ratified cross-concern change, and a map overridden once gets
# ignored forever. So the lane is (owner x concern x glob), and cross-concern
# work has an explicit RATIFIED escape that is RECORDED rather than refused.
#
# Portable kernel: carries no project nouns. Team identities, the shared
# reference, and the ownership/claims file locations all come from a profile
# (see profiles/*.conf) — same discovery order as pm-preflight.sh.
#
# bash 3.2 compatible (macOS). No associative arrays, no mapfile, no grep -P.
#
# A path can match SEVERAL lanes at once, at different concerns — that is the
# whole point of the concern axis (kernel K4). Every matching lane is reported;
# the acting dev is blocked only by a lane someone ELSE owns at a concern that
# isn't the universal `*` catch-all. A cross-concern block has a receipt escape:
# the RATIFIED token turns the block into a RECORDED note that names every lane
# crossed and the owner who must smoke-test it. A frozen lane is the one wall
# ratification cannot open.
#   Sources, in order: --ratified flag, $RATIFIED, then the last commit message.
#   A receipt read from a COMMIT covers ONLY the files of that commit (see
#   `is_ratified_for`): an ambient receipt used to outlive its build and switch
#   the guard off for every later one. An explicit receipt (--ratified or
#   $RATIFIED) covers the invocation. So BEFORE committing, a lane crossing is
#   declared with `--ratified`; the commit message stays the audit trail
#   AFTERWARDS.
#   Never read a verdict from the exit code alone: look for an `own lane` or
#   `SHARED lane` line. A bare `RECORDED:` is a block dressed up as a permission.
#
# EXIT
#   0  every path is in the acting dev's own lane and unclaimed by anyone else
#      (also: no paths were given, so there was nothing to judge)
#   1  JUDGED, with something to name: at least one path is in a shared,
#      contested or unmapped lane; or a cross-concern write was RATIFIED (see
#      RECORDED: lines); or a claim is stale, of unknown session, or the claims
#      file is absent. The printed lines say which. Never read the verdict from
#      the code alone.
#   2  JUDGED, a STOP: at least one path is in a frozen lane, or in another
#      dev's lane at a concern that dev does not own and no ratification was
#      found, or under a live claim held by the other dev or another session of
#      the same dev
#   3  DID NOT RUN, nothing was judged: no profile, a bad argument, no ownership
#      map, or the acting dev unknown (the dev variable is unset and --dev was
#      not given). Printed on stderr even with --quiet. 0, 1 and 2 are verdicts;
#      any other code means there is none.
#
# USAGE
#   ownership-lint.sh [--map F] [--claims F] [--dev <id>] [--ratified TEXT] [--claim-exempt "P1 P2"] [--quiet] [--refresh] PATH...
#   ownership-lint.sh --refresh            # regenerate the EVIDENCE column from git
#   RATIFIED="RATIFIED: <who>, <when>" ownership-lint.sh PATH...
#   git diff --name-only | xargs ownership-lint.sh

# Started by another shell (zsh, sh)? These scripts use bash-only expansions
# (e.g. ${VAR:+-flag "$VAR"} word-splitting) — re-exec under bash, never degrade.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=""

if [ -n "${PM_REPO_ROOT:-}" ]; then
  REPO_ROOT="$PM_REPO_ROOT"
elif REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO_ROOT" ]; then
  :
else
  REPO_ROOT="$(cd "$KIT_DIR/../../.." && pwd)"
  echo "ownership-lint: WARNING no \$PM_REPO_ROOT and cwd is not inside a git repo — falling back to the kernel's grandparent-of-grandparent ($REPO_ROOT)." >&2
fi

DEV=""
QUIET=0
REFRESH=0
PATHS=()    # an ARRAY: a path may contain spaces (a string list split "my file.php" in two)
RATIFIED_FLAG=""
CLAIM_EXEMPT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --conf)    [ $# -ge 2 ] && [ -n "$2" ] || { echo "ownership-lint: --conf needs a value" >&2; exit 3; }; CONF="$2"; shift 2 ;;
    --map)     [ $# -ge 2 ] && [ -n "$2" ] || { echo "ownership-lint: --map needs a value" >&2; exit 3; }; MAP="$2"; shift 2 ;;
    --claims)  [ $# -ge 2 ] && [ -n "$2" ] || { echo "ownership-lint: --claims needs a value" >&2; exit 3; }; CLAIMS="$2"; shift 2 ;;
    --dev)     [ $# -ge 2 ] && [ -n "$2" ] || { echo "ownership-lint: --dev needs a value" >&2; exit 3; }; DEV="$2"; shift 2 ;;
    --ratified) [ $# -ge 2 ] && [ -n "$2" ] || { echo "ownership-lint: --ratified needs a value" >&2; exit 3; }; RATIFIED_FLAG="$2"; shift 2 ;;
    --claim-exempt) [ $# -ge 2 ] || { echo "ownership-lint: --claim-exempt needs a value" >&2; exit 3; }; CLAIM_EXEMPT="$2"; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{print;next} {exit}' "$0"; exit 0 ;;
    -*)        echo "ownership-lint: unknown flag $1" >&2; exit 3 ;;
    *)         PATHS[${#PATHS[@]}]="$1"; shift ;;
  esac
done

# ── profile discovery (identical order to pm-preflight.sh) ────────────────────
if [ -z "$CONF" ] && [ -n "${PM_PROFILE:-}" ]; then
  if [ -f "$PM_PROFILE" ]; then
    CONF="$PM_PROFILE"
  elif [ -f "$REPO_ROOT/claude-brain/pm-kit/profiles/$PM_PROFILE.conf" ]; then
    CONF="$REPO_ROOT/claude-brain/pm-kit/profiles/$PM_PROFILE.conf"
  fi
fi
if [ -z "$CONF" ] && [ -d "$REPO_ROOT/claude-brain/pm-kit/profiles" ]; then
  N=$(find "$REPO_ROOT/claude-brain/pm-kit/profiles" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && CONF=$(find "$REPO_ROOT/claude-brain/pm-kit/profiles" -maxdepth 1 -name '*.conf')
fi
if [ -z "$CONF" ]; then
  N=$(find "$KIT_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')
  [ "$N" = 1 ] && CONF=$(find "$KIT_DIR" -maxdepth 1 -name '*.conf')
fi

if [ -n "$CONF" ] && [ ! -f "$CONF" ]; then
  echo "ownership-lint: NOT RUN — --conf '$CONF' does not exist (a profile named explicitly is never replaced by discovery)." >&2
  exit 3
fi
if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "ownership-lint: NOT RUN — no profile found (--conf, \$PM_PROFILE, a single claude-brain/pm-kit/profiles/*.conf, or a single kernel/*.conf). This kernel carries no team/lane vocabulary of its own." >&2
  exit 3
fi

# shellcheck disable=SC1090
. "$CONF"

: "${MAP:=${PF_OWNERSHIP_MAP:-}}"
: "${CLAIMS:=${PF_CLAIMS_FILE:-}}"
: "${SINCE:=${PF_OWNERSHIP_SINCE:-}}"
: "${UPSTREAM:=${PF_REF_NAME:-}}"
: "${DEV_ENV_VAR:=PM_DEV}"
# A claim carries a dev INITIAL, which names a CORRIDOR — never a session.
# Several agent sessions of the SAME dev can hold one shared clone at once, so
# the initial is NECESSARY but never SUFFICIENT to conclude "this claim is
# mine". SESSION_ENV_VAR names the env var holding the session id; the first 8
# hex chars of it, behind SESSION_PREFIX, form the claim's 7th field.
: "${SESSION_ENV_VAR:=${PF_SESSION_ENV_VAR:-CLAUDE_CODE_SESSION_ID}}"
: "${SESSION_PREFIX:=${PF_SESSION_PREFIX:-}}"
# Days after which a still-live claim is flagged for closing or restating
# (PF_CLAIM_STALE_DAYS; the profile documented it, the code hardcoded 3).
: "${STALE_DAYS:=${PF_CLAIM_STALE_DAYS:-3}}"
case "$STALE_DAYS" in ''|*[!0-9]*) STALE_DAYS=3 ;; esac
: "${RATIFY_TOKEN:=${PF_RATIFY_TOKEN:-RATIFIED:}}"
: "${RATIFY_ACTION:=${PF_RATIFY_ACTION:-RECORD}}"
# Lanes whose pattern starts with this prefix name a DATA surface, not a path,
# and must be attributed by CONTENT rather than by pathspec — see --refresh.
: "${DATA_LANE_PREFIX:=${PF_DATA_LANE_PREFIX:-table:}}"
# Paths whose diffs are searched when attributing a data lane. Empty = whole
# repo (correct but slower); narrowing it is a speed choice, so a profile that
# narrows it too far under-counts silently — keep it wider than you think.
: "${CONTENT_PATHS:=${PF_OWNERSHIP_CONTENT_PATHS:-}}"
case "$MAP" in ""|/*) ;; *) MAP="$REPO_ROOT/$MAP" ;; esac
case "$CLAIMS" in ""|/*) ;; *) CLAIMS="$REPO_ROOT/$CLAIMS" ;; esac

if [ -z "$DEV" ]; then
  eval "DEV=\"\${${DEV_ENV_VAR}:-}\""
fi

# Unknown session stays EMPTY on purpose: the rule below treats empty as the
# LOUD case. Never default it to something that could match a claim.
CUR_SESSION=""
eval "_SESS_RAW=\"\${${SESSION_ENV_VAR}:-}\""
[ -n "$_SESS_RAW" ] && CUR_SESSION="${SESSION_PREFIX}${_SESS_RAW:0:8}"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# A claim's session field has ONE canonical form: SESSION_PREFIX followed by the
# first 8 characters of the session id (what claim.sh writes). Anything else is
# either a hand-typed rendering of the SAME id (the full id, or the 8 characters
# without the prefix), which is recognised as mine, or a malformed field, which is
# rejected by name rather than silently read as "another session".
_session_field_wellformed() {
  local f="$1" r
  case "$f" in "$SESSION_PREFIX"*) r="${f#"$SESSION_PREFIX"}" ;; *) return 1 ;; esac
  [ ${#r} -eq 8 ]
}
_session_field_is_mine() {
  local f="$1" r
  [ -n "${_SESS_RAW:-}" ] || return 1
  case "$f" in "$SESSION_PREFIX"*) r="${f#"$SESSION_PREFIX"}" ;; *) r="$f" ;; esac
  [ ${#r} -ge 8 ] || return 1
  case "$_SESS_RAW" in "$r"*) return 0 ;; esac
  return 1
}

# ── --refresh : keep the map HONEST by regenerating its evidence from git ──────
# A hand-written ownership map rots into aspiration. This does not rewrite the
# LANES (that is a human ruling); it recomputes, per lane, who has actually
# touched it since $SINCE, so a lane whose evidence contradicts its owner is
# visible at a glance and can be argued about with numbers.
if [ "$REFRESH" = 1 ]; then
  if [ -z "${DEVS:-}" ] || [ -z "$UPSTREAM" ]; then
    echo "ownership-lint: --refresh needs the profile to define DEVS and PF_REF_NAME — UNMEASURED" >&2
    exit 3
  fi
  cd "$REPO_ROOT" || exit 3
  printf '# ownership evidence — regenerated %s, commits since %s on %s\n' \
         "$(date -u '+%Y-%m-%d')" "$SINCE" "$UPSTREAM"
  HDR="# lane	declared"
  for D in $DEVS; do HDR="$HDR	${D}_commits"; done
  printf '%s\tverdict\n' "$HDR"
  grep -v '^#' "$MAP" 2>/dev/null | grep -v '^[[:space:]]*$' | while read -r MODE OWNER _CONCERN GLOB REST; do
    [ -z "${GLOB:-}" ] && continue

    # A lane naming a DATA surface is not a path, and a pathspec cannot see it:
    # `git log -- 'table:x'` matches no file BY CONSTRUCTION, so it returns 0
    # for every dev and the verdict prints `ok`. MEASURED 2026-08-06: all 16
    # such lanes reported 0/0/ok — a symmetric zero across every lane of one
    # kind describes the INSTRUMENT, not the team, and it was about to be put
    # in front of two humans as grounds for ratification. Measure these by
    # CONTENT (-G on the surface name) instead; the mode is printed so a reader
    # can tell a measured zero from an unmeasurable one.
    LANE_MODE=path; LANE_RE=""
    case "$GLOB" in
      "$DATA_LANE_PREFIX"*)
        T=${GLOB#"$DATA_LANE_PREFIX"}
        if [ -n "$T" ]; then
          LANE_MODE=content
          case "$T" in
            *\*) LANE_RE="\\b${T%\*}[A-Za-z0-9_]*" ;;
            *)   LANE_RE="\\b${T}\\b" ;;
          esac
        else
          LANE_MODE=unmeasured
        fi
        ;;
    esac

    ROW=""; OTHER_HIT=""
    for D in $DEVS; do
      eval "DEFN=\"\${DEV_${D}:-}\""
      RE=$(printf '%s' "$DEFN" | cut -d'|' -f2)
      C=0
      if [ -n "$RE" ]; then
        # shellcheck disable=SC2086  # CONTENT_PATHS is a deliberate word-split pathspec list
        case "$LANE_MODE" in
          content) C=$(git log --since="$SINCE" --format='%an' -G"$LANE_RE" "$UPSTREAM" -- $CONTENT_PATHS 2>/dev/null | grep -cE "$RE") ;;
          path)    C=$(git log --since="$SINCE" --format='%an' --name-only "$UPSTREAM" -- "$GLOB" 2>/dev/null | grep -cE "$RE") ;;
          *)       C="" ;;
        esac
      fi
      ROW="$ROW	${C:-?}"
      if [ "$D" != "$OWNER" ] && [ -n "${C:-}" ] && [ "$C" -gt 0 ]; then OTHER_HIT="$D"; fi
    done
    if [ "$LANE_MODE" = unmeasured ]; then
      V="UNMEASURED (no way to attribute this lane)"
    else
      # The verdict must read the MODE, not only the owner. A `frozen` lane also
      # carries owner `*` — and printed "shared by declaration" for it, i.e. the
      # map's only hard WALL announced itself as its most permissive state.
      # Whoever ratifies from this table reads the verdict, not the map.
      V=ok
      [ "$OWNER" = "*" ] && V="shared by declaration"
      [ "$MODE" = frozen ] && V="FROZEN (no build decision changes this)"
      [ "$MODE" = contested ] && V="contested — nobody has ruled"
      [ "$OWNER" != "*" ] && [ -n "$OTHER_HIT" ] && V="CONTRADICTED ($OTHER_HIT touched a $OWNER lane)"
      V="$V [$LANE_MODE]"
    fi
    printf '%s\t%s%s\t%s\n' "$GLOB" "$OWNER" "$ROW" "$V"
  done
  exit 0
fi

[ -f "$MAP" ] || { echo "ownership-lint: NOT RUN — no ownership map at ${MAP:-<PF_OWNERSHIP_MAP is not set>}; lanes cannot be judged" >&2; exit 3; }

# A map line carrying a literal '{' reads like brace-expansion but isn't one:
# the matcher below is shell CASE-pattern matching, where '{' and '}' are
# ordinary characters that match themselves, never a choice of alternatives.
# One glob per line is the map's own documented contract — flag a violation as
# a map defect instead of letting it silently fail to match anything.
BRACE_LINES=$(grep -n '{' "$MAP" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#')
if [ -n "$BRACE_LINES" ]; then
  echo "ownership-lint: MAP ERROR — literal '{' in $MAP (braces are NOT expanded by case-glob matching; one glob per line):" >&2
  echo "$BRACE_LINES" >&2
fi

[ ${#PATHS[@]} -gt 0 ] || { say "ownership-lint: no paths given"; exit 0; }
[ -n "$DEV" ] || { echo "ownership-lint: NOT RUN — \$$DEV_ENV_VAR is unset and --dev was not given; lanes cannot be judged" >&2; exit 3; }

RC=0
bump() { [ "$1" -gt "$RC" ] && RC="$1"; }

# ── ratification escape (cross-concern receipt, not a gate) ───────────────────
# Search order: --ratified flag, then $RATIFIED, then the last commit's message
# body. The first source that CONTAINS the token wins; a source that does NOT
# contain it just falls through to the next one, it never stops the search.
RATIFIED_SRC=""
if [ -n "$RATIFIED_FLAG" ] && printf '%s' "$RATIFIED_FLAG" | grep -qF "$RATIFY_TOKEN"; then
  RATIFIED_SRC="--ratified flag"
elif [ -n "${RATIFIED:-}" ] && printf '%s' "$RATIFIED" | grep -qF "$RATIFY_TOKEN"; then
  RATIFIED_SRC="\$RATIFIED env"
else
  GIT_MSG=$(cd "$REPO_ROOT" 2>/dev/null && git log -1 --format=%B 2>/dev/null)
  if [ -n "$GIT_MSG" ] && printf '%s' "$GIT_MSG" | grep -qF "$RATIFY_TOKEN"; then
    RATIFIED_SRC="last commit message"
  fi
fi
# ── the receipt must be SCOPED TO THE ACT ─────────────────────────────────────
# The "last commit message" fallback used to be AMBIENT: a `RATIFIED:` written for
# build A covered B, C, D... until the first commit without the token. Measured on
# the origin project: linting a path in the other developer's lane, outside the
# current programme, exited 0 with no `own lane` line, only `RECORDED: (source:
# last commit message)`. The guard was not loosened, it was OFF; and an empty
# RATIFIED="" did not restore it, because an empty variable falls back to the
# message by design.
#
# A receipt carried by something that OUTLIVES THE ACT is a switch left on, and its
# signature is never an error: it is a silent loosening. The fix does not remove
# the source (the commit message remains the correct audit trail afterwards); it
# BOUNDS it to the paths that commit actually touches. Intended consequence: before
# committing, a lane crossing is declared with `--ratified` on the call. Stating
# the intention is exactly what an ambient receipt let people skip.
RATIFIED_FILES=""
if [ "$RATIFIED_SRC" = "last commit message" ]; then
  RATIFIED_FILES=$(cd "$REPO_ROOT" 2>/dev/null && git log -1 --name-only --format= 2>/dev/null)
fi

# Returns 0 when the receipt covers THIS path, 1 otherwise. An explicit receipt
# (--ratified or $RATIFIED) covers the invocation, hence all its paths; a receipt
# read from a commit covers only the files of that commit.
is_ratified_for() {
  [ -n "$RATIFIED_SRC" ] || return 1
  [ "$RATIFIED_SRC" = "last commit message" ] || return 0
  printf '%s\n' "$RATIFIED_FILES" | grep -qxF "$1"
}

ratify_hint() {
  say "       To proceed: pass --ratified \"$RATIFY_TOKEN <who>, <when>\", or set RATIFIED=\"$RATIFY_TOKEN <who>, <when>\", or put a '$RATIFY_TOKEN <who>, <when>' line in the commit message body."
}

# --claim-exempt: paths (EXACT equality, never a glob) that skip the CLAIM check
# but keep the LANE check. For a governance surface every session READS (the
# ownership map, the claims ledger, the handoff register): a claim over it must
# not STOP a session whose build never touches it. The exemption is tested
# FIRST in the claim loop, ahead of the same-dev / other-dev split, so it covers
# the same-dev-other-session verdict as well as the cross-dev one.
is_claim_exempt() {
  [ -n "$CLAIM_EXEMPT" ] || return 1
  local E
  set -f
  for E in $CLAIM_EXEMPT; do
    if [ "$1" = "$E" ]; then set +f; return 0; fi
  done
  set +f
  return 1
}

for P in ${PATHS[@]+"${PATHS[@]}"}; do
  # Collect EVERY matching lane, not just the last one — a path legitimately
  # matches several lanes at different concerns (one owner's logic in a file,
  # another owner's styling tokens in that same file). The universal `*`
  # catch-all is collected separately: it grants an informational
  # "you also own X here", never a blanket pass and never a block by itself —
  # otherwise the one lane that matches every path would make the whole map inert.
  FROZEN_HITS=""; SPEC_MINE=""; SPEC_OTHER=""; SPEC_SHARED=""; SPEC_CONTESTED=""
  STAR_HITS=""; UNKNOWN_HITS=""

  while read -r M O C G REST; do
    case "$M" in ''|'#'*) continue ;; esac
    [ -z "${G:-}" ] && continue
    # shellcheck disable=SC2254
    case "$P" in
      $G)
        if [ "$G" = "*" ]; then
          STAR_HITS="$STAR_HITS
$M	$O	$C	$G"
        else
          case "$M" in
            frozen)    FROZEN_HITS="$FROZEN_HITS
$C	$G" ;;
            own)
              if [ "$O" = "$DEV" ]; then
                SPEC_MINE="$SPEC_MINE
$C	$G"
              else
                SPEC_OTHER="$SPEC_OTHER
$O	$C	$G"
              fi ;;
            shared)    SPEC_SHARED="$SPEC_SHARED
$G	$C" ;;
            contested) SPEC_CONTESTED="$SPEC_CONTESTED
$G	$C" ;;
            *)         UNKNOWN_HITS="$UNKNOWN_HITS
$M	$G" ;;
          esac
        fi ;;
    esac
  done < "$MAP"

  # frozen is the one wall ratification cannot open — it dominates every other
  # lane match on this path, so nothing else needs evaluating.
  if [ -n "$FROZEN_HITS" ]; then
    printf '%s\n' "$FROZEN_HITS" | while IFS="$(printf '\t')" read -r C G REST; do
      [ -z "$C" ] && [ -z "$G" ] && continue
      say "  ⛔   $P — FROZEN lane ($G): $C. Owner ruling required; not a build decision. Ratification does NOT apply to a frozen lane."
    done
    bump 2
    continue
  fi

  if [ -n "$SPEC_OTHER" ]; then
    if is_ratified_for "$P" && [ "$RATIFY_ACTION" != "BLOCK" ]; then
      say "  RECORDED: $P — cross-concern write ratified (source: $RATIFIED_SRC)."
      printf '%s\n' "$SPEC_OTHER" | while IFS="$(printf '\t')" read -r O C G; do
        [ -z "$O" ] && continue
        say "       lane crossed: '$C' owned by '$O' ($G) — '$O' must smoke-test this lane."
      done
      bump 1
    else
      # Does the acting dev ALSO own a specific lane on this same path? MATCH
      # SEMANTICS (see OWNERSHIP.map's header) says the linter "refuses only
      # when the acting dev owns NONE of them" — the concern axis exists
      # precisely so two devs can own different concerns in ONE file. The code
      # refused on the mere PRESENCE of another dev's lane, which is not the
      # documented rule and makes a freshly-declared lane DECORATIVE.
      # Measured: with `own A ops src/shipping*.php` written and matching,
      # the path still exited 2 — indistinguishable from `src/crm.php`, which
      # A genuinely does not own. A map that blocks a change its own rule
      # permits is overridden once and ignored forever (the same failure the
      # `own B style *` catch-all caused).
      # So: co-ownership DOWNGRADES to a named warning; the
      # other dev's concern is still printed, because the boundary has to stay
      # visible — what changes is that it no longer STOPS a dev who owns a lane
      # here. ⚠️ ONE case keeps the ⛔ even then: a lane held at ALL concerns
      # (`C = *`) is a claim over the whole file, and owning one concern under
      # it does not carve anything out.
      # NB: the asterisk must be ESCAPED — inside a case pattern a bare `*` is
      # a wildcard, so the naive `*<TAB>*<TAB>*` matches every line that has
      # two tabs, i.e. ALWAYS, and the downgrade would never fire.
      OTHER_AT_ALL=0
      TABC=$(printf '\t')
      case "$SPEC_OTHER" in
        *"$TABC"\*"$TABC"*) OTHER_AT_ALL=1 ;;
      esac
      CO_OWNED=0
      [ -n "$SPEC_MINE" ] && [ "$OTHER_AT_ALL" = 0 ] && CO_OWNED=1

      printf '%s\n' "$SPEC_OTHER" | while IFS="$(printf '\t')" read -r O C G; do
        [ -z "$O" ] && continue
        if [ "$C" = "*" ]; then
          say "  ⛔   $P — lane belongs to '$O' at ALL concerns ($G). STOP: open a handoff item, do not edit."
        elif [ "$CO_OWNED" = 1 ]; then
          say "  ⚠    $P — '$O' also owns concern '$C' here ($G), and YOU own a lane on this path. Not a refusal (MATCH SEMANTICS). If your change touches '$C', it needs a ratification and '$O' must smoke-test it."
        else
          say "  ⛔   $P — lane belongs to '$O' for concern '$C' ($G). You may only touch a DIFFERENT concern."
        fi
      done
      if [ "$CO_OWNED" = 1 ]; then
        bump 1
      else
        if is_ratified_for "$P" && [ "$RATIFY_ACTION" = "BLOCK" ]; then
          say "       Ratified (source: $RATIFIED_SRC), but this profile sets PF_RATIFY_ACTION=BLOCK — the block stands regardless."
        else
          ratify_hint
        fi
        bump 2
      fi
    fi
  fi

  if [ -n "$SPEC_MINE" ]; then
    printf '%s\n' "$SPEC_MINE" | while IFS="$(printf '\t')" read -r C G; do
      [ -z "$C" ] && continue
      say "  ok   $P — own lane '$C' ($G)"
    done
    printf '%s\n' "$STAR_HITS" | while IFS="$(printf '\t')" read -r M O C G; do
      [ -z "$O" ] && continue
      [ "$O" = "$DEV" ] && continue
      say "       also here: '$O' owns '$C' ($G) — if your change touches that concern, it needs a ratification."
    done
  fi

  if [ -n "$SPEC_SHARED" ]; then
    printf '%s\n' "$SPEC_SHARED" | while IFS="$(printf '\t')" read -r G C; do
      [ -z "$G" ] && continue
      say "  ⚠    $P — SHARED lane ($G, concern '$C'). Deploy PER FILE, md5-verify the deploy target against ${UPSTREAM:-the shared reference} before and after, and name the other owner in the PM record."
    done
    bump 1
  fi

  if [ -n "$SPEC_CONTESTED" ]; then
    printf '%s\n' "$SPEC_CONTESTED" | while IFS="$(printf '\t')" read -r G C; do
      [ -z "$G" ] && continue
      say "  ⚠    $P — CONTESTED lane ($G): $C. Both devs have landed here. Open a handoff item BEFORE editing; state the environment you tested on."
    done
    bump 1
  fi

  if [ -z "$SPEC_OTHER" ] && [ -z "$SPEC_MINE" ] && [ -z "$SPEC_SHARED" ] && [ -z "$SPEC_CONTESTED" ]; then
    MINE_STAR=""
    if [ -n "$STAR_HITS" ]; then
      MINE_STAR=$(printf '%s\n' "$STAR_HITS" | awk -F'\t' -v dev="$DEV" '$2==dev{print; exit}')
    fi
    if [ -n "$MINE_STAR" ]; then
      SC=$(printf '%s' "$MINE_STAR" | cut -f3); SG=$(printf '%s' "$MINE_STAR" | cut -f4)
      say "  ok   $P — own catch-all lane '$SC' ($SG); otherwise UNMAPPED for any other concern."
    else
      say "  ?    $P — UNMAPPED lane. Add it to OWNERSHIP.map before landing, or say why it has no owner."
      bump 1
    fi
  fi

  if [ -n "$UNKNOWN_HITS" ]; then
    printf '%s\n' "$UNKNOWN_HITS" | while IFS="$(printf '\t')" read -r M G; do
      [ -z "$M" ] && continue
      say "  ?    $P — unknown mode '$M' in map ($G)"
    done
    bump 1
  fi
done

# ── live claims ────────────────────────────────────────────────────────────────
if [ -f "$CLAIMS" ]; then
  TODAY=$(date -u '+%Y-%m-%d')

  # A claim's state is the LAST row for its (dev, slug) pair. CLAIMS.tsv is
  # append-only, so a closure is a NEW row — never an edit of the opening one.
  # Reading rows independently and merely `continue`-ing on `closed` (what this
  # loop did until 2026-08-11) means NOTHING in the toolchain ever consumed a
  # closure: the register had a writer and no reader, and every claim ever
  # opened blocked the other dev FOREVER. Measured that day, from l's side, on
  # a claim k had opened AND closed the same morning, whose build was already
  # deployed: ⛔ "under an OPEN CLAIM by 'k' … Talk first." The file's own
  # header promises "two lines per build — one to open, one to close"; the
  # second line had no consumer. Collapsing to last-row-wins also de-duplicates
  # a re-opened slug, which previously fired once per historical opening.
  CLAIMS_OPEN="$(awk -F'\t' '
    /^#/  { next }
    $1==""{ next }
    { k = $3 "\t" $4
      if (!(k in seen)) { seen[k] = 1; ord[++n] = k }
      st[k] = $1; rec[k] = $0 }
    # A claim is LIVE unless its last row is TERMINAL (closed / abandoned): any
    # other state — open, restated (the ageing message itself says "close it or
    # restate it"), a state this vocabulary has not met yet — keeps it held.
    # Comparing against == "open" made a `restated` row erase a live claim held
    # by someone else; enumerating the TERMINAL states fails closed instead.
    # (No ASCII apostrophe in this block: it sits in shell single quotes.)
    END { for (i = 1; i <= n; i++) if (st[ord[i]] != "closed" && st[ord[i]] != "abandoned") print rec[ord[i]] }
  ' "$CLAIMS")"

  for P in ${PATHS[@]+"${PATHS[@]}"}; do
    while IFS="$(printf '\t')" read -r STATE OPENED CDEV SLUG CGLOB NOTE CSESSION; do
      # Same terminal set as the reduction above — kept in step deliberately.
      case "${STATE:-}" in ''|'#'*|closed|abandoned) continue ;; esac
      [ -z "${CGLOB:-}" ] && continue
      # CGLOB is a SPACE-separated list of globs (CLAIMS.tsv's own documented
      # format) — test each one, not the whole field as a single pattern.
      # `set -f` is load-bearing: an unquoted `for x in $list` word-splits
      # AND pathname-expands, so a token like 'claude-brain/pm-kit/**' would
      # otherwise be silently replaced by whatever real files it matches on
      # disk RIGHT NOW, instead of staying a literal pattern for `case`.
      set -f
      for CG in $CGLOB; do
        # shellcheck disable=SC2254
        case "$P" in $CG)
          if is_claim_exempt "$P"; then
            say "  ok   $P — governance surface (claim-exempt): the CLAIM check is waived, the LANE check above still applies. (under claim '$SLUG' by '$CDEV' since $OPENED)"
          elif [ "$CDEV" = "$DEV" ]; then
            # Matching the dev initial proves the CORRIDOR, not the session.
            # Three outcomes, and the default (unknown on either side) is the
            # LOUD one — a vocabulary this open must fail closed, or the FALSE
            # GREEN this replaces walks straight back in the day a corpus of
            # 6-field claims is migrated.
            if [ -z "$CUR_SESSION" ]; then
              say "  ⚠    $P — claim '$SLUG' by dev '$CDEV' (since $OPENED): CURRENT SESSION UNKNOWN (\$$SESSION_ENV_VAR unset/empty) — cannot tell whether this claim is yours. Ask who holds it."
              bump 1
            elif [ -z "${CSESSION:-}" ]; then
              say "  ⚠    $P — claim '$SLUG' by dev '$CDEV' (since $OPENED): SESSION UNKNOWN in the claim (7th field absent) — a dev initial is NECESSARY, never SUFFICIENT. Ask who holds it."
              bump 1
            elif [ "$CSESSION" = "$CUR_SESSION" ]; then
              say "  ok   $P — under YOUR open claim '$SLUG' (since $OPENED)"
            elif _session_field_is_mine "$CSESSION"; then
              # Written by hand: the session id is mine, but not in the form
              # claim.sh writes. Recognised, and said, so it gets rewritten.
              say "  ok   $P — under YOUR open claim '$SLUG' (since $OPENED); its session field '$CSESSION' is not in the canonical form '$CUR_SESSION' (claim.sh writes ${SESSION_PREFIX}<first 8 characters of \$$SESSION_ENV_VAR>)"
            elif ! _session_field_wellformed "$CSESSION"; then
              say "  ⛔   $P — claim '$SLUG' by dev '$CDEV' (since $OPENED) has a MALFORMED session field '$CSESSION': expected '${SESSION_PREFIX}' followed by the first 8 characters of the session id (what claim.sh writes), e.g. '${SESSION_PREFIX}${_SESS_RAW:-abcd1234}' for the current session. It is not recognisable as this session, so it is treated as another session's; repair the field or ask who holds the claim."
              bump 2
            else
              say "  ⛔   $P — under an open claim by ANOTHER SESSION of the same dev ('$CSESSION', '$SLUG', since $OPENED) — ask who holds it; never conclude \"that one is mine\"."
              say "       Two sessions of the same dev building the same surface is how a feature ships twice. Talk first."
              bump 2
            fi
          else
            say "  ⛔   $P — under an OPEN CLAIM by '$CDEV': '$SLUG' since $OPENED. ${NOTE:-}"
            say "       Two sessions building the same surface is how a feature ships twice. Talk first."
            bump 2
          fi ;;
        esac
      done
      set +f
    done <<EOF_CLAIMS_OPEN
$CLAIMS_OPEN
EOF_CLAIMS_OPEN
  done
  # A claim nobody closed is indistinguishable from a claim nobody is working on.
  # Reads the collapsed set, so a slug closed today stops nagging today.
  CLAIMS_AGING="$(awk -F'\t' -v today="$TODAY" -v stale="$STALE_DAYS" '
    function g(y,m,d,  a,yy,mm){a=int((14-m)/12);yy=y+4800-a;mm=m+12*a-3;
      return d+int((153*mm+2)/5)+365*yy+int(yy/4)-int(yy/100)+int(yy/400)-32045}
    $1!="" && $4!="" {
      split($2,o,"-"); split(today,t,"-")
      age=g(t[1]+0,t[2]+0,t[3]+0)-g(o[1]+0,o[2]+0,o[3]+0)
      if (age>stale+0) printf "  ⚠    claim %s by %s is %d days old — close it or restate it\n", $4, $3, age
    }' <<EOF_CLAIMS_AGING
$CLAIMS_OPEN
EOF_CLAIMS_AGING
)"
  # NOT `awk … | while read; do bump; done`: the last stage of a pipeline runs
  # in a SUBSHELL, so every bump landed on a copy of RC and was discarded —
  # measured 2026-08-11, three ⚠ printed and EXIT=0. That is verbatim the
  # failure this file's own header calls "the bug, not the baseline".
  if [ -n "$CLAIMS_AGING" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      say "$l"; bump 1
    done <<EOF_AGING
$CLAIMS_AGING
EOF_AGING
  fi
else
  say "  ⚠    no $CLAIMS — nothing records what is IN FLIGHT; only what already landed."
  bump 1
fi

exit "$RC"
