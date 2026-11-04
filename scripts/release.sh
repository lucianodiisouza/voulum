#!/usr/bin/env bash
#
# release.sh — build a distributable Voulum.dmg: Developer ID signed,
# notarized and stapled, so it opens on any Mac with no warnings.
#
# Used both locally and by the release workflow. Steps:
#   1. build Release unsigned (xcodebuild)
#   2. sign inside-out: Sparkle helpers → Sparkle.framework → Voulum.app
#   3. package the .dmg with its installer window (scripts/dmg), then sign it
#   4. notarize with notarytool, then staple the ticket
#   5. write build/updates/appcast.xml, the Sparkle feed for this DMG
#      (locally only: the release workflow builds its own from a secret)
#
# Usage:
#   scripts/release.sh                  # version from project.yml
#   scripts/release.sh 0.5.0            # explicit version (also CFBundleVersion)
#   scripts/release.sh --no-notarize    # sign + package only
#   scripts/release.sh --adhoc          # ad-hoc signature, no notarization
#   scripts/release.sh --no-appcast     # skip the Sparkle feed
#
# Signing identity: $SIGNING_IDENTITY, else the first "Developer ID
# Application" identity in your keychain.
#
# Notary credentials, first match wins:
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER   App Store Connect API key (CI)
#   APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD     app-specific password
#   NOTARY_PROFILE (default "voulum-notary")          keychain profile, created once with:
#       xcrun notarytool store-credentials voulum-notary
#
# Sparkle signing key: the one generate_keys stored in your login keychain,
# or $SPARKLE_KEY_FILE.
#
# Output: build/Voulum-v<version>-macos.dmg (path also written to $GITHUB_ENV
# as DMG when running in Actions) and build/updates/appcast.xml.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
ENTITLEMENTS="${REPO_ROOT}/Sources/Voulum/Voulum.entitlements"

version=""
notarize=true
adhoc=false
appcast=true
[[ -n "${GITHUB_ACTIONS:-}" ]] && appcast=false
for arg in "$@"; do
  case "$arg" in
    --no-notarize) notarize=false ;;
    --adhoc)       adhoc=true; notarize=false; appcast=false ;;
    --no-appcast)  appcast=false ;;
    -h|--help)
      sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *)  version="${arg#v}" ;;
  esac
done

step() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

cd "${REPO_ROOT}"

if [[ -z "$version" ]]; then
  version="$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml | head -1)"
fi
[[ -n "$version" ]] || die "Couldn't work out the version; pass it as an argument."

if $adhoc; then
  identity="-"
else
  identity="${SIGNING_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  fi
  [[ -n "$identity" ]] || die "No Developer ID Application identity found (set SIGNING_IDENTITY, or use --adhoc)."
fi

# --- 1. Build ---------------------------------------------------------------

step "Building Voulum ${version} (Release)"
command -v xcodegen >/dev/null && xcodegen generate --quiet
# Sparkle orders updates by CFBundleVersion, so it has to grow with every
# release; the marketing version does that.
xcodebuild \
  -project Voulum.xcodeproj \
  -scheme Voulum \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${BUILD_DIR}" \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$version" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -quiet \
  build

APP="${BUILD_DIR}/Build/Products/Release/Voulum.app"
[[ -d "$APP" ]] || die "Build produced no app at $APP"

# --- 2. Sign, innermost first -----------------------------------------------

sign() {
  local flags=(--force --sign "$identity")
  $adhoc || flags+=(--options runtime --timestamp)
  codesign "${flags[@]}" "$@"
}

step "Signing with: ${identity}"
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  SPARKLE_B="${SPARKLE}/Versions/B"
  for helper in \
    "${SPARKLE_B}/XPCServices/Installer.xpc" \
    "${SPARKLE_B}/XPCServices/Downloader.xpc" \
    "${SPARKLE_B}/Autoupdate" \
    "${SPARKLE_B}/Updater.app"; do
    # Keep the entitlements Sparkle ships its helpers with.
    [[ -e "$helper" ]] && sign --preserve-metadata=entitlements "$helper"
  done
  sign "$SPARKLE"
fi
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 3. Package -------------------------------------------------------------

DMG="${BUILD_DIR}/Voulum-v${version}-macos.dmg"
step "Packaging $(basename "$DMG")"
command -v create-dmg >/dev/null || die "create-dmg not found (brew install create-dmg)."
# The installer window: artwork from scripts/dmg (660x400 points; the icon
# positions below match it). Finder lays the window out, so the first run asks
# to let your terminal control Finder. The height adds the 28pt title bar.
DMG_ART="${REPO_ROOT}/scripts/dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
tiffutil -cathidpicheck "${DMG_ART}/background.png" "${DMG_ART}/background@2x.png" \
  -out "${STAGE}.tiff" 2>/dev/null
rm -f "$DMG"
create-dmg \
  --volname "Voulum" \
  --volicon "${APP}/Contents/Resources/AppIcon.icns" \
  --background "${STAGE}.tiff" \
  --window-pos 200 160 \
  --window-size 660 428 \
  --icon-size 128 \
  --text-size 13 \
  --icon "Voulum.app" 170 190 \
  --hide-extension "Voulum.app" \
  --app-drop-link 490 190 \
  --no-internet-enable \
  "$DMG" "$STAGE" >/dev/null
rm -rf "$STAGE" "${STAGE}.tiff"
$adhoc || sign "$DMG"

# --- 4. Notarize ------------------------------------------------------------

if $notarize; then
  if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    creds=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    creds=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  else
    creds=(--keychain-profile "${NOTARY_PROFILE:-voulum-notary}")
  fi

  step "Notarizing (this usually takes a few minutes)"
  out="$(xcrun notarytool submit "$DMG" "${creds[@]}" --wait --output-format plist)" \
    || { echo "$out"; die "notarytool submit failed"; }
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$out" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    id="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$out" 2>/dev/null || true)"
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${creds[@]}" || true
    die "Notarization finished with status: ${status:-unknown}"
  fi

  step "Stapling"
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

# --- 5. Sparkle feed --------------------------------------------------------

if $appcast; then
  step "Writing the Sparkle appcast"
  generate_appcast="$(find "${BUILD_DIR}/SourcePackages/artifacts" -path '*/bin/generate_appcast' -type f 2>/dev/null | head -1)"
  [[ -n "$generate_appcast" ]] || die "generate_appcast not found; build once so Sparkle's package is fetched, or pass --no-appcast."
  repo="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  UPDATES="${BUILD_DIR}/updates"
  rm -rf "$UPDATES" && mkdir -p "$UPDATES"
  cp "$DMG" "$UPDATES/"
  key_args=()
  [[ -n "${SPARKLE_KEY_FILE:-}" ]] && key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
  # generate_appcast reads the version out of the app inside the DMG and signs
  # the download with the EdDSA key; the app checks it against SUPublicEDKey.
  "$generate_appcast" ${key_args[@]+"${key_args[@]}"} \
    --download-url-prefix "https://github.com/${repo}/releases/download/v${version}/" \
    "$UPDATES"
  printf '  Upload both to the v%s release:\n    gh release upload v%s "%s" "%s" --clobber\n' \
    "$version" "$version" "$DMG" "$UPDATES/appcast.xml"
fi

[[ -n "${GITHUB_ENV:-}" ]] && echo "DMG=$DMG" >> "$GITHUB_ENV"
printf '\033[1;32m✓\033[0m %s\n' "$DMG"
