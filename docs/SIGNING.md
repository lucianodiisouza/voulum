# Code signing & notarization

Releases are **Developer ID signed and notarized**, so the downloaded app opens
with no Gatekeeper warning and no `xattr` step. A single script does the work,
locally and in CI: [`scripts/release.sh`](../scripts/release.sh).

1. Build Release, unsigned.
2. Sign inside-out with the hardened runtime and a secure timestamp:
   - first Sparkle's helpers (`Installer.xpc`, `Downloader.xpc`, `Autoupdate`, `Updater.app`)
   - then `Sparkle.framework`
   - then `Voulum.app` with [`Voulum.entitlements`](../Sources/Voulum/Voulum.entitlements)
3. Package `Voulum-vX.Y.Z-macos.dmg` and sign the DMG.
4. `notarytool submit --wait`, then `stapler staple` and an `spctl` check. If
   Apple rejects the submission, the script prints the notary log.

If the CI secrets are missing, the workflow falls back to an ad-hoc signature
(`release.sh --adhoc`), so releases never break.

## Releasing from your Mac

You need a **Developer ID Application** certificate in your login keychain.
Check that it's there:

```bash
security find-identity -v -p codesigning   # "Developer ID Application: Name (TEAMID)"
```

Store notary credentials in the keychain once. notarytool asks for an Apple ID
and an [app-specific password](https://appleid.apple.com), or for an App Store
Connect API key:

```bash
xcrun notarytool store-credentials voulum-notary
```

Then build a release:

```bash
scripts/release.sh            # version from project.yml → build/Voulum-v<version>-macos.dmg
scripts/release.sh 0.5.0      # explicit version
scripts/release.sh --no-notarize
```

To use a different identity or profile, set `SIGNING_IDENTITY` or
`NOTARY_PROFILE`.

## Releasing from CI

The `release-dmg` job in
[`release-please.yml`](../.github/workflows/release-please.yml) runs whenever
release-please publishes a release:

1. It imports the certificate into a throwaway keychain.
2. It runs `scripts/release.sh "$TAG"`.
3. It uploads the DMG, then updates the Sparkle appcast and the Homebrew cask.

### Secrets

Add these under Repo ▸ **Settings ▸ Secrets and variables ▸ Actions**.

**Certificate** (required for signing):

| Secret | Value |
|--------|-------|
| `APPLE_CERTIFICATE_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy`. Export the cert **with its private key** from Keychain Access. |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | optional; for example `Developer ID Application: Luciano de Souza (TJ7XUV6VQ9)` |

**Notarization**, either option.

Option A, App Store Connect API key (recommended):

| Secret | Value |
|--------|-------|
| `NOTARY_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_API_KEY_ID` | the key ID |
| `NOTARY_API_ISSUER_ID` | the issuer ID |

Create the key at App Store Connect ▸ Users and Access ▸ Integrations ▸ Team
Keys, with the *Developer* role.

Option B, Apple ID:

| Secret | Value |
|--------|-------|
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | `TJ7XUV6VQ9` |
| `APPLE_APP_PASSWORD` | an app-specific password |

With these in place, the next release is signed, notarized and stapled
automatically.
