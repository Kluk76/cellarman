#!/usr/bin/env bash
# Thin launcher — the stable entry point your PM calls. Portable kernel lives
# at claude-brain/pm-kit/kernel/pm-preflight.sh; this just wires it to YOUR
# profile and forwards every argument untouched.
#
# Copy this file to <repo>/bin/pm-preflight.sh and replace "example" below
# with your profile's filename (claude-brain/pm-kit/profiles/<name>.conf).
exec "$(cd "$(dirname "$0")/.." && pwd)/claude-brain/pm-kit/kernel/pm-preflight.sh" --conf "$(cd "$(dirname "$0")/.." && pwd)/claude-brain/pm-kit/profiles/example.conf" "$@"
