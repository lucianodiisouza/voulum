# Code signing & notarization

By default the released `.dmg` is **ad-hoc signed** (free, but users must clear
the quarantine flag — see the README). Once you have a **paid Apple Developer
account**, add the secrets below and the release workflow automatically switches
to a **Developer ID** signature + **notarization**, so the app opens with no
warnings and no `xattr` step.

No code change is needed to turn this on — the workflow detects the secrets. If
they're absent it falls back to ad-hoc, so nothing breaks in the meantime.

## One-time setup

### 1. Create a Developer ID Application certificate

In [Apple Developer ▸ Certificates](https://developer.apple.com/account/resources/certificates/list),
create a **Developer ID Application** certificate, download it, and add it to
your login keychain (double-click the `.cer`). Then export it **with its private
key** as a `.p12` (Keychain Access ▸ right-click the cert ▸ Export), setting a
password.

Base64-encode the `.p12` for the secret:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

### 2. Create an app-specific password

At [appleid.apple.com](https://appleid.apple.com) ▸ Sign-In & Security ▸
App-Specific Passwords, generate one for notarization.

### 3. Find your identity string and Team ID

```bash
security find-identity -v -p codesigning   # -> "Developer ID Application: Your Name (TEAMID)"
```

The `TEAMID` in parentheses is your Team ID.

## GitHub secrets to add

Repo ▸ **Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret**:

| Secret | Value |
|--------|-------|
| `APPLE_CERTIFICATE_P12_BASE64` | base64 of the `.p12` (step 1) |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | your Team ID |
| `APPLE_APP_PASSWORD` | the app-specific password (step 2) |

That's it — the next release signs, notarizes, and staples automatically.

## How it works in CI

In [`release-please.yml`](../.github/workflows/release-please.yml) the
`release-dmg` job sets `HAS_CERT` from whether `APPLE_CERTIFICATE_P12_BASE64`
exists. When true it imports the cert into a throwaway keychain, signs the app
with `--options runtime` (hardened runtime, required for notarization), builds
the `.dmg`, then `notarytool submit --wait` + `stapler staple`. When false it
ad-hoc signs and skips notarization.

> Prefer an App Store Connect API key over an app-specific password? Swap the
> `notarytool` auth flags for `--key`, `--key-id`, and `--issuer` and store the
> `.p8` as a secret instead.
