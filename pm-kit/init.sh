#!/usr/bin/env bash
# init.sh — install the kit into a repository: the README quickstart's copy and
# rename steps, for a given project name and developer initial.
#
#   <kit checkout>/pm-kit/init.sh --name <project> --dev <initial>
#                                 [--repo <dir>] [--dry-run] [--no-agent-install]
#
#   --name     project name: lowercase letters, digits and hyphens, starting with
#              a letter. It replaces "acme" in every template (agent
#              <name>-pm, memory directory <name>-pm-memory, profile
#              <name>.conf, session prefix "<name>-") and, upper-cased with
#              hyphens as underscores, the developer variable <NAME>_DEV.
#   --dev      the developer initial (lowercase letters and digits).
#   --repo     the repository to install into (default: the current directory;
#              it must be a git work tree). Run it from the root.
#   --dry-run  print what would be done, write nothing.
#   --no-agent-install
#              do not copy the agent file to ~/.claude/agents/ (the doctor
#              compares that copy with the one in the repository).
#
# WHAT IT WRITES (under <repo>; a path that already exists is never replaced)
#   claude-brain/pm-kit/                 the kit (profiles/<name>.conf included)
#   claude-brain/pm-kit.conf             paths and budgets
#   claude-brain/agents/<name>-pm.md     agent file: the kernel pasted between its markers
#   claude-brain/agents/<name>-pm-memory.md        the seed index
#   claude-brain/agents/<name>-pm-memory/          shipped-arcs register, handoff register
#   claude-brain/CLAIMS.tsv, claude-brain/OWNERSHIP.map   from the templates
#   claude-brain/pm-sync.sh, .claude/hooks/* (the .sh hooks and bash-guard.cases), .claude/settings.json
#   bin/pm-preflight.sh                  the launcher
#   docs/PLAN.md                         a placeholder plan document
#   ~/.claude/agents/<name>-pm.md        the installed copy of the agent file
# and it APPENDS, once, to .gitattributes, .gitignore and CLAUDE.md (skipped when
# the text is already there).
#
# IDEMPOTENT AND NON-DESTRUCTIVE. Before writing anything it checks every target:
# one that does not exist is created; one that exists with exactly the content
# this run would write is left alone ("unchanged"); one that exists with other
# content makes the whole run REFUSE (exit 2, nothing written, the files listed),
# because replacing it would destroy somebody's edits. So a second run is a no-op
# and a run after you edited the files never overwrites them.
#
# EXIT CODES  0 done (or dry run) · 2 refused: an existing file differs ·
#             3 did not run: bad arguments, not a git work tree, a template
#             missing from the kit checkout.
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"   # <kit checkout>/pm-kit
KIT_ROOT="$(cd "$KIT_DIR/.." && pwd -P)"                          # <kit checkout>

die() { echo "init.sh: NOT RUN — $*" >&2; exit 3; }

NAME=""; DEV=""; REPO="$(pwd)"; DRY=0; AGENT_INSTALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name) [ $# -ge 2 ] || die "--name needs a value"; NAME="$2"; shift 2 ;;
    --dev)  [ $# -ge 2 ] || die "--dev needs a value"; DEV="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-agent-install) AGENT_INSTALL=0; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{print;next} {exit}' "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

[ -n "$NAME" ] || die "--name <project> is required"
[ -n "$DEV" ]  || die "--dev <initial> is required"
# Explicit letters, not a range: in a UTF-8 locale a bash glob range follows the
# collation order, where the range a-z also matches A-Y (macOS bash 3.2 measured).
LOW=abcdefghijklmnopqrstuvwxyz
case "$NAME" in
  [$LOW]*) ;; *) die "--name '$NAME' must start with a lowercase letter" ;;
esac
case "$NAME" in
  *[!${LOW}0-9-]*) die "--name '$NAME' may contain only lowercase letters, digits and hyphens" ;;
esac
case "$DEV" in
  *[!${LOW}0-9]*) die "--dev '$DEV' may contain only lowercase letters and digits" ;;
esac
[ -d "$REPO" ] || die "--repo '$REPO' is not a directory"
REPO="$(cd "$REPO" && pwd -P)"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$REPO is not a git work tree (run git init first)"
[ "$(git -C "$REPO" rev-parse --show-toplevel)" = "$REPO" ] || die "$REPO is not the root of its repository (run it from the root, or pass --repo <root>)"

UPPER="$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')"
DEVVAR="${UPPER}_DEV"
AUTHOR="$(git -C "$REPO" config user.name 2>/dev/null)"; [ -n "$AUTHOR" ] || AUTHOR="$DEV"
# the name goes into a sed replacement and a regex: keep it to harmless characters
AUTHOR="$(printf '%s' "$AUTHOR" | tr -c 'A-Za-z0-9 ._-' '_')"

# Every template this run reads must exist in the kit checkout.
for t in pm-kit/PROTOCOL.md pm-kit/doctor.sh profiles/example.conf pm-kit.conf.example \
         skeleton/bin-pm-preflight.example.sh skeleton/index-seed.md skeleton/dev-handoff-register.example.md \
         skeleton/CLAIMS.tsv.example skeleton/OWNERSHIP.map.example skeleton/gitattributes.example \
         skeleton/gitignore.example skeleton/agent-example.md skeleton/CLAUDE.md.snippet \
         skeleton/pm-sync.example.sh skeleton/settings.example.json skeleton/hooks; do
  [ -e "$KIT_ROOT/$t" ] || die "template '$t' is missing from the kit checkout at $KIT_ROOT"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pm-init.XXXXXX")" || die "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT INT TERM

# rename <file>: the template with acme -> name, ACME -> NAME (upper-cased).
rename() { sed "s/ACME/${UPPER}/g; s/acme/${NAME}/g" "$1"; }

# ── build the whole tree to write in $TMP/stage, then compare, then write ─────
STAGE="$TMP/stage"; mkdir -p "$STAGE"
put() { mkdir -p "$(dirname "$STAGE/$1")"; cat > "$STAGE/$1"; }   # put <repo-relative path> < content

# the kit itself, with the profile renamed and the dev set
mkdir -p "$STAGE/claude-brain"
cp -R "$KIT_DIR" "$STAGE/claude-brain/pm-kit"
rm -rf "$STAGE/claude-brain/pm-kit/state"
mkdir -p "$STAGE/claude-brain/pm-kit/profiles"
# One developer: DEVS, DEV_<id>, and the initial in the author/id patterns. [a-z]
# keeps the id and queue patterns tolerant if a second developer joins later.
# The example profile declares a migrations queue, a deploy host, a database probe
# and a view graph that a new project does not have. Declaring a host that does not
# exist would make `--probe-db` ssh to it, so those variables start EMPTY (n/a: the
# phase measures nothing and says so). The kit's own profiles/example.conf shows
# them filled in; copy a line back when you have the thing it describes.
EMPTIED="PF_QUEUE_DIR PF_QUEUE_STAGING PF_QUEUE_TARGET PF_DB_SCHEMA PF_NS_TAKEN PF_TARGET_HOST PF_TARGET_PATH PF_ARTEFACT_EXPAND PF_ARTEFACT_GRAPH_CACHE PF_OWNERSHIP_PROSE PF_SHARED_TOOLS PF_DEBT_FILE"
rename "$KIT_ROOT/profiles/example.conf" \
  | sed -e "s/^DEVS=.*/DEVS=\"$DEV\"/" \
        -e "/^DEV_a=/d" \
        -e "s/^DEV_b=.*/DEV_${DEV}=\"${AUTHOR}|^${AUTHOR}\$\"/" \
        -e "s/\[ab\]/[a-z]/g" \
  | awk -v vars="$EMPTIED" '
      BEGIN { n = split(vars, v, " ") }
      { for (i = 1; i <= n; i++)
          if (index($0, v[i] "=") == 1) { print v[i] "=\"\"   # not declared by init.sh: see profiles/example.conf in the kit"; next }
        print }' \
  | put "claude-brain/pm-kit/profiles/${NAME}.conf"
rename "$KIT_ROOT/pm-kit.conf.example" | put "claude-brain/pm-kit.conf"
cp "$KIT_ROOT/skeleton/bin-pm-preflight.example.sh" "$TMP/launcher"; put "bin/pm-preflight.sh" < "$TMP/launcher"
rename "$KIT_ROOT/skeleton/index-seed.md" | put "claude-brain/agents/${NAME}-pm-memory.md"
printf '# Shipped arcs register\n' | put "claude-brain/agents/${NAME}-pm-memory/shipped-arcs-register.md"
rename "$KIT_ROOT/skeleton/dev-handoff-register.example.md" | put "claude-brain/agents/${NAME}-pm-memory/dev-handoff-register.md"
put "claude-brain/CLAIMS.tsv" < "$KIT_ROOT/skeleton/CLAIMS.tsv.example"
# The template's header (how to write lanes) without its fictional example lanes,
# and one catch-all: a solo start owns everything, so the pre-flight does not report
# every path as an unmapped lane. Replace it with real lanes when a second
# developer joins.
{ awk '/^# EXAMPLE/{exit} {print}' "$KIT_ROOT/skeleton/OWNERSHIP.map.example"
  printf '# Solo start (written by init.sh): the initial below owns every path at every\n# concern. Replace this line with real lanes when a second developer joins.\n'
  printf 'own   %s  *  *\n' "$DEV"; } | put "claude-brain/OWNERSHIP.map"
printf '# Plan\n\n### P-1 First thing\nGoal: ...\nAcceptance: ...\n' | put "docs/PLAN.md"
cp "$KIT_ROOT/skeleton/pm-sync.example.sh" "$TMP/pmsync"; put "claude-brain/pm-sync.sh" < "$TMP/pmsync"
for h in "$KIT_ROOT"/skeleton/hooks/*.sh "$KIT_ROOT"/skeleton/hooks/*.cases; do rename "$h" | put ".claude/hooks/$(basename "$h")"; done
rename "$KIT_ROOT/skeleton/settings.example.json" | put ".claude/settings.json"

# the agent file: the template with the kernel pasted between its two markers
awk '/^<!-- cellarman kernel: begin/{k=1} k; /^<!-- cellarman kernel: end/{k=0}' "$KIT_ROOT/pm-kit/PROTOCOL.md" > "$TMP/kernel.md"
[ -s "$TMP/kernel.md" ] || die "no kernel block found in $KIT_ROOT/pm-kit/PROTOCOL.md"
awk -v kf="$TMP/kernel.md" '
  /^<!-- cellarman kernel: begin/ { while ((getline l < kf) > 0) print l; skip=1; next }
  /^<!-- cellarman kernel: end/   { skip=0; next }
  !skip' "$KIT_ROOT/skeleton/agent-example.md" | sed "s/ACME/${UPPER}/g; s/acme/${NAME}/g" \
  | put "claude-brain/agents/${NAME}-pm.md"

# ── plan: classify every staged file ──────────────────────────────────────────
NEW=""; SAME=""; DIFF=""
while IFS= read -r rel; do
  rel="${rel#./}"
  if [ ! -e "$REPO/$rel" ]; then NEW="$NEW$rel"$'\n'
  elif cmp -s "$STAGE/$rel" "$REPO/$rel"; then SAME="$SAME$rel"$'\n'
  else DIFF="$DIFF$rel"$'\n'; fi
done < <(cd "$STAGE" && find . -type f | sort)

# the installed copy of the agent file (outside the repository)
AGENT_HOME_REL=".claude/agents/${NAME}-pm.md"
AGENT_HOME="${HOME:-}/$AGENT_HOME_REL"
AGENT_HOME_STATE=skip
if [ "$AGENT_INSTALL" = 1 ] && [ -n "${HOME:-}" ]; then
  if [ ! -e "$AGENT_HOME" ]; then AGENT_HOME_STATE=new
  elif cmp -s "$STAGE/claude-brain/agents/${NAME}-pm.md" "$AGENT_HOME"; then AGENT_HOME_STATE=same
  else AGENT_HOME_STATE="diff"; DIFF="$DIFF~/$AGENT_HOME_REL"$'\n'; fi
fi

if [ -n "$DIFF" ]; then
  echo "init.sh: REFUSED — these files already exist with different content, and replacing them would destroy edits:" >&2
  printf '%s' "$DIFF" | sed 's/^/  /' >&2
  echo "init.sh: nothing was written. Move or delete them (or merge by hand) and run again." >&2
  exit 2
fi

# appends: text blocks added once to files that may already exist
GA_LINE="$(grep -v '^#' "$KIT_ROOT/skeleton/gitattributes.example" | grep -v '^[[:space:]]*$' | head -1)"
GI_MARK="claude-brain/agents/.pm-load-log.tsv"
SNIP_MARK="## Project manager"
append_state() { # file marker -> new|have
  if [ -f "$REPO/$1" ] && grep -qF -- "$2" "$REPO/$1"; then echo have; else echo new; fi
}
GA_STATE="$(append_state .gitattributes "$GA_LINE")"
GI_STATE="$(append_state .gitignore "$GI_MARK")"
SN_STATE="$(append_state CLAUDE.md "$SNIP_MARK")"

# ── report, and write unless --dry-run ────────────────────────────────────────
say_list() { [ -n "$2" ] && { printf '%s' "$2" | sed "s/^/  $1 /"; }; return 0; }
if [ "$DRY" = 1 ]; then echo "init.sh --dry-run: nothing will be written. Plan for $REPO (project '$NAME', developer '$DEV', variable $DEVVAR):"
else echo "init.sh: installing into $REPO (project '$NAME', developer '$DEV', variable $DEVVAR)"; fi
say_list "create   " "$NEW"
say_list "unchanged" "$SAME"
case "$AGENT_HOME_STATE" in
  new)  echo "  create    ~/$AGENT_HOME_REL" ;;
  same) echo "  unchanged ~/$AGENT_HOME_REL" ;;
  skip) echo "  skipped   ~/$AGENT_HOME_REL (--no-agent-install)" ;;
esac
[ "$GA_STATE" = new ] && echo "  append    .gitattributes (merge=union for the claims file)" || echo "  unchanged .gitattributes (already carries it)"
[ "$GI_STATE" = new ] && echo "  append    .gitignore (derived and per-machine artefacts)" || echo "  unchanged .gitignore (already carries them)"
[ "$SN_STATE" = new ] && echo "  append    CLAUDE.md (the consultation rule)" || echo "  unchanged CLAUDE.md (already carries it)"

if [ "$DRY" = 1 ]; then exit 0; fi

# Write only what is new. A write failure stops the run and says what is on disk.
WROTE=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  mkdir -p "$REPO/$(dirname "$rel")" && cp "$STAGE/$rel" "$REPO/$rel" || { echo "init.sh: FAILED writing $rel (earlier files are already on disk)" >&2; exit 1; }
  [ -x "$STAGE/$rel" ] && chmod +x "$REPO/$rel"
  WROTE=$((WROTE+1))
done <<EOF_NEW
$NEW
EOF_NEW
# executable bits: the staged copies keep the template modes through cp -R / cat; fix the ones made by put()
for rel in bin/pm-preflight.sh claude-brain/pm-sync.sh; do [ -f "$REPO/$rel" ] && chmod +x "$REPO/$rel"; done
for h in "$REPO"/.claude/hooks/*.sh; do [ -f "$h" ] && chmod +x "$h"; done
chmod +x "$REPO"/claude-brain/pm-kit/*.sh "$REPO"/claude-brain/pm-kit/kernel/*.sh 2>/dev/null

if [ "$AGENT_HOME_STATE" = new ]; then
  mkdir -p "$(dirname "$AGENT_HOME")" && cp "$STAGE/claude-brain/agents/${NAME}-pm.md" "$AGENT_HOME" \
    || { echo "init.sh: FAILED writing $AGENT_HOME" >&2; exit 1; }
fi
if [ "$GA_STATE" = new ]; then
  # shellcheck disable=SC2094  # the last-byte probe reads the file before the append, never concurrently
  { [ -s "$REPO/.gitattributes" ] && [ "$(tail -c 1 "$REPO/.gitattributes" | od -An -tx1 | tr -d ' \n')" != 0a ] && printf '\n'
    cat "$KIT_ROOT/skeleton/gitattributes.example"; } >> "$REPO/.gitattributes"
fi
if [ "$GI_STATE" = new ]; then
  # shellcheck disable=SC2094  # the last-byte probe reads the file before the append, never concurrently
  { [ -s "$REPO/.gitignore" ] && [ "$(tail -c 1 "$REPO/.gitignore" | od -An -tx1 | tr -d ' \n')" != 0a ] && printf '\n'
    cat "$KIT_ROOT/skeleton/gitignore.example"; } >> "$REPO/.gitignore"
fi
if [ "$SN_STATE" = new ]; then
  # the snippet without its leading comment block, with the agent name filled in
  # shellcheck disable=SC2094  # the emptiness probe reads the file before the append, never concurrently
  { [ -s "$REPO/CLAUDE.md" ] && printf '\n'
    awk '/^<!--/{c=1} !c{print} /-->/{if(c){c=0; skip_blank=1}}' "$KIT_ROOT/skeleton/CLAUDE.md.snippet" | sed '/./,$!d' | sed "s/acme-pm/${NAME}-pm/g"; } >> "$REPO/CLAUDE.md"
fi

echo "init.sh: done ($WROTE file(s) created)."
echo "Next: export $DEVVAR=$DEV; then bin/pm-preflight.sh and claude-brain/pm-kit/doctor.sh --strict (see the README, Quickstart)."
exit 0
