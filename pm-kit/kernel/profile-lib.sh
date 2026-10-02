#!/usr/bin/env bash
# profile-lib.sh — shared helpers for kernel scripts that read the profile:
# repo-root resolution and profile discovery. SOURCED, never executed.
#
# Expects the caller to have set KIT_DIR (the pm-kit/ directory) and to call:
#   pm_repo_root            -> sets REPO_ROOT, or returns 1
#   pm_find_profile "$CONF" -> sets CONF to a readable profile, or returns 1
#
# Discovery order (identical for every script using this library):
#   1. the explicit --conf value, when it exists
#   2. $PM_PROFILE: a path to a profile, or a bare name resolved to
#      <kit>/profiles/<name>.conf
#   3. the single *.conf in <kit>/profiles/ (two or more is ambiguous: no pick)
# The kit directory is located from the script's own path, so a kit installed
# under any directory name is found.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "profile-lib.sh must be sourced from bash" >&2
  return 1 2>/dev/null || exit 1
fi

pm_repo_root() {
  REPO_ROOT="${PM_REPO_ROOT:-}"
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
  fi
  [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]
}

pm_find_profile() {
  local given="${1:-}" n
  CONF=""
  if [ -n "$given" ]; then
    [ -f "$given" ] && CONF="$given"
    [ -n "$CONF" ]
    return
  fi
  if [ -n "${PM_PROFILE:-}" ]; then
    if [ -f "$PM_PROFILE" ]; then
      CONF="$PM_PROFILE"
    elif [ -f "$KIT_DIR/profiles/$PM_PROFILE.conf" ]; then
      CONF="$KIT_DIR/profiles/$PM_PROFILE.conf"
    fi
  fi
  if [ -z "$CONF" ] && [ -d "$KIT_DIR/profiles" ]; then
    n="$(find "$KIT_DIR/profiles" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$n" = 1 ]; then
      CONF="$(find "$KIT_DIR/profiles" -maxdepth 1 -name '*.conf')"
    fi
  fi
  [ -n "$CONF" ]
}
