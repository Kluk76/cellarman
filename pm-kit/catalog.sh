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
# triggers = harvested from the file's own leading "> Trigger ..." blockquote lines; title = first "# " heading. loads/last_load come from the
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
# Started by another shell (zsh, sh)? These scripts use bash-only expansions
# (e.g. ${VAR:+-flag "$VAR"} word-splitting) — re-exec under bash, never degrade.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -u

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$KIT_DIR/../.." && pwd)"

# Canonical path, with a fallback for systems whose `realpath` is absent (older
# macOS) or lacks GNU options: follow symlinks with plain `readlink`, then
# resolve the directory with `pwd -P`. No `readlink -f`, no `realpath -q`.
_realpath() {
    local p="$1" l n=0 d
    if command -v realpath >/dev/null 2>&1 && realpath "$p" 2>/dev/null; then return 0; fi
    while [ -L "$p" ] && [ "$n" -lt 40 ]; do
        l="$(readlink "$p")" || return 1
        case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
        n=$((n + 1))
    done
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd -P)
    else
        d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
        printf '%s/%s\n' "$d" "$(basename "$p")"
    fi
}

MODE=gen
PATTERN=""
CONF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grep)  [ $# -ge 2 ] && [ -n "$2" ] || { echo "pm-catalog: --grep needs a pattern" >&2; exit 64; }
                 MODE=grep; PATTERN="$2"; shift 2 ;;
        --audit) MODE=audit; shift ;;
        *)       CONF="$1"; shift ;;
    esac
done
CONF="${CONF:-$KIT_DIR/../pm-kit.conf}"
[ -f "$CONF" ] || { echo "pm-catalog: conf not found: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

CATALOG="${PM_CATALOG:-$(dirname "$PM_INDEX")/pm-catalog.tsv}"
# A missing memory dir must be an error, not "-1 topic files" after a realpath
# failure that the pipeline below swallowed.
[ -d "${PM_MEMORY_DIR:-}" ] || { echo "pm-catalog: memory dir not found: ${PM_MEMORY_DIR:-<PM_MEMORY_DIR unset>}" >&2; exit 1; }
MEM_DIR="$(_realpath "$PM_MEMORY_DIR")" || { echo "pm-catalog: cannot resolve $PM_MEMORY_DIR" >&2; exit 1; }

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
        # where the house convention puts them). EVERY trigger line of the head
        # is kept, untruncated: the column is the --grep haystack, and a cap
        # here made later trigger lines and long ones unreachable by search
        # (display is shortened at print time instead — see the grep mode).
        head_block="$(head -c 6144 "$f")"
        triggers="$(printf '%s\n' "$head_block" \
            | grep -iE '^> .*trigger' \
            | sed 's/^> *//' | tr -d '*`' | tr '\n\t' '  ' | sed 's/ *$//')"
        title="$(printf '%s\n' "$head_block" \
            | grep -m1 '^# ' | sed 's/^# *//' | tr -d '*`' | tr '\t' ' ' | cut -c1-160)"
        # Exact first-column match through ENVIRON (no regex, no -P: BSD grep has
        # none, and its error was swallowed so every file read "loads:0").
        loadrow="$(REL="$rel" awk -F'\t' '$1 == ENVIRON["REL"] { print; exit }' "$LOADS_TMP")"
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
        # Display only: triggers longer than 400 chars print shortened with an
        # ellipsis; the match below always runs on the FULL column.
        # Match on the routing columns only (path, triggers, title) so byte
        # counts and dates can't produce false hits. The pattern is a POSIX
        # ERE matched case-insensitively as a SUBSTRING — alternation is plain
        # `chart|svg` (⛔ not `chart\|svg`: BRE-style escapes corrupt the
        # match). It reaches awk via ENVIRON, not -v: -v reprocesses backslash
        # escapes, printing a warning and then matching a DIFFERENT pattern
        # than the one given — a plausible-looking result over the wrong
        # population. Substring semantics mean short terms over-match
        # ("chart" hits "charter") — anchor when it matters.
        CATALOG_PAT="$PATTERN" awk -F'\t' '
            # cut_chars: the first n characters, never ending inside a UTF-8 character.
            # substr counts characters under gawk in a UTF-8 locale but BYTES under mawk
            # or LC_ALL=C, where a cut at byte n can leave the head of a multi-byte
            # character (invalid UTF-8 on screen); in byte mode an incomplete trailing
            # sequence is dropped.
            function cut_chars(s, n,   cut, len, i, need) {
                cut = substr(s, 1, n)
                if (length(ELL) == 1) return cut
                len = length(cut); i = len
                while (i > 0 && (substr(cut, i, 1) in CONT)) i--
                if (i > 0 && (substr(cut, i, 1) in LEAD)) {
                    need = LEAD[substr(cut, i, 1)]
                    if (len - i + 1 < need) cut = substr(cut, 1, i - 1)
                }
                return cut
            }
            BEGIN { pat = tolower(ENVIRON["CATALOG_PAT"]); ELL = "…"
                    for (b = 128; b < 192; b++) CONT[sprintf("%c", b)] = 1
                    for (b = 192; b < 224; b++) LEAD[sprintf("%c", b)] = 2
                    for (b = 224; b < 240; b++) LEAD[sprintf("%c", b)] = 3
                    for (b = 240; b < 248; b++) LEAD[sprintf("%c", b)] = 4 }
            NR==1 { next }
            tolower($1 FS $6 FS $7) ~ pat {
                trig = $6
                if (length(trig) > 400) trig = cut_chars(trig, 400) "…"
                printf "%s\t%sB\tloads:%s last:%s\n\t%s\n\t%s\n", $1, $2, $4, $5, $7, trig }' \
            "$CATALOG"
        ;;
    audit)
        echo "pm-catalog: files with NO harvestable trigger line (add a '> Trigger …' blockquote under the title):"
        awk -F'\t' 'NR>1 && $6=="" { printf "    %7dB  %s\n", $2, $1 }' "$CATALOG"
        N=$(awk -F'\t' 'NR>1 && $6=="" ' "$CATALOG" | wc -l)
        echo "pm-catalog: $N / $ROWS without triggers"
        ;;
esac
