#!/usr/bin/env bash
# tests/conf-surface.sh — does the example profile say what the scripts read?
#
#   conf-surface.sh [--conf <profile>] [--kitconf <pm-kit.conf example>] [--kit <kit root>]
#
# Two violations, both exit 1:
#   UNREAD <name>        a variable ASSIGNED in the profile that no profile-reading
#                        script reads, and that is not inside the block
#                        "--- agent-read: begin ---" ... "--- agent-read: end ---"
#                        (the section for variables the PM agent itself reads).
#   UNDOCUMENTED <name>  a PF_*, PM_* or DOMAIN_* name a profile-reading script
#                        reads (on a non-comment line) that appears nowhere in
#                        the profile, neither assigned nor in a comment.
# The same two rules are applied to pm-kit.conf.example and the scripts that read
# pm-kit.conf (doctor.sh except its `_prof` names, catalog.sh, load-telemetry.sh,
# session-ledger.sh, pm-sync, the two example hooks); a name there counts as
# documented when either example file mentions it.
# Exit 0: the two agree. Exit 3: it could not run (missing conf or kit).
#
# Profile readers: kernel/pm-preflight.sh, kernel/ownership-lint.sh,
# kernel/rails-index.sh, kernel/claim.sh, lint-claims-session.sh, plus the names
# doctor.sh asks for with `_prof NAME` (doctor sources pm-kit.conf, not the
# profile, so its other names do not count). A family such as DEV_<id> counts as
# read when a script expands it by prefix (`DEV_${...}`).
#
# This file is the reader of record: tests/smoke.sh runs it on the shipped tree
# (must pass) and on fixtures that break each rule (must fail).
set -u
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"; CONF=""; KITCONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) CONF="$2"; shift 2 ;;
    --kitconf) KITCONF="$2"; shift 2 ;;
    --kit)  KIT="$2"; shift 2 ;;
    *) echo "conf-surface: unknown argument '$1'" >&2; exit 3 ;;
  esac
done
[ -n "$CONF" ] || CONF="$KIT/profiles/example.conf"
[ -n "$KITCONF" ] || KITCONF="$KIT/pm-kit.conf.example"
[ -f "$CONF" ] || { echo "conf-surface: NOT RUN — no profile at $CONF" >&2; exit 3; }
[ -f "$KITCONF" ] || { echo "conf-surface: NOT RUN — no pm-kit.conf example at $KITCONF" >&2; exit 3; }
[ -d "$KIT/pm-kit/kernel" ] || { echo "conf-surface: NOT RUN — no kit at $KIT" >&2; exit 3; }

T="$(mktemp -d "${TMPDIR:-/tmp}/conf-surface.XXXXXX")" || exit 3
trap 'rm -rf "$T"' EXIT INT TERM

# code_of <file>...: the files' code, comment-only lines removed.
code_of() {
  local f
  for f in "$@"; do
    [ -f "$KIT/$f" ] || { echo "conf-surface: NOT RUN — $KIT/$f is missing" >&2; exit 3; }
    grep -vE '^[[:space:]]*#' "$KIT/$f"
  done
}

# assigned_in <conf>: variables assigned outside comments and outside the
# agent-read block. Several assignments on one line (separated by ;) are all taken.
assigned_in() {
  awk '
    /--- agent-read: begin ---/ { skip = 1; next }
    /--- agent-read: end ---/   { skip = 0; next }
    skip { next }
    /^[[:space:]]*#/ { next }
    { line = $0
      while (match(line, /(^|;[[:space:]]*)[A-Za-z_][A-Za-z0-9_]*=/)) {
        s = substr(line, RSTART, RLENGTH); sub(/^;[[:space:]]*/, "", s); sub(/=$/, "", s)
        print s
        line = substr(line, RSTART + RLENGTH)
      } }' "$1" | sort -u
}

bad=0
# surface <label> <conf> <code file> <doc file>...
surface() {
  local label="$1" conf="$2" code="$3" v pre t d found; shift 3
  assigned_in "$conf" > "$T/assigned"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if grep -qE "(^|[^A-Za-z0-9_])${v}([^A-Za-z0-9_]|\$)" "$code"; then continue; fi
    case "$v" in   # a family expanded by prefix, e.g. DEV_${D}
      *_*) pre="${v%_*}_"; if grep -qF "${pre}\${" "$code"; then continue; fi ;;
    esac
    echo "UNREAD $v   ($label)"; bad=1
  done < "$T/assigned"
  grep -oE '(PF|PM|DOMAIN)_[A-Za-z0-9_]*[A-Za-z0-9]' "$code" | sort -u > "$T/names"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    found=0
    for d in "$@"; do
      grep -qE "(^|[^A-Za-z0-9_])${t}([^A-Za-z0-9_]|\$)" "$d" && { found=1; break; }
    done
    [ "$found" = 1 ] || { echo "UNDOCUMENTED $t   ($label)"; bad=1; }
  done < "$T/names"
  wc -l < "$T/assigned" | tr -d ' ' > "$T/n.$label"
}

# Profile readers (doctor.sh contributes only the names it asks for with `_prof`).
{ code_of pm-kit/kernel/pm-preflight.sh pm-kit/kernel/ownership-lint.sh pm-kit/kernel/rails-index.sh \
          pm-kit/kernel/claim.sh pm-kit/lint-claims-session.sh
  grep -oE '_prof [A-Z][A-Z0-9_]*' "$KIT/pm-kit/doctor.sh" | awk '{print $2}'; } > "$T/code-profile"
surface profile "$CONF" "$T/code-profile" "$CONF"

# pm-kit.conf readers.
code_of pm-kit/doctor.sh pm-kit/catalog.sh pm-kit/load-telemetry.sh pm-kit/kernel/session-ledger.sh \
        skeleton/pm-sync.example.sh skeleton/hooks/pm-report-back-gate.sh skeleton/hooks/pm-consult-nudge.sh > "$T/code-kitconf"
# doctor.sh also expands PF_* names, but only through `_prof`; drop them from this side.
grep -vE '(PF)_' "$T/code-kitconf" > "$T/code-kitconf2" || true
surface pm-kit.conf "$KITCONF" "$T/code-kitconf2" "$KITCONF" "$CONF"

if [ "$bad" = 0 ]; then
  echo "conf-surface: OK (profile: $(cat "$T/n.profile") variables, pm-kit.conf: $(cat "$T/n.pm-kit.conf"); every one read, every read name documented)"
fi
exit "$bad"
