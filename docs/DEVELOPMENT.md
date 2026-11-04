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
| [`CoreAudioUtils.swift`](../Sources/Voulum/CoreAudioUtils.swift) | Typed, throwing wrappers over the Core Audio property C API, plus property listeners (`listen(to:)` → a token that unregisters on deinit). |
| [`AudioEngine.swift`](../Sources/Voulum/AudioEngine.swift) | Finds the apps playing audio and groups helper processes under their owning app (parent-PID walk, then the enclosing bundle). Applies each app's saved settings and decides when it needs a tap. Also owns the live meters. |
| [`AudioEngine+Transport.swift`](../Sources/Voulum/AudioEngine+Transport.swift), [`NowPlaying.swift`](../Sources/Voulum/NowPlaying.swift) | Per-app play/pause/skip and track metadata through each app's scripting interface. |
| [`AppTap.swift`](../Sources/Voulum/AppTap.swift) | The audio path for one app. A `CATapDescription(.mutedWhenTapped)` feeds a private aggregate device that holds the tap and one or more output devices. The IOProc runs gain ramp → EQ → soft limiter → meters → fan-out to every output. |
| [`Equalizer.swift`](../Sources/Voulum/Equalizer.swift) | 10-band EQ model, built-in presets, RBJ biquads, and a realtime-safe processor. |
| [`DeviceController.swift`](../Sources/Voulum/DeviceController.swift) | Output and input devices: defaults, volumes, priority order, hiding, and auto-switching to a preferred device. |
| [`Preferences.swift`](../Sources/Voulum/Preferences.swift) | Everything persisted: per-app settings keyed by bundle id, pinned and ignored apps, user presets, shortcuts, options. |
| [`Hotkeys.swift`](../Sources/Voulum/Hotkeys.swift) | Global shortcuts (Carbon `RegisterEventHotKey`, hold to repeat) and the shortcut recorder. |
| [`URLCommands.swift`](../Sources/Voulum/URLCommands.swift) | The `voulum://` automation scheme. |
| [`StatusItemController.swift`](../Sources/Voulum/StatusItemController.swift) | Status item, live icon, popover, and keyboard handling while it's open. |
| [`PopupView.swift`](../Sources/Voulum/PopupView.swift), [`AppRowView.swift`](../Sources/Voulum/AppRowView.swift), [`EQPanel.swift`](../Sources/Voulum/EQPanel.swift), [`Components.swift`](../Sources/Voulum/Components.swift) | The popup UI: output card and device list, app rows with the level ring and route picker, the draggable EQ curve, and the boost-zone slider. |
| [`SettingsView.swift`](../Sources/Voulum/SettingsView.swift) | The Settings window. |
| [`VolumeToast.swift`](../Sources/Voulum/VolumeToast.swift) | The on-screen toast shown when a shortcut changes a volume. |
| [`Updater.swift`](../Sources/Voulum/Updater.swift) | Sparkle. It stays dormant until a real `SUPublicEDKey` is configured. |
| [`LoginItem.swift`](../Sources/Voulum/LoginItem.swift) | Launch at login via `SMAppService`. |
| [`VoulumApp.swift`](../Sources/Voulum/VoulumApp.swift) | Entry point. Sets the accessory policy, enforces a single instance, and wires up hotkeys and URLs. |

### Only tap what needs it

An app is tapped only when its settings differ from "untouched". That means a
volume other than 100%, mute, EQ, or a custom route (`AppAudioSettings.needsTap`).
Apps left alone keep the normal macOS audio path. Resetting an app tears its
tap down.

### Realtime safety

The render callback never allocates or takes a blocking lock:
- Gain, peak, RMS and limiter state live in a preallocated buffer.
- EQ coefficients are swapped with `os_unfair_lock_trylock`. If the lock is
  busy, the callback keeps the previous coefficients for that cycle.
- Biquad state flushes denormals.

### Routing and fallback

A route is either `.system` (follow the default output) or a list of device
UIDs. Missing devices are skipped; if none remain, the app plays on the default
output. Device-list changes reconcile every tap, so a reconnected device is
picked up again automatically. Non-main subdevices in the aggregate use drift
compensation.

### Why polling for the app list

The list refreshes when the popup opens. It polls every second (meters at
24 Hz) while the popup is open, and every 3 s in the background so routes and
volumes reach new apps. The process-list listener catches apps that appear in
between.

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
   then runs [`scripts/release.sh`](../scripts/release.sh):
   - builds the app, signs it with the Developer ID, and notarizes it
   - attaches `Voulum-vX.Y.Z-macos.dmg` to the release
   - refreshes the Sparkle appcast and the Homebrew cask

   The build has to run in that same workflow, because a release created by
   `GITHUB_TOKEN` can't trigger a separate `on: release` workflow.

[`build`](../.github/workflows/build.yml) compiles every push and PR as a sanity
check.

For the signing secrets and local releases, see [docs/SIGNING.md](SIGNING.md).
CI falls back to an ad-hoc signature when the secrets are missing.

## Ideas

- Media-key volume with an on-screen HUD
- Brightness/volume for external displays (DDC)
- Per-app input (microphone) gain
- Headphone EQ profiles (AutoEQ)
