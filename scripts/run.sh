#!/usr/bin/env bash
#
# run.sh — build Voulum, install it to /Applications, and launch it.
#
# Regenerates the Xcode project from project.yml (so newly added source files
# are picked up), builds with xcodebuild, replaces the installed .app, and opens
# it. Ad-hoc signed, matching the dev/release setup.
#
# Usage:
#   scripts/run.sh              # build Debug, install, launch
#   scripts/run.sh --release    # build Release instead of Debug
#   scripts/run.sh --selftest   # launch with VOULUM_SELFTEST=1 (headless tap ramp)
#   scripts/run.sh --no-open    # build + install but don't launch
#
set -euo pipefail

APP_NAME="Voulum"
INSTALLED_APP="/Applications/${APP_NAME}.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

configuration="Debug"
selftest=false
do_open=true
for arg in "$@"; do
  case "$arg" in
    --release)  configuration="Release" ;;
    --selftest) selftest=true ;;
    --no-open)  do_open=false ;;
    -h|--help)
      sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

cd "${REPO_ROOT}"

if command -v xcodegen >/dev/null 2>&1; then
  step "Regenerating Xcode project (xcodegen)"
  xcodegen generate >/dev/null
else
  step "xcodegen not found — building existing project as-is"
fi

step "Building ${APP_NAME} (${configuration})"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
  -configuration "${configuration}" -derivedDataPath build build \
  | tail -3

BUILT_APP="${BUILD_DIR}/Build/Products/${configuration}/${APP_NAME}.app"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Build succeeded but ${BUILT_APP} is missing" >&2
  exit 1
fi

# Xcode signs the app ad hoc with the hardened runtime on, and the runtime's
# library validation then refuses the embedded Sparkle.framework (dyld:
# "Library missing ... different Team IDs"). Re-sign inside-out without the
# runtime, as release.sh --adhoc does.
step "Re-signing ad hoc"
SPARKLE="${BUILT_APP}/Contents/Frameworks/Sparkle.framework"
if [[ -d "${SPARKLE}" ]]; then
  for helper in \
    "${SPARKLE}/Versions/B/XPCServices/Installer.xpc" \
    "${SPARKLE}/Versions/B/XPCServices/Downloader.xpc" \
    "${SPARKLE}/Versions/B/Autoupdate" \
    "${SPARKLE}/Versions/B/Updater.app"; do
    [[ -e "${helper}" ]] && codesign --force --sign - --preserve-metadata=entitlements "${helper}" 2>/dev/null
  done
  codesign --force --sign - "${SPARKLE}" 2>/dev/null
fi
codesign --force --sign - --entitlements "${REPO_ROOT}/Sources/${APP_NAME}/${APP_NAME}.entitlements" \
  "${BUILT_APP}" 2>/dev/null
codesign --verify --deep --strict "${BUILT_APP}"

step "Quitting running ${APP_NAME} instances"
killall "${APP_NAME}" 2>/dev/null && echo "  stopped" || echo "  none running"
sleep 1

step "Installing to ${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${BUILT_APP}" "${INSTALLED_APP}"

if [[ "${do_open}" == true ]]; then
  if [[ "${selftest}" == true ]]; then
    step "Launching with VOULUM_SELFTEST=1"
    VOULUM_SELFTEST=1 open "${INSTALLED_APP}"
  else
    step "Launching ${APP_NAME}"
    open "${INSTALLED_APP}"
  fi
else
  step "Installed (not launching)"
fi

step "Done."
