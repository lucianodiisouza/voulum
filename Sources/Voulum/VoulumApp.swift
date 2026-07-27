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
    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioProcessController.shared.start()
    }
}
