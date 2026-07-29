import AppKit
import SwiftUI

@main
struct VoulumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AudioProcessController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller)
        } label: {
            // SF Symbol that reads as "audio sources".
            Image(systemName: "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Starts audio enumeration eagerly at launch. Relying on the menu content
/// view's `.task` would defer everything until the user first opens the menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch argument that runs a headless uninstall cleanup and quits — used by
    /// `scripts/clean.sh`. It's the only reliable way to do these two things from
    /// outside the app: unregistering an `SMAppService` login item and destroying
    /// leaked Core Audio devices both require running the app's own code.
    static let cleanupFlag = "--uninstall-cleanup"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains(Self.cleanupFlag) {
            log.info("Running uninstall cleanup (\(Self.cleanupFlag, privacy: .public))")
            LoginItem.setEnabled(false)      // drop the launch-at-login registration
            ProcessTap.reapLeakedDevices()    // destroy any aggregate devices / taps we left behind
            NSApp.terminate(nil)
            return
        }
        AudioProcessController.shared.start()
    }
}
