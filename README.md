<h1 align="center">Voulum</h1>

<p align="center">
  <em>Per-app volume control for macOS, from your menu bar.</em>
</p>

macOS lets you set one system volume — but not the volume of *each app*. Voulum
adds the missing mixer. It also answers the daily annoyance behind it: **"which
of my thirty open windows is making that sound?"**

Click the menu-bar icon and you see every app currently playing audio. Each one
gets:

- 🔎 **a jump button** — bring that app to the front so you can find the sound
- 🔊 **a volume slider** — from mute, through normal, up to 3× boost
- 🔇 **a mute toggle** — silence one app without touching the rest

The list updates itself while the menu is open — no refresh needed.

---

## Install

> Voulum is **not** signed with an Apple Developer ID or notarized (that costs a
> paid Apple account). macOS therefore treats it as "unidentified" and will
> refuse to open it on the first try. This is expected — here's the one-time
> workaround.

1. Download **`Voulum-vX.Y.Z-macos.dmg`** from the
   [latest release](../../releases/latest) and open it.
2. Drag **Voulum.app** onto the **Applications** shortcut in the window.
3. Clear the quarantine flag so macOS will run it. Open **Terminal** and run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Voulum.app
   ```

4. Open **Voulum** from Applications. Look for the 🔊 icon in your menu bar.

<details>
<summary>Prefer not to use Terminal?</summary>

Double-click the app. macOS blocks it. Then go to **System Settings ▸ Privacy &
Security**, scroll down, and click **"Open Anyway"** next to the message about
Voulum. Confirm once. (On older macOS you can instead **right-click the app ▸
Open ▸ Open**.) The Terminal command above is the most reliable method.
</details>

## First use

- **Audio permission.** The first time you change an app's volume, macOS asks
  for permission to capture audio (that's how per-app volume works under the
  hood). Click **Allow**. Voulum remembers this — it won't ask again.
  You can review it later in **System Settings ▸ Privacy & Security ▸
  Microphone**.
- **Launch at login.** Toggle **"Launch at login"** at the bottom of the menu to
  have Voulum start automatically. macOS remembers the setting across reboots.

## FAQ

**Is it safe / what's the audio permission for?**
Voulum uses Apple's official Core Audio "process tap" API to intercept an app's
audio and play it back at your chosen volume. macOS classes that as audio
capture, so it asks permission. Voulum only routes audio to your speakers — it
records nothing.

**Why isn't it just signed?**
Signing + notarization needs a paid Apple Developer account. The app is built in
the open on GitHub Actions; you can read exactly what's in it.

**It says the app is damaged / can't be opened.**
That's the quarantine flag. Run the `xattr` command in step 3 above.

## Building it yourself

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

MIT — see [LICENSE](LICENSE).
