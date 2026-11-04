# Developing Voulum

A menu-bar macOS app that adds per-app volume control using Core Audio process
taps (macOS 14.4+). No kernel extension, no virtual audio driver.

## Requirements

- macOS 14.4 or newer (the process-tap APIs)
- Xcode 15.3+ (developed on Xcode 26 / Swift 6.2)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

The `.xcodeproj` is **generated** from [`project.yml`](../project.yml) and is
git-ignored. Regenerate it whenever you add/remove/rename source files:

```bash
xcodegen generate
open Voulum.xcodeproj      # ⌘R to run
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Voulum.xcodeproj -scheme Voulum -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

Running from Xcode installs into DerivedData; for testing the login-item and
permission flows, copy the built app into `/Applications` and ad-hoc sign it:

```bash
codesign --force --deep --sign - \
  --entitlements Sources/Voulum/Voulum.entitlements /Applications/Voulum.app
```

### Self-test

Set `VOULUM_SELFTEST=1` to run a headless smoke test of the tap pipeline on the
first playing process (it ramps the gain and logs each Core Audio status to
stderr and the unified log under subsystem `com.voulum.app`). Off by default.

```bash
VOULUM_SELFTEST=1 /Applications/Voulum.app/Contents/MacOS/Voulum
```

## Architecture

| File | Responsibility |
|------|----------------|
| [`CoreAudioUtils.swift`](../Sources/Voulum/CoreAudioUtils.swift) | Typed, throwing wrappers over the Core Audio property C API. |
| [`AudioProcess.swift`](../Sources/Voulum/AudioProcess.swift) | Model for one audio process; resolves helper processes to the owning app by walking parent PIDs (so a Chrome renderer shows as "Google Chrome"). |
| [`AudioProcessController.swift`](../Sources/Voulum/AudioProcessController.swift) | Enumerates processes, refresh-on-open + poll-while-open, owns the per-app volume/mute state and remembers the audio permission. |
| [`ProcessTap.swift`](../Sources/Voulum/ProcessTap.swift) | The volume engine: `CATapDescription(.mutedWhenTapped)` → `AudioHardwareCreateProcessTap` → private aggregate device → IOProc that scales tapped frames by `gain` (`vDSP_vsmul`). |
| [`LoginItem.swift`](../Sources/Voulum/LoginItem.swift) | Launch-at-login via `SMAppService`. |
| [`VoulumApp.swift`](../Sources/Voulum/VoulumApp.swift), [`MenuView.swift`](../Sources/Voulum/MenuView.swift) | `MenuBarExtra` UI; an `AppDelegate` starts enumeration eagerly at launch. |

### Why polling instead of Core Audio listeners

The list refreshes when the menu opens and polls on a 1 s timer only while it's
open (`beginLiveUpdates`/`endLiveUpdates`). This is simpler and more reliable
than per-process property listeners for catching apps that start/stop playing,
and does zero background work when the menu is closed. Tune `pollInterval` in
`AudioProcessController`.

### Permissions

Process taps require the audio-input entitlement
(`com.apple.security.device.audio-input`) and an `NSMicrophoneUsageDescription`
(see [`Info.plist`](../Sources/Voulum/Info.plist) and
[`Voulum.entitlements`](../Sources/Voulum/Voulum.entitlements)). macOS persists
the grant; we also mirror it in `UserDefaults` so the UI stops prompting.

## Releasing

Releases are automated with **Conventional Commits** + **release-please**.

1. Land changes on `main` with Conventional Commit messages:
   - `feat: …` → minor bump, `fix: …` → patch bump, `feat!:`/`BREAKING CHANGE:`
     → major. `chore/docs/ci/build/refactor:` don't trigger a release on their
     own.
2. [`release-please`](../.github/workflows/release-please.yml) opens/updates a
   **"chore(main): release x.y.z"** PR that maintains
   [`CHANGELOG.md`](../CHANGELOG.md) and bumps `MARKETING_VERSION` in
   `project.yml` (via the `x-release-please-version` marker).
3. **Merge that PR.** release-please tags `vX.Y.Z` and publishes a GitHub
   Release with the generated notes.
4. The **same** [`release-please`](../.github/workflows/release-please.yml) run
   then builds a Release `.app`, ad-hoc signs it, packages it into
   `Voulum-vX.Y.Z-macos.dmg`, and attaches it to the release. (The build must
   share that workflow run — a release created by the built-in `GITHUB_TOKEN`
   cannot trigger a separate `on: release` workflow.)

[`build`](../.github/workflows/build.yml) compiles every push and PR as a sanity
check.

> The released app is ad-hoc signed but **not notarized** — users clear the
> quarantine flag to run it (see the main README). To enable Developer ID
> signing + notarization (so users skip that step), add the Apple secrets
> described in [docs/SIGNING.md](SIGNING.md); the workflow turns it on
> automatically and falls back to ad-hoc when they're absent.

## Roadmap

- Persist per-app volumes across relaunch (keyed by bundle id)
- Rebuild the aggregate when the default output device changes
- App icon, richer menu-bar state
- Developer ID signing + notarization for a friction-free download
