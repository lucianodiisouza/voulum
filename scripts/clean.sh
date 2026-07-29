#!/usr/bin/env bash
#
# clean.sh — remove local Voulum installs and dev artifacts.
#
# Quits any running instance, runs a headless in-app cleanup (unregisters the
# launch-at-login item and destroys leaked Core Audio devices/taps), deletes
# every installed .app it can find, wipes local build output, and clears the
# app's saved state (UserDefaults). By default it leaves the macOS
# audio-permission (TCC) grant alone; pass --reset-permission to also revoke it
# so you can re-test the first-run permission prompt.
#
# Usage:
#   scripts/clean.sh                 # quit, cleanup, uninstall, clear build + defaults
#   scripts/clean.sh --reset-permission   # also revoke the audio/mic TCC grant
#   scripts/clean.sh --keep-defaults      # leave UserDefaults untouched
#   scripts/clean.sh --skip-app-cleanup   # don't launch the app for login-item/audio cleanup
#
set -euo pipefail

BUNDLE_ID="com.voulum.app"
APP_NAME="Voulum"
CLEANUP_FLAG="--uninstall-cleanup"
CLEANUP_TIMEOUT=15
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

reset_permission=false
clear_defaults=true
app_cleanup=true
for arg in "$@"; do
  case "$arg" in
    --reset-permission) reset_permission=true ;;
    --keep-defaults)    clear_defaults=false ;;
    --skip-app-cleanup) app_cleanup=false ;;
    -h|--help)
      sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

# Run a command with a hard timeout (macOS ships no `timeout`). Kills the
# process if it outlives the limit so a wedged HAL can't hang the whole script.
run_with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
  local watcher=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$rc"
}

# Collect every installed Voulum.app: the two standard locations plus anything
# Spotlight knows about, minus copies inside this repo's build output.
declare -a APP_PATHS=()
add_app() {
  local p="$1"
  [[ -d "$p" ]] || return 0
  case "$p" in "${REPO_ROOT}"/*) return 0 ;; esac   # skip dev build artifacts
  local existing
  for existing in "${APP_PATHS[@]:-}"; do
    [[ "$existing" == "$p" ]] && return 0            # dedupe
  done
  APP_PATHS+=("$p")
}

add_app "/Applications/${APP_NAME}.app"
add_app "${HOME}/Applications/${APP_NAME}.app"
if command -v mdfind >/dev/null 2>&1; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && add_app "$p"
  done < <(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null || true)
fi

step "Quitting running ${APP_NAME} instances"
killall "${APP_NAME}" 2>/dev/null && echo "  stopped" || echo "  none running"
sleep 1

# Before deleting anything, let the app tear down state that only its own code
# can reach: the SMAppService login item and any leaked Core Audio devices.
if [[ "${app_cleanup}" == true ]]; then
  if [[ "${#APP_PATHS[@]}" -gt 0 ]]; then
    cleanup_app="${APP_PATHS[0]}"
    cleanup_bin="${cleanup_app}/Contents/MacOS/${APP_NAME}"
    if [[ -x "${cleanup_bin}" ]]; then
      step "Running in-app cleanup (login item + leaked audio devices)"
      if run_with_timeout "${CLEANUP_TIMEOUT}" "${cleanup_bin}" "${CLEANUP_FLAG}"; then
        echo "  done"
      else
        echo "  cleanup timed out or failed — continuing"
      fi
    fi
  else
    step "No installed app found — skipping in-app cleanup"
    echo "  (a login item or leaked audio devices from a since-deleted app can't"
    echo "   be cleared this way; reinstall + relaunch once, then re-run clean.sh)"
  fi
fi

if [[ "${#APP_PATHS[@]}" -gt 0 ]]; then
  for app in "${APP_PATHS[@]}"; do
    step "Removing ${app}"
    rm -rf "${app}"
    echo "  removed"
  done
else
  step "No installed ${APP_NAME}.app found"
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
