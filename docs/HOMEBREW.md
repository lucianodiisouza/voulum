# Homebrew distribution

Voulum is a GUI app, so it ships as a **Homebrew Cask**. The canonical cask
lives in this repo at [`Casks/voulum.rb`](../Casks/voulum.rb); the release
workflow copies it into a separate **tap repo** on every release, with the
version and DMG checksum filled in.

Once set up, users install with:

```bash
brew install --cask lucianodiisouza/voulum/voulum
```

## Prerequisite: signing & notarization

Do **not** publish the cask until releases are signed + notarized (see
[SIGNING.md](SIGNING.md)). An unsigned cask installs, but Gatekeeper still
blocks the app on launch and, worse for Voulum, the audio-tap permission is
keyed to the code signature, so ad-hoc-signed builds re-prompt for permission on
every update. Homebrew's official cask repo also expects notarized apps. Ship
Homebrew and notarization together.

## One-time setup

### 1. Create the tap repo

Create an **empty public repo** named exactly `homebrew-voulum` under the same
owner as this repo. The `homebrew-` prefix is what makes `brew tap` find it; the
tap is then referred to as `lucianodiisouza/voulum` (Homebrew drops the prefix).

No files needed: the release workflow creates `Casks/voulum.rb` on the next
release.

### 2. Add the push token

The release runs in *this* repo but must push to the *tap* repo, so it needs a
cross-repo token. Create a **fine-grained personal access token** scoped to the
`homebrew-voulum` repo with **Contents: read and write**, then add it here as a
secret:

Repo ▸ **Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret**

| Secret | Value |
|--------|-------|
| `HOMEBREW_TAP_TOKEN` | the fine-grained PAT (Contents: R/W on `homebrew-voulum`) |

That's it. The next release bumps the cask automatically.

## How it works in CI

In [`release-please.yml`](../.github/workflows/release-please.yml) the
`release-dmg` job sets `HAS_TAP_TOKEN` from whether `HOMEBREW_TAP_TOKEN` exists.
When true, after the `.dmg` is built and uploaded it clones the tap, writes the
new `version` and the uploaded DMG's `sha256` into a copy of this repo's
`Casks/voulum.rb`, and pushes. When false the step is skipped, so this is safe
to merge before the tap repo or token exist.

## Seeding the current version by hand (optional)

If you want the tap live before the next release, copy `Casks/voulum.rb` into
`homebrew-voulum/Casks/voulum.rb` as-is. It already carries the latest released
version and checksum.

## Going official later

Submitting to Homebrew's own `homebrew-cask` (so `brew install --cask voulum`
works with no tap prefix) requires the project to clear their notability bar and
be notarized. Keep the personal tap regardless. It's the fallback and the place
to test cask changes.
