#!/usr/bin/env bash
#
# clean.sh — remove local Voulum installs and dev artifacts.
#
# Quits any running instance, deletes the installed .app, wipes local build
# output, and clears the app's saved state (UserDefaults). By default it leaves
# the macOS audio-permission (TCC) grant alone; pass --reset-permission to also
# revoke it so you can re-test the first-run permission prompt.
#
# Usage:
#   scripts/clean.sh                 # quit, uninstall, clear build + defaults
#   scripts/clean.sh --reset-permission   # also revoke the audio/mic TCC grant
#   scripts/clean.sh --keep-defaults      # leave UserDefaults untouched
#
set -euo pipefail

BUNDLE_ID="com.voulum.app"
APP_NAME="Voulum"
INSTALLED_APP="/Applications/${APP_NAME}.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

reset_permission=false
clear_defaults=true
for arg in "$@"; do
  case "$arg" in
    --reset-permission) reset_permission=true ;;
    --keep-defaults)    clear_defaults=false ;;
    -h|--help)
      sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

step "Quitting running ${APP_NAME} instances"
killall "${APP_NAME}" 2>/dev/null && echo "  stopped" || echo "  none running"

if [[ -d "${INSTALLED_APP}" ]]; then
  step "Removing ${INSTALLED_APP}"
  rm -rf "${INSTALLED_APP}"
  echo "  removed"
else
  step "No installed app at ${INSTALLED_APP}"
fi

if [[ -d "${BUILD_DIR}" ]]; then
  step "Removing build output (${BUILD_DIR})"
  rm -rf "${BUILD_DIR}"
  echo "  removed"
fi

if [[ "${clear_defaults}" == true ]]; then
  step "Clearing UserDefaults for ${BUNDLE_ID}"
  defaults delete "${BUNDLE_ID}" 2>/dev/null && echo "  cleared" || echo "  nothing stored"
fi

if [[ "${reset_permission}" == true ]]; then
  step "Revoking audio/microphone permission (TCC) for ${BUNDLE_ID}"
  tccutil reset Microphone "${BUNDLE_ID}" 2>/dev/null && echo "  microphone reset" || echo "  microphone: nothing to reset"
  tccutil reset AudioCapture "${BUNDLE_ID}" 2>/dev/null && echo "  audio-capture reset" || true
fi

step "Done."
