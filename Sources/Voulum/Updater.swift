import Sparkle
import SwiftUI

/// Owns Sparkle's updater and exposes just enough of it to SwiftUI.
///
/// Sparkle drives the whole update loop itself (background checks, the "new
/// version available" prompt, download, verify, replace-and-relaunch). We only
/// need to (a) start it and (b) publish `canCheckForUpdates` so the menu's
/// "Check for Updates…" item can disable itself while a check is already
/// running.
///
/// Updates are verified with an EdDSA (Ed25519) signature — see `SUPublicEDKey`
/// in Info.plist — which is independent of Apple code signing, so it works even
/// though Voulum ships unsigned. The feed and signing are documented in
/// docs/UPDATES.md.
@MainActor
final class Updater: ObservableObject {
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true kicks off the background scheduler immediately,
        // honoring SUEnableAutomaticChecks / SUScheduledCheckInterval.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manual check, triggered from the menu. Shows Sparkle's own UI.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
