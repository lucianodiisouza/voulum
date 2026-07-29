# Auto-update (Sparkle)

Voulum uses [Sparkle](https://sparkle-project.org) to check for, download, and
install new versions. This works even though the app is **unsigned**: Sparkle
verifies each update with its own **EdDSA (Ed25519)** signature, which is
independent of Apple code signing / notarization.

A nice side effect: updates installed by Sparkle are *not* quarantined (the app
downloads them, not the browser), so the one-time `xattr` workaround in the
README only ever applies to the **first** install. Every update after that is
one click.

## How it fits together

- The app polls **`appcast.xml`** — an RSS feed of released versions — at the
  URL in `SUFeedURL` (Info.plist), currently the
  `releases/latest/download/appcast.xml` permalink.
- Each entry carries an `edSignature`. The app checks it against the public key
  in **`SUPublicEDKey`** (Info.plist) before installing anything.
- On release, CI signs the `.dmg` with the **private** key (a repo secret) and
  regenerates `appcast.xml`, attaching it to the GitHub Release. See the
  `Generate signed appcast` step in
  [`.github/workflows/release-please.yml`](../.github/workflows/release-please.yml).

Until the secret and public key are in place, the CI step is skipped and
releases behave exactly as before — nothing breaks while auto-update is off.

## One-time setup

Auto-update is wired but **not yet armed**. Two things are needed:

### 1. Generate the EdDSA keypair (you, locally)

Sparkle ships a `generate_keys` tool. Grab the same release the CI uses:

```bash
SPARKLE_VERSION=2.6.4
curl -fsSL -o sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
mkdir sparkle && tar -xf sparkle.tar.xz -C sparkle

# Creates a private key in your login Keychain and prints the PUBLIC key.
./sparkle/bin/generate_keys
```

- Copy the printed **public** key into `SUPublicEDKey` in
  [`Sources/Voulum/Info.plist`](../Sources/Voulum/Info.plist), replacing
  `REPLACE_WITH_YOUR_SPARKLE_PUBLIC_ED_KEY`.
- Export the **private** key for CI:

  ```bash
  ./sparkle/bin/generate_keys -x sparkle_private_key.pem
  ```

  Keep this file out of git. The private key is the only thing that can forge an
  update — treat it like a signing identity.

### 2. Add the CI secret

Create a repository secret named **`SPARKLE_PRIVATE_KEY`** containing the
contents of `sparkle_private_key.pem`:

```bash
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private_key.pem
```

That's it. The next release-please release will publish a signed `appcast.xml`,
and installed copies will start seeing updates.

## Why the CI overrides `CURRENT_PROJECT_VERSION`

Sparkle decides "is this newer?" by comparing **`CFBundleVersion`**.
`project.yml` pins `CURRENT_PROJECT_VERSION` (→ `CFBundleVersion`) to `"1"`, so
without intervention every build would look identical to Sparkle and no update
would ever be offered. The release workflow therefore overrides it with the
release version (the git tag minus its leading `v`), so `0.3.0 > 0.2.1` compares
correctly. Local/debug builds are unaffected.

## Testing before a real release

You can point `SUFeedURL` at a local file:// or a scratch gist while testing,
bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`, run `generate_appcast`
against a folder of test DMGs, and confirm the in-app "Check for Updates…" flow
offers and installs the newer build.
