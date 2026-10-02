#!/usr/bin/env bash
# Thin launcher: the stable entry point your PM calls. The portable kernel
# lives at claude-brain/pm-kit/kernel/pm-preflight.sh; this pins the repo root
# and forwards every argument untouched.
#
# Copy this file to <repo>/bin/pm-preflight.sh. It names NO profile: with
# exactly one claude-brain/pm-kit/profiles/*.conf the kernel finds it on its
# own. With several, select one per call (`--conf <path>`) or per shell
# (`PM_PROFILE=<name-or-path>`), never by editing this file.
#
# EXIT CODES (the kernel's, passed through unchanged)
#   0 clear · 1 warnings · 2 STOP · 3 did not run (nothing was measured:
#   no profile, bad arguments, a missing tool, or, from this launcher, the
#   kernel script not being where it should be). 0, 1 and 2 are verdicts;
#   any other code means there is no verdict.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/claude-brain/pm-kit/kernel/pm-preflight.sh"
[ -f "$KERNEL" ] || { echo "pm-preflight: NOT RUN — kernel not found at $KERNEL (the kit must be installed at claude-brain/pm-kit/)" >&2; exit 3; }
: "${PM_REPO_ROOT:=$ROOT}"; export PM_REPO_ROOT
exec "$KERNEL" "$@"
