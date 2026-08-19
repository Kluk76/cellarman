#!/usr/bin/env bash
# pm-preflight.sh — the clash detector a PM runs BEFORE it sequences anything,
# and before any build agent is dispatched. Portable kernel: carries no project
# nouns — see profiles/*.conf for those, and the profile-discovery block below.
#
# WHY THIS EXISTS
#   Every cross-dev incident had the same shape: the correct rule was written
#   down, in prose, in a file somebody had to remember to read — and nothing
#   evaluated the rule against the actual state at the moment it mattered. This
#   script evaluates them. It is the executable half of rails that otherwise
#   exist only as words in a project's PM memory.
#
# DESIGN CONSTRAINTS (learned the hard way, see 00-audit.md §3)
#   - MUST run on macOS bash 3.2 as well as Linux bash 5. No associative arrays,
#     no mapfile, no ${x,,}, no `date -Is`, no `grep -P`, no `readlink -f`.
#     Empty arrays are always expanded as ${a[@]+"${a[@]}"}.
#   - MUST NOT write anything outside $TMPDIR. It is a read-only instrument.
#   - MUST distinguish WARN from STOP. Everything else in this toolchain exits 0
#     with a warning nobody reads; that pattern is the bug, not the baseline.
#
# EXIT CODES  (the whole point — a checker that cannot stop a session is decoration)
#   0  clear
#   1  warnings only — proceed, but the consult must name them
#   2  STOP — the PM must not sequence the build until a human resolves it
#
# USAGE
#   pm-preflight.sh                                  # repo-wide pre-flight
#   pm-preflight.sh --paths src/billing.php app/db.php
#   pm-preflight.sh --migrations db/migrations/_draft/foo.sql
#   pm-preflight.sh --probe-db                       # + live VPS/schema probes
#   pm-preflight.sh --no-fetch                       # skip network (offline)
#   pm-preflight.sh --json                           # machine-readable summary
#
# PORTABILITY (this file carries ZERO project nouns — see profiles/*.conf)
#   Repo root, in order:
#     1. $PM_REPO_ROOT if the environment provides it
#     2. `git rev-parse --show-toplevel` run FROM THE CALLER'S CWD
#     3. fallback: the kernel dir's grandparent-of-grandparent (works only
#        when this file still lives at <repo>/claude-brain/pm-kit/kernel/) —
#        printed as an explicit WARNING, never silent.
#   Profile (the file supplying every project noun), in order:
#     1. --conf <path>
#     2. $PM_PROFILE — a path if the file exists at that exact path, else
#        treated as a bare profile NAME resolved under the kit's profiles/ dir
#     3. <repo-root>/claude-brain/pm-kit/profiles/*.conf — used only if
#        EXACTLY ONE match
#     4. a *.conf sitting next to this script (kernel/*.conf) — used only if
#        EXACTLY ONE match
#   No profile found ⇒ STOP (exit 2). This tool has no meaning without one.

set -u

# ── locate ──────────────────────────────────────────────────────────────────────
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF=""

if [ -n "${PM_REPO_ROOT:-}" ]; then
  REPO_ROOT="$PM_REPO_ROOT"
elif REPO_ROOT="$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO_ROOT" ]; then
  :
else
  REPO_ROOT="$(cd "$KIT_DIR/../../.." && pwd)"
  echo "pm-preflight: WARNING no \$PM_REPO_ROOT and cwd is not inside a git repo — falling back to the kernel's grandparent-of-grandparent ($REPO_ROOT). This is only correct if the kernel still lives at <repo>/claude-brain/pm-kit/kernel/." >&2
fi

DO_FETCH=1; DO_PROBE=0; DO_JSON=0
PATHS=(); MIGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --conf)       CONF="$2"; shift 2 ;;
    --no-fetch)   DO_FETCH=0; shift ;;
    --probe-db)   DO_PROBE=1; shift ;;
    --json)       DO_JSON=1; shift ;;
    --paths)      shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do PATHS[${#PATHS[@]}]="$1"; shift; done ;;
    --migrations) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do MIGS[${#MIGS[@]}]="$1"; shift; done ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "pm-preflight: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

# ── profile discovery (see header) ─────────────────────────────────────────────
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
  echo "pm-preflight: STOP — no profile found (--conf, \$PM_PROFILE, a single claude-brain/pm-kit/profiles/*.conf, or a single kernel/*.conf). This kernel carries no project nouns of its own and cannot run without one." >&2
  exit 2
fi

# shellcheck disable=SC1090
. "$CONF"

# ── profile → internal working variables ───────────────────────────────────────
# The profile speaks its own PF_*/PM_* vocabulary (see profiles/*.conf); this is
# the ONE place that vocabulary is translated into the names the checks below
# use. Keeping the mapping here (not scattered through the checks) is what lets
# the checks stay noun-free.
: "${UPSTREAM:=${PF_REF_NAME:-}}"
: "${MIG_DIR:=${PF_QUEUE_DIR:-}}"
: "${DRAFT_DIR:=${PF_QUEUE_STAGING:-}}"
: "${HANDOFF:=${PF_ARB_FILE:-}}"
: "${OWNERSHIP_MAP:=${PF_OWNERSHIP_MAP:-}}"
: "${SCRAPPING:=${PF_DEBT_FILE:-}}"
: "${DOCTOR:=${PM_DOCTOR:-}}"
: "${SSH_TARGET:=${PF_TARGET_HOST:-}}"
: "${VPS_PATH:=${PF_TARGET_PATH:-}}"
: "${DB_SCHEMA:=${PF_DB_SCHEMA:-}}"
: "${ARB_WARN_DAYS:=${PF_ARB_WARN_DAYS:-3}}"
: "${ARB_STOP_DAYS:=${PF_ARB_STOP_DAYS:-7}}"
: "${SHARED_TOOLS:=${PF_SHARED_TOOLS:-}}"
: "${QUEUE_AUTHOR_RE:=${PF_QUEUE_AUTHOR_RE:-}}"
: "${NS_TAKEN_CMD:=${PF_NS_TAKEN:-}}"
: "${DEV_ENV_VAR:=PM_DEV}"
: "${RAILS_TSV:=${PF_RAILS_OUTPUT:-}}"
: "${OWNERSHIP_PROSE:=${PF_OWNERSHIP_PROSE:-}}"

if [ -z "$UPSTREAM" ]; then
  echo "pm-preflight: STOP — profile '$CONF' does not define PF_REF_NAME (or UPSTREAM directly) — the shared-reference branch is undeclared." >&2
  exit 2
fi

cd "$REPO_ROOT" || { echo "pm-preflight: cannot cd $REPO_ROOT" >&2; exit 64; }

# Propagate the resolved root/profile/dev-var so a spawned ownership-lint.sh
# (P5 below) resolves the SAME profile deterministically, rather than
# re-discovering it independently and risking disagreement.
export PM_REPO_ROOT="$REPO_ROOT"
export PM_PROFILE="$CONF"
export DEV_ENV_VAR

RC=0
WARN_N=0
STOP_N=0
JSON_ROWS=""

_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
_row() { # kind check message
  JSON_ROWS="$JSON_ROWS{\"level\":\"$1\",\"check\":\"$2\",\"msg\":\"$(_esc "$3")\"},"
}
ok()   { [ "$DO_JSON" = 1 ] || printf '  \033[32mok\033[0m   %-22s %s\n' "$1" "$2"; _row ok "$1" "$2"; }
warn() { WARN_N=$((WARN_N+1)); [ "$RC" -lt 1 ] && RC=1
         [ "$DO_JSON" = 1 ] || printf '  \033[33mWARN\033[0m %-22s %s\n' "$1" "$2"; _row warn "$1" "$2"; }
stop() { STOP_N=$((STOP_N+1)); RC=2
         [ "$DO_JSON" = 1 ] || printf '  \033[31mSTOP\033[0m %-22s %s\n' "$1" "$2"; _row stop "$1" "$2"; }
sec()  { [ "$DO_JSON" = 1 ] || printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "$DO_JSON" = 1 ] || printf '\033[1mpm-preflight\033[0m  %s  @ %s\n' "$REPO_ROOT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── P1. Divergence from upstream — the WHOLE repo, not just the memory paths ────
# doctor.sh check 9 measures ahead/behind for the two memory paths only. It is
# structurally blind to db/migrations/, public/, app/ and bin/ — i.e. to every
# surface where two devs actually collide. This is that check, un-narrowed.
sec "P1 · upstream divergence"
if [ "$DO_FETCH" = 1 ]; then
  if git fetch --quiet "${UPSTREAM%%/*}" 2>/dev/null; then ok fetch "fetched ${UPSTREAM%%/*}"
  else warn fetch "git fetch failed (offline? tailnet down?) — divergence below may be stale"; fi
else
  warn fetch "--no-fetch: divergence measured against a possibly stale remote ref"
fi

if git rev-parse --verify --quiet "$UPSTREAM" >/dev/null; then
  BEHIND=$(git rev-list --count "HEAD..$UPSTREAM" 2>/dev/null || echo 0)
  AHEAD=$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)
  BR=$(git rev-parse --abbrev-ref HEAD)
  if [ "$BEHIND" -gt 0 ]; then
    stop behind "$BEHIND commit(s) on $UPSTREAM not in HEAD ($BR) — PULL before sequencing anything"
    # Name the other dev's work explicitly: 'behind' is abstract, a filename is not.
    OTHERS=$(git log --format='%an' "HEAD..$UPSTREAM" 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$OTHERS" ] && stop behind "  authors upstream you have not pulled: $OTHERS"
  else
    ok behind "HEAD contains all of $UPSTREAM"
  fi
  if [ "$AHEAD" -gt 0 ]; then
    # A push is NOT bounded by a pathspec: whatever sits here rides out with the
    # next push, including another session's commits. Enumerate, never count.
    warn ahead "$AHEAD local commit(s) not on $UPSTREAM — a push ships ALL of them:"
    git log --format='         %h %an %s' "$UPSTREAM..HEAD" 2>/dev/null | head -12 \
      | while IFS= read -r l; do [ "$DO_JSON" = 1 ] || printf '%s\n' "$l"; done
  else
    ok ahead "nothing unpushed"
  fi
else
  stop upstream "ref '$UPSTREAM' does not exist — cannot measure divergence"
fi

# Uncommitted work in the SHARED worktree, listed not counted.
DIRTY=$(git status --porcelain 2>/dev/null | head -30)
if [ -n "$DIRTY" ]; then
  N=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  warn dirty "$N uncommitted path(s) in the shared tree — diff any you did not touch:"
  [ "$DO_JSON" = 1 ] || printf '%s\n' "$DIRTY" | sed 's/^/         /' | head -12
else
  ok dirty "worktree clean"
fi

# ── P2. Migration queue — three-way: disk ↔ shared reference ↔ deploy target ────
# The migration runner applies the ENTIRE pending lot in lexical filename order,
# and a deploy makes the other dev's committed-but-unapplied migrations
# applicable. 'Pending 0' proves nothing: a status check enumerates the queue
# dir ON THE DEPLOY TARGET and never the shared reference ($UPSTREAM). The only
# measure that decides, in BOTH directions, is a diff.
sec "P2 · migration queue"
TMP="${TMPDIR:-/tmp}/pmpf.$$"; mkdir -p "$TMP" || exit 64
trap 'rm -rf "$TMP"' EXIT INT TERM

ls "$MIG_DIR"/*.sql 2>/dev/null | while IFS= read -r f; do basename "$f"; done | sort > "$TMP/disk"
git ls-tree "$UPSTREAM" "$MIG_DIR/" --name-only 2>/dev/null \
  | sed 's|.*/||' | grep '\.sql$' | sort > "$TMP/upstream"

ONLY_UP=$(comm -13 "$TMP/disk" "$TMP/upstream")
ONLY_DK=$(comm -23 "$TMP/disk" "$TMP/upstream")

if [ -n "$ONLY_UP" ]; then
  stop mig-upstream "migration(s) on $UPSTREAM and NOT on your disk — the next deploy by ANYONE arms them:"
  [ "$DO_JSON" = 1 ] || printf '%s\n' "$ONLY_UP" | sed 's/^/         /'
  # Whose are they? The initial in the filename is the only reliable attributor:
  # git blame lies for a queue dir (a staged file rides out in another
  # session's commit), and md5(local)==md5(shared ref)==md5(deploy target) is
  # the real proof. The capture regex and the env var it names are BOTH
  # profile-supplied (PF_QUEUE_AUTHOR_RE / DEV_ENV_VAR) — this kernel does not
  # know how many devs there are or what their initials look like.
  if [ "$DO_JSON" != 1 ] && [ -n "${QUEUE_AUTHOR_RE:-}" ]; then
    printf '%s\n' "$ONLY_UP" | sed -n "s/${QUEUE_AUTHOR_RE}.*/         → authored by ${DEV_ENV_VAR}=\\1/p" | sort -u
  fi
else
  ok mig-upstream "no migration on $UPSTREAM missing from disk"
fi

if [ -n "$ONLY_DK" ]; then
  warn mig-local "migration file(s) on disk and NOT on $UPSTREAM (unpushed, or another session's):"
  [ "$DO_JSON" = 1 ] || printf '%s\n' "$ONLY_DK" | sed 's/^/         /'
else
  ok mig-local "no unpushed migration files"
fi

# _draft: `next-migration.sh finalize` sweeps the WHOLE directory, so another
# session's draft gets stamped with your initial and lands untracked by git.
if [ -d "$DRAFT_DIR" ]; then
  DN=$(ls "$DRAFT_DIR"/*.sql 2>/dev/null | wc -l | tr -d ' ')
  if [ "$DN" -gt 0 ]; then
    warn mig-draft "$DN file(s) in $DRAFT_DIR — 'finalize' sweeps ALL of them; list before running it:"
    [ "$DO_JSON" = 1 ] || ls "$DRAFT_DIR"/*.sql 2>/dev/null | sed 's/^/         /'
  else ok mig-draft "_draft/ empty"; fi
else ok mig-draft "_draft/ absent (nothing staged)"; fi

if [ "$DO_PROBE" = 1 ]; then
  if VPSLS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
        "ls $VPS_PATH/$MIG_DIR/*.sql 2>/dev/null | xargs -n1 basename" 2>/dev/null); then
    printf '%s\n' "$VPSLS" | sort > "$TMP/vps"
    UP_NOT_VPS=$(comm -13 "$TMP/vps" "$TMP/upstream")
    VPS_NOT_UP=$(comm -23 "$TMP/vps" "$TMP/upstream")
    if [ -n "$UP_NOT_VPS" ]; then
      warn mig-vps "on $UPSTREAM, not yet on the VPS (a deploy arms them):"
      [ "$DO_JSON" = 1 ] || printf '%s\n' "$UP_NOT_VPS" | sed 's/^/         /'
    fi
    if [ -n "$VPS_NOT_UP" ]; then
      stop mig-vps "on the VPS and NOT on $UPSTREAM — prod has a migration git does not know about:"
      [ "$DO_JSON" = 1 ] || printf '%s\n' "$VPS_NOT_UP" | sed 's/^/         /'
    fi
    [ -z "$UP_NOT_VPS$VPS_NOT_UP" ] && ok mig-vps "VPS == $UPSTREAM for db/migrations/"
  else
    warn mig-vps "could not reach $SSH_TARGET — VPS side of the three-way diff NOT measured"
  fi
else
  warn mig-vps "--probe-db not given: the VPS leg is UNMEASURED ('Pending 0' would be an unproven claim)"
fi

# ── P3. Global-namespace collision for NEW migrations ──────────────────────────
# MySQL scopes FK *and* CHECK constraint names to the SCHEMA, not the table. A
# sandbox schema proves syntax and behaviour; it can NEVER prove uniqueness in a
# global namespace, because the colliding object is precisely what the sandbox
# left out (see profiles/*.conf §4 for a real-incident instance of this).
sec "P3 · global namespace (constraint / trigger / event names)"
CAND=""
if [ ${#MIGS[@]} -gt 0 ]; then
  CAND="${MIGS[@]+${MIGS[*]}}"
else
  # default candidate set: drafts + anything unpushed + anything uncommitted
  CAND="$(ls "$DRAFT_DIR"/*.sql 2>/dev/null; \
          printf '%s\n' "$ONLY_DK" | sed "s|^|$MIG_DIR/|" ; \
          git status --porcelain -- "$MIG_DIR" 2>/dev/null | awk '{print $NF}')"
fi
CAND=$(printf '%s\n' $CAND | grep '\.sql$' | sort -u)

if [ -z "$CAND" ]; then
  ok namespace "no new/edited migration to check"
else
  # Extract every name this file would CREATE in a schema-global namespace.
  : > "$TMP/names"
  for f in $CAND; do
    [ -f "$f" ] || continue
    grep -oiE 'CONSTRAINT[[:space:]]+`?[A-Za-z0-9_]+`?'      "$f" | awk '{print $NF}' | tr -d '`' >> "$TMP/names"
    grep -oiE 'CREATE[[:space:]]+TRIGGER[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" | awk '{print $NF}' | tr -d '`' >> "$TMP/names"
    grep -oiE 'CREATE[[:space:]]+EVENT[[:space:]]+`?[A-Za-z0-9_]+`?'   "$f" | awk '{print $NF}' | tr -d '`' >> "$TMP/names"
  done
  sort -u "$TMP/names" -o "$TMP/names"
  NN=$(wc -l < "$TMP/names" | tr -d ' ')

  if [ "$NN" = 0 ]; then
    ok namespace "candidate migration(s) declare no schema-global name"
  elif [ "$DO_PROBE" = 1 ] && [ -z "$NS_TAKEN_CMD" ]; then
    warn namespace "profile defines no namespace probe (PF_NS_TAKEN) — UNMEASURED, falling back to the repo-corpus lower bound"
    DO_PROBE=0
  elif [ "$DO_PROBE" = 1 ]; then
    # AUTHORITATIVE: the entire reach-the-real-schema command is profile-owned
    # (PF_NS_TAKEN / NS_TAKEN_CMD) — this kernel does not know how the project's
    # DB is bootstrapped, reached, or authenticated to.
    if TAKEN=$(eval "$NS_TAKEN_CMD" 2>/dev/null); then
      printf '%s\n' "$TAKEN" | sort -u > "$TMP/taken"
      HITS=$(comm -12 "$TMP/names" "$TMP/taken")
      if [ -n "$HITS" ]; then
        stop namespace "name(s) ALREADY TAKEN in schema '$DB_SCHEMA' — this migration will fail:"
        [ "$DO_JSON" = 1 ] || printf '%s\n' "$HITS" | sed 's/^/         /'
      else
        ok namespace "$NN declared name(s) verified free against the REAL schema"
      fi
    else
      warn namespace "live probe failed — falling back to the repo-corpus lower bound (see below)"
      DO_PROBE=0
    fi
  fi

  if [ "$DO_PROBE" = 0 ] && [ "$NN" -gt 0 ]; then
    # OFFLINE LOWER BOUND — explicitly NOT a proof. It greps every constraint name
    # ever declared in db/migrations/ (excluding the candidate files themselves).
    # It under-reports: objects created outside migrations, or renamed since, are
    # invisible. It never over-reports: a hit here is a real prior declaration.
    : > "$TMP/corpus"
    for f in "$MIG_DIR"/*.sql; do
      case " $CAND " in *" $f "*) continue ;; esac
      grep -oiE 'CONSTRAINT[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" 2>/dev/null | awk '{print $NF}' | tr -d '`' >> "$TMP/corpus"
    done
    sort -u "$TMP/corpus" -o "$TMP/corpus"
    HITS=$(comm -12 "$TMP/names" "$TMP/corpus")
    if [ -n "$HITS" ]; then
      stop namespace "name(s) already declared elsewhere in $MIG_DIR — collision (1826) is near-certain:"
      [ "$DO_JSON" = 1 ] || printf '%s\n' "$HITS" | sed 's/^/         /'
    else
      warn namespace "$NN name(s) clear of the repo corpus — this is a LOWER BOUND, not a proof. Re-run with --probe-db before applying."
    fi
  fi
fi

# ── P4. Migration slug ↔ created table names ───────────────────────────────────
# A build whose files say `retro-*` and whose tables say `crm_*` has drifted from
# what the PM recorded as planned, and nobody notices until someone greps the
# planned name and finds nothing. Five-line detector, catches it at write time.
sec "P4 · migration slug vs created objects"
if [ -n "$CAND" ]; then
  DRIFT=0
  for f in $CAND; do
    [ -f "$f" ] || continue
    B=$(basename "$f" .sql)
    SLUG=$(printf '%s' "$B" | sed 's/^[0-9]\{12\}_[kl]_//; s/[-_].*$//' | tr 'A-Z' 'a-z')
    TBLS=$(grep -oiE 'CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+`?[A-Za-z0-9_]+`?' "$f" \
           | awk '{print $NF}' | tr -d '`' | tr 'A-Z' 'a-z' | sort -u)
    [ -z "$TBLS" ] && continue
    for t in $TBLS; do
      case "$t" in "$SLUG"*|*"$SLUG"*) ;; *) DRIFT=1
        warn slug-drift "$(basename "$f"): slug '$SLUG' creates table '$t' — name the drift in the PM record" ;;
      esac
    done
  done
  [ "$DRIFT" = 0 ] && ok slug-drift "no slug/table divergence in candidate migrations"
else
  ok slug-drift "n/a"
fi

# ── P5. Ownership of the touched paths ─────────────────────────────────────────
sec "P5 · ownership"
if [ ! -f "$OWNERSHIP_MAP" ]; then
  warn ownership "$OWNERSHIP_MAP absent — ownership is prose only${OWNERSHIP_PROSE:+ ($OWNERSHIP_PROSE)}; no machine check possible"
else
  TOUCH="${PATHS[@]+${PATHS[*]}}"
  [ -z "$TOUCH" ] && TOUCH=$(git status --porcelain 2>/dev/null | awk '{print $NF}')
  if [ -z "$TOUCH" ]; then
    ok ownership "no touched paths given and worktree clean"
  else
    "$KIT_DIR/ownership-lint.sh" --map "$OWNERSHIP_MAP" --quiet $TOUCH
    case $? in
      0) ok ownership "all touched paths are within the acting dev's lane" ;;
      1) warn ownership "touched path(s) in a SHARED lane — run ownership-lint.sh for the list" ;;
      2) stop ownership "touched path(s) in the OTHER dev's lane or a FROZEN lane — see ownership-lint.sh" ;;
      *) warn ownership "ownership-lint.sh unavailable or errored" ;;
    esac
  fi
fi

# Shared tools carry environment-dependent constants. bin/deploy.sh has been
# patched by both devs on orthogonal axes (host address; GNU-vs-BSD portability)
# and neither could validate the other's environment. Touching one of these is a
# handoff event, not a commit.
TOUCHNOW=$(git status --porcelain 2>/dev/null | awk '{print $NF}')
for t in $SHARED_TOOLS; do
  case " $TOUCHNOW ${PATHS[@]+${PATHS[*]}} " in
    *" $t "*) warn shared-tool "$t is a SHARED TOOL — only one dev has ever exercised it in his environment. Open a handoff item BEFORE landing (H-<date>-<k|l>-<slug>), and state which OS/host/PHP you tested on." ;;
  esac
done

# ── P6. Arbitration queue — age computed from the ID, never from the column ────
# The register's escalation rule reads a hand-maintained '· N j' field. Measured
# 2026-08-05: 9 of 11 open items carried a stale age; eight had crossed the 7-day
# 🔴 threshold while reading "0 j". A detector keys on SILENCE, not on a status
# column somebody has to remember to write.
sec "P6 · arbitration queue (age recomputed, not read)"
if [ ! -f "$HANDOFF" ]; then
  warn arbitration "$HANDOFF not found"
else
  TODAY=$(date -u '+%Y%m%d')
  awk -v today="$TODAY" -v warnd="$ARB_WARN_DAYS" -v stopd="$ARB_STOP_DAYS" '
    function g(y,m,d,  a,yy,mm){a=int((14-m)/12);yy=y+4800-a;mm=m+12*a-3;
      return d+int((153*mm+2)/5)+365*yy+int(yy/4)-int(yy/100)+int(yy/400)-32045}
    /^### H-20/ {
      line=$0
      if (match(line,/H-[0-9]{8}-[kl]-[a-z0-9-]+/)) {
        id=substr(line,RSTART,RLENGTH)
        ds=substr(id,3,8)
        y=substr(ds,1,4)+0; m=substr(ds,5,2)+0; d=substr(ds,7,2)+0
        ty=substr(today,1,4)+0; tm=substr(today,5,2)+0; td=substr(today,7,2)+0
        age=g(ty,tm,td)-g(y,m,d)
        # ⛔ VOCABULAIRE DE CLÔTURE, DÉCLARÉ : « · CLOS » / « · RÉPONDU » /
        # « · CADUQUE », le mot COLLÉ au séparateur, tout ornement APRÈS.
        # 🔴 Même vocabulaire dans pm-kit/doctor.sh §12 (qui lit les CORPS, que
        # P6 ne lit pas) et dans les règles du routeur — 3 sites, à modifier
        # ensemble.
        # ⚠️ Aucune apostrophe ASCII dans ce bloc : il vit entre quotes simples
        # de shell, une apostrophe la FERME (erreur commise puis mesurée le 18-08).
        state = (line ~ /· *(CLOS|RÉPONDU|CADUQUE)/) ? "closed" : "open"
        # ⭐ « je n’ai pas compris » ne doit JAMAIS se lire « c’est ouvert ».
        # Un item CLOS hors gabarit continue de vieillir et pousse vers une
        # escalade `tsk_` (mail réel) d’une question déjà réglée — mesuré le
        # 14-08 : 1 en-tête sur 27, et c’était exactement celui-là.
        # Deux niveaux, gradués sur la CERTITUDE :
        #   HORS-GABARIT : « · » puis QUE de la décoration puis le mot
        #                  (« · ✅ CLOS », « · **CLOS** », « ·  ✅  RÉPONDU »).
        #                  Quasi-certain : la forme stricte a déjà échoué ici.
        #   SUSPECT      : mot de clôture ailleurs dans l’en-tête (p.ex. après
        #                  un tiret au lieu du « · »). Peut être de la prose
        #                  légitime dans un item ouvert ⇒ signalé, pas affirmé.
        if (state=="open") {
          if (line ~ /· *[^A-Za-z0-9]* *(CLOS|RÉPONDU|CADUQUE)/) badfmt[id]="HORS-GABARIT"
          else if (line ~ /(CLOS|RÉPONDU|CADUQUE)/)              badfmt[id]="SUSPECT"
        }
        decl=-1; if (match(line,/· *[0-9]+ j/)) { s=substr(line,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); decl=s+0 }
        if (state=="open") {
          lvl = (age>=stopd) ? "STOP" : ((age>=warnd) ? "WARN" : "ok")
          drift = (decl>=0 && decl!=age) ? sprintf(" [declared %dj — STALE]", decl) : ""
          if (id in badfmt) drift = drift " [" badfmt[id] "]"
          printf "%s\t%s\t%d\t%s\n", lvl, id, age, drift
        }
      }
    }
    END { for (i in badfmt) printf "FMT\t%s\t0\t%s\n", i, badfmt[i] | "sort" }' "$HANDOFF" > "$TMP/arb"

  if [ ! -s "$TMP/arb" ]; then
    ok arbitration "no open handoff items"
  else
    NSTOP=$(grep -c '^STOP' "$TMP/arb" 2>/dev/null || true); NSTOP=${NSTOP:-0}
    NWARN=$(grep -c '^WARN' "$TMP/arb" 2>/dev/null || true); NWARN=${NWARN:-0}
    NSTALE=$(grep -c 'STALE' "$TMP/arb" 2>/dev/null || true); NSTALE=${NSTALE:-0}
    while IFS="$(printf '\t')" read -r LVL ID AGE DRIFT; do
      case "$LVL" in
        STOP) warn arbitration "$ID — $AGE d open, past the ${ARB_STOP_DAYS}d escalation threshold$DRIFT" ;;
        WARN) warn arbitration "$ID — $AGE d open, name it in the recommendation$DRIFT" ;;
      esac
    done < "$TMP/arb"
    # ⭐ « Je ne sais pas lire cet en-tête » ne doit JAMAIS se rendre par le même
    # octet que « il est ouvert ». Agrégé en UNE ligne : la règle se répète mal,
    # et une instruction recopiée par item devient du papier peint.
    NFMT=$(grep -c '^FMT' "$TMP/arb" 2>/dev/null || true); NFMT=${NFMT:-0}
    if [ "${NFMT:-0}" -gt 0 ]; then
      FMTIDS=$(awk -F"\t" '$1=="FMT"{printf "%s(%s) ", $2, $4}' "$TMP/arb")
      warn arbitration "$NFMT en-tête(s) HORS VOCABULAIRE, comptés OUVERTS faute d'être lus : $FMTIDS— la clôture s'écrit « · CLOS » / « · RÉPONDU » / « · CADUQUE », le mot COLLÉ au « · », tout ornement APRÈS. HORS-GABARIT = ornement entre le « · » et le mot (quasi-certain) ; SUSPECT = mot de clôture ailleurs dans l'en-tête (peut être de la prose légitime)."
    fi
    [ "$NSTALE" -gt 0 ] && warn arbitration "$NSTALE item(s) carry a STALE declared age — the '· N j' field is decoration; delete it or generate it"
    [ "$NSTOP" -gt 0 ] && warn arbitration "$NSTOP item(s) need a human tsk_ escalation — ⛔ the PM must NOT create it (real mail, prod write)"
    ok arbitration "queue measured: $NSTOP overdue / $NWARN ageing"
  fi
fi

# Dead-but-live surface: an open scrapping item with an explicitly empty gate is
# a decision nobody scheduled, not a piece of debt. Surface it unprompted.
if [ -f "$SCRAPPING" ]; then
  NOGATE=$(grep -nE '^#[0-9]+ —.*(OUVERT|OPEN)' "$SCRAPPING" | grep -icE 'gate[^.]{0,30}(aucun|none)' 2>/dev/null || true); NOGATE=${NOGATE:-0}
  [ "${NOGATE:-0}" -gt 0 ] && warn dead-surface "$NOGATE open scrapping item(s) declare NO gate — they are unscheduled decisions, not debt. Name them."
fi

# ── P7. Memory-store health (delegate, don't reimplement) ──────────────────────
sec "P7 · PM memory"
if [ -x "$DOCTOR" ]; then
  DOUT=$("$DOCTOR" 2>/dev/null | grep -E 'WARN|FAIL' || true)
  if [ -n "$DOUT" ]; then
    [ "$DO_JSON" = 1 ] || printf '%s\n' "$DOUT" | sed 's/^/         /'
    printf '%s\n' "$DOUT" | grep -q FAIL && stop memory "doctor.sh reports FAIL — index over hard budget or dangling links"
    printf '%s\n' "$DOUT" | grep -q WARN && warn memory "doctor.sh warnings above — this is where the debt lives; '0 fail' ≠ 'in budget'"
  else
    ok memory "doctor.sh clean"
  fi
else
  warn memory "$DOCTOR not executable — memory health UNMEASURED"
fi

# ── P8. Artefact-keyed rails — recall by ADDRESS, not by association ───────────
# rails-index.sh mines the PM's always-read index into a TSV keyed on the
# named artefact each rail protects (table/file/column/symbol), transitively
# expanded over the view-dependency graph. This phase is the consumer: for
# every touched path/table, grep the TSV and print what it finds VERBATIM — a
# STOP-severity hit is exactly as blocking as any other STOP check in this
# tool, a WARN exactly as advisory. A missing TSV is never a clean pass: it is
# UNMEASURED, said as loudly as a failed probe anywhere else in this file.
sec "P8 · artefact-keyed rails"
if [ -z "$RAILS_TSV" ]; then
  warn rails "profile defines no PF_RAILS_OUTPUT — artefact-keyed rail lookup UNMEASURED"
elif [ ! -f "$RAILS_TSV" ]; then
  warn rails "$RAILS_TSV absent — UNMEASURED, not a clean pass. Run kernel/rails-index.sh (ideally with --refresh-graph at least once) before trusting this check."
else
  TOUCH8="${PATHS[@]+${PATHS[*]}}"
  [ -z "$TOUCH8" ] && TOUCH8=$(git status --porcelain 2>/dev/null | awk '{print $NF}')
  if [ -z "$TOUCH8" ]; then
    ok rails "no touched path/table given and worktree clean"
  else
    : > "$TMP/rails-cand"
    for P in $TOUCH8; do
      printf '%s\n' "$P" >> "$TMP/rails-cand"
      case "$P" in */*) basename "$P" >> "$TMP/rails-cand" ;; esac
    done
    sort -u "$TMP/rails-cand" -o "$TMP/rails-cand"
    HITN=0
    while IFS= read -r CAND; do
      [ -z "$CAND" ] && continue
      awk -F'\t' -v c="$CAND" '$1==c' "$RAILS_TSV" > "$TMP/rails-hit" 2>/dev/null
      [ -s "$TMP/rails-hit" ] || continue
      while IFS="$(printf '\t')" read -r ART SEV RAIL SRC ORIG; do
        [ -z "$ART" ] && continue
        HITN=$((HITN + 1))
        MSG="$ART [$ORIG] ($SRC): $RAIL"
        case "$SEV" in
          STOP) stop rails "$MSG" ;;
          WARN) warn rails "$MSG" ;;
          *)     ok rails "[$SEV] $MSG" ;;
        esac
      done < "$TMP/rails-hit"
    done < "$TMP/rails-cand"
    CAND_N=$(wc -l < "$TMP/rails-cand" | tr -d ' ')
    [ "$HITN" -eq 0 ] && ok rails "no rail keyed to any of the $CAND_N touched artefact(s)"
  fi
fi

# ── verdict ────────────────────────────────────────────────────────────────────
if [ "$DO_JSON" = 1 ]; then
  printf '{"rc":%d,"warn":%d,"stop":%d,"checks":[%s]}\n' "$RC" "$WARN_N" "$STOP_N" "${JSON_ROWS%,}"
else
  printf '\n'
  case "$RC" in
    0) printf '\033[32m● CLEAR\033[0m — no clash signal. Proceed.\n' ;;
    1) printf '\033[33m● PROCEED WITH NAMED WARNINGS (%d)\033[0m — the consult MUST name each one.\n' "$WARN_N" ;;
    2) printf '\033[31m● STOP (%d blocking)\033[0m — do not sequence this build. Resolve, or hand it to a human.\n' "$STOP_N" ;;
  esac
fi
exit "$RC"
