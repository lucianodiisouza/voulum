import ServiceManagement

/// Thin wrapper over `SMAppService` for the "launch at login" toggle
/// (macOS 13+). Registering the main app makes macOS relaunch Voulum on login;
/// the state is stored by the system, so it survives reboots and reinstalls.
enum LoginItem {

    /// Whether Voulum is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister the app as a login item. Returns the resulting state
    /// so the UI can reconcile if the call failed.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Failed to \(enabled ? "enable" : "disable", privacy: .public) launch-at-login: \(String(describing: error), privacy: .public)")
        }
        return isEnabled
    }
}
