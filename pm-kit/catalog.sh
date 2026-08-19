#!/usr/bin/env bash
# pm-kit/catalog.sh — the card catalog of the PM topic corpus.
#
# Why it exists: the always-read index is byte-budgeted, so it cannot carry a
# routing line for every topic file — but "a file absent from the router is NOT
# a file absent from memory". This script gives the PM an O(1)-context way to
# find the right file: regenerate the catalog (sub-second, always fresh, never
# stale) and grep it, instead of growing the index or reading files whole.
#
# One TSV row per topic file:
#   path <TAB> bytes <TAB> mtime <TAB> loads <TAB> last_load <TAB> triggers <TAB> title
# triggers = harvested from the file's own leading "> Trigger …" / "> Déclencheur …"
# blockquote lines; title = first "# " heading. loads/last_load come from the
# per-machine telemetry log (mechanical, not self-reported).
#
# Usage:
#   catalog.sh                  regenerate, print catalog path + row count
#   catalog.sh --grep <ere>     regenerate, then match rows — case-insensitive
#                               POSIX ERE, substring; alternation = `a|b`
#   catalog.sh --audit          regenerate, list files with NO harvestable
#                               trigger line (poor routability — fix at source)
#
# Generic: zero project knowledge; everything comes from pm-kit.conf.
# The catalog is DERIVED + per-machine (it embeds telemetry) — gitignore it.
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"

MODE=gen
PATTERN=""
CONF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grep)  MODE=grep; PATTERN="${2:-}"; shift 2 ;;
        --audit) MODE=audit; shift ;;
        *)       CONF="$1"; shift ;;
    esac
done
CONF="${CONF:-$KIT_DIR/../pm-kit.conf}"
[ -f "$CONF" ] || { echo "pm-catalog: conf not found: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

CATALOG="${PM_CATALOG:-$(dirname "$PM_INDEX")/pm-catalog.tsv}"
MEM_DIR="$(realpath "$PM_MEMORY_DIR")"

# Pre-aggregate the load log once: relpath -> "count \t last-date".
LOADS_TMP="$(mktemp)"
trap 'rm -f "$LOADS_TMP"' EXIT
if [ -f "${PM_LOAD_LOG:-/nonexistent}" ]; then
    awk -F'\t' '{ n[$2]++; if ($1 > d[$2]) d[$2] = $1 }
                END { for (k in n) printf "%s\t%d\t%s\n", k, n[k], d[k] }' \
        "$PM_LOAD_LOG" > "$LOADS_TMP"
fi

{
    printf 'path\tbytes\tmtime\tloads\tlast_load\ttriggers\ttitle\n'
    find "$MEM_DIR" -type f -name '*.md' | LC_ALL=C sort | while IFS= read -r f; do
        rel="${f#"$MEM_DIR"/}"
        bytes=$(wc -c < "$f")
        mtime=$(date -r "$f" +%F)
        # Harvest routing signals from the file head only (cheap, and that is
        # where the house convention puts them).
        head_block="$(head -c 6144 "$f")"
        triggers="$(printf '%s\n' "$head_block" \
            | grep -iE '^> .*(trig(ger)?|déclench)' | head -3 \
            | sed 's/^> *//' | tr -d '*`' | tr '\n\t' '  ' | cut -c1-400)"
        title="$(printf '%s\n' "$head_block" \
            | grep -m1 '^# ' | sed 's/^# *//' | tr -d '*`' | tr '\t' ' ' | cut -c1-160)"
        loadrow="$(grep -m1 -P "^\Q$rel\E\t" "$LOADS_TMP" 2>/dev/null || true)"
        if [ -n "$loadrow" ]; then
            loads="$(printf '%s' "$loadrow" | cut -f2)"
            last="$(printf '%s' "$loadrow" | cut -f3)"
        else
            loads=0; last='-'
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$rel" "$bytes" "$mtime" "$loads" "$last" "$triggers" "$title"
    done
} > "$CATALOG"

ROWS=$(( $(wc -l < "$CATALOG") - 1 ))

case "$MODE" in
    gen)
        echo "pm-catalog: $ROWS topic files -> $CATALOG"
        ;;
    grep)
        [ -n "$PATTERN" ] || { echo "pm-catalog: --grep needs a pattern" >&2; exit 1; }
        # Match on the routing columns only (path, triggers, title) so byte
        # counts and dates can't produce false hits. The pattern is a POSIX
        # ERE matched case-insensitively as a SUBSTRING — alternation is plain
        # `chart|svg` (⛔ not `chart\|svg`: BRE-style escapes corrupt the
        # match). It reaches awk via ENVIRON, not -v: -v reprocesses backslash
        # escapes, printing a warning and then matching a DIFFERENT pattern
        # than the one given — a plausible-looking result over the wrong
        # population. Substring semantics mean short terms over-match
        # ("chart" hits "charter") — anchor when it matters.
        PM_CATALOG_PAT="$PATTERN" awk -F'\t' '
            BEGIN { pat = tolower(ENVIRON["PM_CATALOG_PAT"]) }
            NR==1 { next }
            tolower($1 FS $6 FS $7) ~ pat {
                printf "%s\t%sB\tloads:%s last:%s\n\t%s\n\t%s\n", $1, $2, $4, $5, $7, $6 }' \
            "$CATALOG"
        ;;
    audit)
        echo "pm-catalog: files with NO harvestable trigger line (add a '> Trigger …' blockquote under the title):"
        awk -F'\t' 'NR>1 && $6=="" { printf "    %7dB  %s\n", $2, $1 }' "$CATALOG"
        N=$(awk -F'\t' 'NR>1 && $6=="" ' "$CATALOG" | wc -l)
        echo "pm-catalog: $N / $ROWS without triggers"
        ;;
esac
