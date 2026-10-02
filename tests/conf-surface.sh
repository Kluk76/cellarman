#!/usr/bin/env bash
# tests/conf-surface.sh — does the example profile say what the scripts read?
#
#   conf-surface.sh [--conf <profile>] [--kit <kit root>]
#
# Two violations, both exit 1:
#   UNREAD <name>        a variable ASSIGNED in the profile that no profile-reading
#                        script reads, and that is not inside the block
#                        "--- agent-read: begin ---" ... "--- agent-read: end ---"
#                        (the section for variables the PM agent itself reads).
#   UNDOCUMENTED <name>  a PF_*, PM_* or DOMAIN_* name a profile-reading script
#                        reads (on a non-comment line) that appears nowhere in
#                        the profile, neither assigned nor in a comment.
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
KIT="$(cd "$HERE/.." && pwd)"; CONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --conf) CONF="$2"; shift 2 ;;
    --kit)  KIT="$2"; shift 2 ;;
    *) echo "conf-surface: unknown argument '$1'" >&2; exit 3 ;;
  esac
done
[ -n "$CONF" ] || CONF="$KIT/profiles/example.conf"
[ -f "$CONF" ] || { echo "conf-surface: NOT RUN — no profile at $CONF" >&2; exit 3; }
[ -d "$KIT/pm-kit/kernel" ] || { echo "conf-surface: NOT RUN — no kit at $KIT" >&2; exit 3; }

T="$(mktemp -d "${TMPDIR:-/tmp}/conf-surface.XXXXXX")" || exit 3
trap 'rm -rf "$T"' EXIT INT TERM

# Code of the profile readers, comment-only lines removed.
for f in pm-kit/kernel/pm-preflight.sh pm-kit/kernel/ownership-lint.sh pm-kit/kernel/rails-index.sh \
         pm-kit/kernel/claim.sh pm-kit/lint-claims-session.sh; do
  [ -f "$KIT/$f" ] || { echo "conf-surface: NOT RUN — $KIT/$f is missing" >&2; exit 3; }
  grep -vE '^[[:space:]]*#' "$KIT/$f"
done > "$T/code"
grep -oE '_prof [A-Z][A-Z0-9_]*' "$KIT/pm-kit/doctor.sh" | awk '{print $2}' >> "$T/code"

# Variables assigned in the profile, outside comments and outside the agent-read
# block. Several assignments on one line (separated by ;) are all taken.
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
    } }' "$CONF" | sort -u > "$T/assigned"

bad=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  if grep -qE "(^|[^A-Za-z0-9_])${v}([^A-Za-z0-9_]|\$)" "$T/code"; then continue; fi
  # a family expanded by prefix, e.g. DEV_${D}
  case "$v" in
    *_*) pre="${v%_*}_"
         if grep -qF "${pre}\${" "$T/code"; then continue; fi ;;
  esac
  echo "UNREAD $v"; bad=1
done < "$T/assigned"

# Names the readers use that the profile never mentions.
grep -oE '(PF|PM|DOMAIN)_[A-Za-z0-9_]*[A-Za-z0-9]' "$T/code" | sort -u | while IFS= read -r t; do
  grep -qE "(^|[^A-Za-z0-9_])${t}([^A-Za-z0-9_]|\$)" "$CONF" || echo "UNDOCUMENTED $t"
done > "$T/undoc"
if [ -s "$T/undoc" ]; then cat "$T/undoc"; bad=1; fi

if [ "$bad" = 0 ]; then
  echo "conf-surface: OK ($(wc -l < "$T/assigned" | tr -d ' ') variables, every one read; every read name documented)"
fi
exit "$bad"
