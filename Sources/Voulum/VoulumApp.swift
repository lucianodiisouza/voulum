import AppKit
import SwiftUI

/// Plain AppKit entry point: Voulum is a status item with a popover, which
/// gives us what `MenuBarExtra` can't — opening the popup from a hotkey or URL,
/// keyboard control while it's open, and an icon that updates live.
@main
enum VoulumMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch argument that runs a headless uninstall cleanup and quits — used by
    /// `scripts/clean.sh`. It's the only reliable way to do these two things from
    /// outside the app: unregistering an `SMAppService` login item and destroying
    /// leaked Core Audio devices both require running the app's own code.
    static let cleanupFlag = "--uninstall-cleanup"

    static let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(Self.cleanupFlag) {
            log.info("Running uninstall cleanup (\(Self.cleanupFlag, privacy: .public))")
            LoginItem.setEnabled(false)
            AppTap.reapLeakedDevices()
            NSApp.terminate(nil)
            return
        }

        // Two copies would fight over the same taps (each muting the app and
        // replaying it), so a second launch hands over to the first and quits.
        let me = NSRunningApplication.current
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .contains(where: { $0 != me && !$0.isTerminated }) {
            log.info("Another Voulum is already running; quitting this one")
            NSApp.terminate(nil)
            return
        }

        DeviceController.shared.start()
        AudioEngine.shared.start()
        StatusItemController.shared.install()

        let prefs = Preferences.shared
        HotkeyCenter.shared.handler = { action in
            let engine = AudioEngine.shared
            let step = prefs.volumeStep.fraction
            switch action {
            case .togglePopup:
                StatusItemController.shared.toggle()
            case .volumeUp, .volumeDown, .toggleMute:
                guard let app = engine.hotkeyTarget() else { return NSSound.beep() }
                switch action {
                case .volumeUp: engine.step(app, by: step)
                case .volumeDown: engine.step(app, by: -step)
                default: engine.toggleMute(app)
                }
                VolumeToast.shared.show(app: app, settings: engine.settings(app.key))
            }
        }
        HotkeyCenter.shared.apply(prefs.hotkeys)
        _ = Self.updater
        if OnboardingWindowController.needsOnboarding { OnboardingWindowController.shared.show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AudioEngine.shared.whenReady { urls.forEach(URLCommands.handle) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Preferences.shared.saveNow()
        // Hand every app's audio straight back to macOS before we go.
        AudioEngine.shared.shutdown()
    }

    /// Reopening the app from Finder / Spotlight while it's running opens the popup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        StatusItemController.shared.open()
        return false
    }
}
