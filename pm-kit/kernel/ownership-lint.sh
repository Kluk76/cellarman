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
# ignored forever. So the lane is (owner × concern × glob), and cross-concern
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
#   🔴 Le reçu lu dans un COMMIT ne couvre QUE les fichiers de ce commit (voir
#   `is_ratified_for`) : un reçu ambiant survivait à son build et éteignait la
#   garde pour tout le suivant. Un reçu explicite (--ratified / $RATIFIED) porte
#   sur l'invocation. ⇒ AVANT de commiter, une traversée se déclare avec
#   `--ratified` ; le message de commit reste la trace d'audit APRÈS coup.
#   ⛔ Ne jamais lire un verdict au CODE DE SORTIE : lire la présence d'une
#   ligne `own lane` / `SHARED lane`. Un `RECORDED:` seul est un blocage
#   maquillé en autorisation.
#
# EXIT
#   0  every path is in the acting dev's own lane, unclaimed by the other
#   1  at least one path is in a shared/contested/unmapped lane, or a
#      cross-concern write was RATIFIED (see RECORDED: lines)
#   2  at least one path is in a frozen lane, or in another dev's lane at a
#      concern that dev doesn't own and no ratification was found, or under an
#      open claim held by the other dev
#
# USAGE
#   ownership-lint.sh [--map F] [--claims F] [--dev <id>] [--ratified TEXT] [--quiet] [--refresh] PATH...
#   ownership-lint.sh --refresh            # regenerate the EVIDENCE column from git
#   RATIFIED="RATIFIED: k+l, 2026-08-06" ownership-lint.sh PATH...
#   git diff --name-only | xargs ownership-lint.sh

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
PATHS=""
RATIFIED_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --conf)    CONF="$2"; shift 2 ;;
    --map)     MAP="$2"; shift 2 ;;
    --claims)  CLAIMS="$2"; shift 2 ;;
    --dev)     DEV="$2"; shift 2 ;;
    --ratified) RATIFIED_FLAG="$2"; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*)        echo "ownership-lint: unknown flag $1" >&2; exit 64 ;;
    *)         PATHS="$PATHS $1"; shift ;;
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

if [ -z "$CONF" ] || [ ! -f "$CONF" ]; then
  echo "ownership-lint: STOP — no profile found (--conf, \$PM_PROFILE, a single claude-brain/pm-kit/profiles/*.conf, or a single kernel/*.conf). This kernel carries no team/lane vocabulary of its own." >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$CONF"

: "${MAP:=${PF_OWNERSHIP_MAP:-}}"
: "${CLAIMS:=${PF_CLAIMS_FILE:-}}"
: "${SINCE:=${PF_OWNERSHIP_SINCE:-}}"
: "${UPSTREAM:=${PF_REF_NAME:-}}"
: "${DEV_ENV_VAR:=PM_DEV}"
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

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# ── --refresh : keep the map HONEST by regenerating its evidence from git ──────
# A hand-written ownership map rots into aspiration. This does not rewrite the
# LANES (that is a human ruling); it recomputes, per lane, who has actually
# touched it since $SINCE, so a lane whose evidence contradicts its owner is
# visible at a glance and can be argued about with numbers.
if [ "$REFRESH" = 1 ]; then
  if [ -z "${DEVS:-}" ] || [ -z "$UPSTREAM" ]; then
    echo "ownership-lint: --refresh needs the profile to define DEVS and PF_REF_NAME — UNMEASURED" >&2
    exit 64
  fi
  cd "$REPO_ROOT" || exit 64
  printf '# ownership evidence — regenerated %s, commits since %s on %s\n' \
         "$(date -u '+%Y-%m-%d')" "$SINCE" "$UPSTREAM"
  HDR="# lane	declared"
  for D in $DEVS; do HDR="$HDR	${D}_commits"; done
  printf '%s\tverdict\n' "$HDR"
  grep -v '^#' "$MAP" 2>/dev/null | grep -v '^[[:space:]]*$' | while read -r MODE OWNER CONCERN GLOB REST; do
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

[ -f "$MAP" ] || { say "ownership-lint: no map at $MAP"; exit 1; }

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

[ -n "$PATHS" ] || { say "ownership-lint: no paths given"; exit 0; }
[ -n "$DEV" ] || { say "ownership-lint: \$$DEV_ENV_VAR unset and --dev not given — cannot judge lanes"; exit 1; }

RC=0
bump() { [ "$1" -gt "$RC" ] && RC="$1"; }

# ── ratification escape (cross-concern receipt, not a gate) ───────────────────
# Search order: --ratified flag, then $RATIFIED, then the last commit's message
# body. The first source that CONTAINS the token wins; a source that does NOT
# contain it just falls through to the next one, it never stops the search.
RATIFIED_SRC=""
RATIFIED_TEXT=""
if [ -n "$RATIFIED_FLAG" ] && printf '%s' "$RATIFIED_FLAG" | grep -qF "$RATIFY_TOKEN"; then
  RATIFIED_SRC="--ratified flag"; RATIFIED_TEXT="$RATIFIED_FLAG"
elif [ -n "${RATIFIED:-}" ] && printf '%s' "$RATIFIED" | grep -qF "$RATIFY_TOKEN"; then
  RATIFIED_SRC="\$RATIFIED env"; RATIFIED_TEXT="$RATIFIED"
else
  GIT_MSG=$(cd "$REPO_ROOT" 2>/dev/null && git log -1 --format=%B 2>/dev/null)
  if [ -n "$GIT_MSG" ] && printf '%s' "$GIT_MSG" | grep -qF "$RATIFY_TOKEN"; then
    RATIFIED_SRC="last commit message"; RATIFIED_TEXT="$GIT_MSG"
  fi
fi
# ── the receipt must be SCOPED TO THE ACT ─────────────────────────────────────
# 🔴 Le repli « dernier message de commit » était AMBIANT : un `RATIFIED:` posé
# pour le build A couvrait B, C, D… jusqu'au premier commit sans le jeton.
# Mesuré : `ownership-lint --dev A src/crm.php` — couloir du second
# développeur, hors du programme en cours — rendait **EXIT=0 sans aucune
# ligne `own lane`**, uniquement `RECORDED: (source: last commit message)`. La
# garde n'était pas assouplie, elle était ÉTEINTE. Et `RATIFIED=""` ne la
# rétablissait pas : la variable vide retombe (à dessein) sur le message.
#
# Un reçu porté par un support qui SURVIT À L'ACTE est un interrupteur laissé
# sur ON, et sa signature n'est jamais une erreur — c'est un assouplissement
# silencieux. Le correctif ne supprime pas la source (le message de commit reste
# la trace d'audit correcte APRÈS coup) : il la BORNE aux chemins que ce commit
# touche réellement. Conséquence voulue : avant de commiter, une traversée de
# couloir se déclare avec `--ratified` sur l'appel — dire son intention est
# précisément ce qu'un reçu ambiant permettait d'éviter.
RATIFIED_FILES=""
if [ "$RATIFIED_SRC" = "last commit message" ]; then
  RATIFIED_FILES=$(cd "$REPO_ROOT" 2>/dev/null && git log -1 --name-only --format= 2>/dev/null)
fi

# 1 si le reçu couvre CE chemin, 0 sinon. Un reçu explicite (--ratified /
# $RATIFIED) porte sur l'invocation, donc sur tous ses chemins ; un reçu lu dans
# un commit ne porte que sur les fichiers de ce commit.
is_ratified_for() {
  [ -n "$RATIFIED_SRC" ] || return 1
  [ "$RATIFIED_SRC" = "last commit message" ] || return 0
  printf '%s\n' "$RATIFIED_FILES" | grep -qxF "$1"
}

ratify_hint() {
  say "       To proceed: pass --ratified \"$RATIFY_TOKEN <who>, <when>\", or set RATIFIED=\"$RATIFY_TOKEN <who>, <when>\", or put a '$RATIFY_TOKEN <who>, <when>' line in the commit message body."
}

for P in $PATHS; do
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
    END { for (i = 1; i <= n; i++) if (st[ord[i]] == "open") print rec[ord[i]] }
  ' "$CLAIMS")"

  for P in $PATHS; do
    while IFS="$(printf '\t')" read -r STATE OPENED CDEV SLUG CGLOB NOTE; do
      case "${STATE:-}" in ''|'#'*|closed) continue ;; esac
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
          if [ "$CDEV" = "$DEV" ]; then
            say "  ok   $P — under YOUR open claim '$SLUG' (since $OPENED)"
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
  CLAIMS_AGING="$(awk -F'\t' -v today="$TODAY" '
    function g(y,m,d,  a,yy,mm){a=int((14-m)/12);yy=y+4800-a;mm=m+12*a-3;
      return d+int((153*mm+2)/5)+365*yy+int(yy/4)-int(yy/100)+int(yy/400)-32045}
    $1=="open" {
      split($2,o,"-"); split(today,t,"-")
      age=g(t[1]+0,t[2]+0,t[3]+0)-g(o[1]+0,o[2]+0,o[3]+0)
      if (age>3) printf "  ⚠    claim %s by %s is %d days old — close it or restate it\n", $4, $3, age
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
