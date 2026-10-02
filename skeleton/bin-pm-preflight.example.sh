#!/usr/bin/env bash
# Thin launcher — the stable entry point your PM calls. Portable kernel lives
# at claude-brain/pm-kit/kernel/pm-preflight.sh; this pins the repo root and
# forwards every argument untouched.
#
# Copy this file to <repo>/bin/pm-preflight.sh. It names NO profile: with
# exactly one claude-brain/pm-kit/profiles/*.conf the kernel finds it on its
# own. With several, select one per call (`--conf <path>`) or per shell
# (`PM_PROFILE=<name-or-path>`) — never by editing this file.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${PM_REPO_ROOT:=$ROOT}"; export PM_REPO_ROOT
exec "$ROOT/claude-brain/pm-kit/kernel/pm-preflight.sh" "$@"
