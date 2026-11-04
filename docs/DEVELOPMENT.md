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
| [`AudioProcessController.swift`](../Sources/Voulum/AudioProcessController.swift) | Enumerates processes, refresh-on-open + poll-while-open, owns the per-app volume/mute state, the transport (play/pause) state, and remembers the audio permission. |
| [`NowPlaying.swift`](../Sources/Voulum/NowPlaying.swift) | Per-app AppleScript recipes: transport (pause/resume/skip) for every supported app, track metadata for the ones that can report it cheaply. |
| [`ProcessTap.swift`](../Sources/Voulum/ProcessTap.swift) | The volume engine: `CATapDescription(.mutedWhenTapped)` → `AudioHardwareCreateProcessTap` → private aggregate device → IOProc that scales tapped frames by `gain` (`vDSP_vsmul`). |
| [`LoginItem.swift`](../Sources/Voulum/LoginItem.swift) | Launch-at-login via `SMAppService`. |
| [`VoulumApp.swift`](../Sources/Voulum/VoulumApp.swift), [`MenuView.swift`](../Sources/Voulum/MenuView.swift) | `MenuBarExtra` UI; an `AppDelegate` starts enumeration eagerly at launch. |

### Why polling instead of Core Audio listeners

The list refreshes when the menu opens and polls on a 1 s timer only while it's
open (`beginLiveUpdates`/`endLiveUpdates`). This is simpler and more reliable
than per-process property listeners for catching apps that start/stop playing,
and does zero background work when the menu is closed. Tune `pollInterval` in
`AudioProcessController`.

### Per-app play/pause

There is no general way to pause an arbitrary macOS app. MediaRemote — the
framework behind Control Center's now-playing controls — is entitlement-gated to
Apple's own binaries since macOS 15.4, so a third party can neither read
arbitrary media metadata nor send a targeted transport command. `NowPlayingService`
therefore scripts each app individually, which means an allow-list, split into two
tiers:

- **Transport** (every recipe): pause / resume, plus skip where it means
  something. Native apps use their own verbs — Spotify/Music/TV have real
  `play`/`pause`, VLC's `play` is a *toggle* so both directions have to test
  `playing` first, QuickTime addresses `front document`.
- **Metadata** (`Recipe.metadata != nil`): title/artist/album, read on the 1 s
  poll. Browsers deliberately opt out.

Browsers are driven by injected JavaScript that pauses `<video>`/`<audio>`
elements. Two things shape that code:

- Neither Safari's nor Chromium's dictionary exposes an "audible tab" flag, and
  audio usually plays in a *background* tab — so a command has to sweep every tab
  of every window. That's why browsers report no metadata: sweeping once a second
  would be absurd. Their play state comes from Core Audio's `isRunningOutput`,
  which is an accurate "is this app making sound" signal anyway.
- Pause tags each element it stops with `data-voulum-paused`; resume plays back
  exactly those. Without the marker, resume would have to guess which element to
  start, and would happily fire off an unrelated autoplay video.
- The sweep recurses into nested iframes — plenty of players live in one, and
  `document.querySelectorAll` only sees the top document. A **cross-origin**
  frame throws on `contentDocument` and is skipped; neither browser's scripting
  API can reach inside one, so media in a third-party embed can't be paused.
  That's a hard ceiling, not a bug to fix — in practice it's how most LMS video
  (Canvas external tools, Kaltura, Panopto) and most third-party embeds arrive.
- Because of that ceiling the sweep returns a **count** of the elements it
  actually touched, and `send` maps a count of zero onto
  `ScriptError.unreachableMedia`. Without it a browser pause that reached nothing
  looks identical to one that worked: the script succeeds, the row flips to
  "Paused", and the next poll silently flips it back. The count is what turns
  that into an honest message.

The injected JS is written on one line with single quotes only and builds
newlines via `String.fromCharCode(10)`. It gets embedded in a double-quoted
AppleScript string literal, which can't span lines, can't carry an unescaped `"`,
and would resolve a `\n` escape itself before JavaScript ever saw it.

Requires the user to enable "Allow JavaScript from Apple Events" (Safari's
Develop menu, Chromium's View ▸ Developer menu) and to grant Automation access.
Both failure modes are classified in `NowPlayingService.ScriptError` and surfaced
in the row.

`pauseOthersOnPlay` (menu toggle, on by default) makes a resume pause every other
scriptable app first, deduped by bundle id — one browser routinely shows up as
several Core Audio helper processes.

Two lag hazards, both handled by `pausedAt`:

1. Core Audio drops a paused app from `isRunningOutput`, so its row would vanish
   from the menu before the user could press play again. `visible` keeps
   anything in `pausedAt` listed.
2. In the other direction the HAL keeps reporting running-output for a beat
   *after* a pause lands, so the 400 ms post-command reload would immediately
   clear the flag and flash the row back to "Playing". `pauseGrace` (2.5 s) makes
   our own flag outrank the HAL until then.

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
