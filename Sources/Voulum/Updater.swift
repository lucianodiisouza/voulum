import Sparkle
import SwiftUI

/// Owns Sparkle's updater and exposes just enough of it to SwiftUI.
///
/// Sparkle drives the whole update loop itself (background checks, the "new
/// version available" prompt, download, verify, replace-and-relaunch). Updates
/// are verified with an EdDSA signature (`SUPublicEDKey` in Info.plist) on top
/// of Developer ID signing — see docs/UPDATES.md.
///
/// Until a real public key is in Info.plist the updater stays dormant: starting
/// Sparkle with the placeholder would greet every user with an "updater failed
/// to start" alert.
@MainActor
final class Updater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let isConfigured: Bool

    /// "0.4.1", for Settings and the popup's footer.
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    private let controller: SPUStandardUpdaterController

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty && !key.hasPrefix("REPLACE")
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if isConfigured {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Manual check. Shows Sparkle's own UI.
    func checkForUpdates() {
        guard isConfigured else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}
