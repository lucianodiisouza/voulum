import AppKit
import Foundation

/// `voulum://` automation. Every command that takes `app=` accepts a bundle id
/// or an app name; leave it out to target the app that's playing right now.
///
///   voulum://volume?app=Spotify&level=40        set to 40% (0–400)
///   voulum://volume?app=Spotify&step=-10        relative change, in points
///   voulum://mute?app=Safari · unmute · toggle-mute
///   voulum://route?app=Music&device=AirPods     device name(s)/UID(s), comma-separated, or "system"
///   voulum://eq?app=Spotify&preset=Rock         preset name or id; &enabled=false to bypass
///   voulum://reset?app=Spotify
///   voulum://output?device=MacBook Pro Speakers switch the system output
///   voulum://output-volume?level=30             system output volume (0–100)
///   voulum://open · voulum://settings
@MainActor
enum URLCommands {

    static let examples = [
        "voulum://volume?app=Spotify&level=40",
        "voulum://volume?step=-10",
        "voulum://toggle-mute?app=Safari",
        "voulum://route?app=Music&device=AirPods,system",
        "voulum://eq?app=Spotify&preset=Late%20Night",
        "voulum://output?device=MacBook%20Pro%20Speakers",
    ]

    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "voulum" else { return }
        let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name.lowercased()] = item.value ?? ""
        }
        let engine = AudioEngine.shared
        let devices = DeviceController.shared
        func target() -> AudioApp? {
            if let name = query["app"], !name.isEmpty { return engine.findApp(name) }
            return engine.hotkeyTarget()
        }
        func outputDevice(_ query: String) -> AudioDevice? {
            let q = query.lowercased()
            return devices.outputs.first { $0.uid.lowercased() == q }
                ?? devices.outputs.first { $0.name.lowercased() == q }
                ?? devices.outputs.first { $0.name.lowercased().contains(q) }
        }

        switch command {
        case "volume", "set-volume":
            guard let app = target() else { return fail(url, "no matching app") }
            if let level = query["level"].flatMap(Float.init) {
                engine.setLevel(level / 100, for: app)
            } else if let step = query["step"].flatMap(Float.init) {
                engine.step(app, by: step / 100)
            }
        case "mute":
            if let app = target() { engine.setMuted(true, for: app) }
        case "unmute":
            if let app = target() { engine.setMuted(false, for: app) }
        case "toggle-mute":
            if let app = target() { engine.toggleMute(app) }
        case "route":
            guard let app = target(), let spec = query["device"] else { return fail(url, "need app and device") }
            let names = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if names.contains(where: { $0.lowercased() == "system" }) && names.count == 1 {
                engine.setRoute(.system, for: app)
            } else {
                let uids = names.compactMap { outputDevice($0)?.uid }
                guard !uids.isEmpty else { return fail(url, "no matching device") }
                engine.setRoute(.devices(uids), for: app)
            }
        case "eq":
            guard let app = target() else { return fail(url, "no matching app") }
            var eq = engine.settings(app.key).eq
            if let name = query["preset"]?.lowercased(),
               let preset = Preferences.shared.allPresets.first(where: { $0.id == name || $0.name.lowercased() == name }) {
                eq.gains = preset.gains
                eq.presetID = preset.id
                eq.enabled = true
            }
            if let enabled = query["enabled"] { eq.enabled = enabled != "false" && enabled != "0" }
            engine.setEQ(eq, for: app)
        case "reset":
            if let app = target() { engine.reset(app) }
        case "output", "set-output":
            guard let spec = query["device"], let device = outputDevice(spec) else { return fail(url, "no matching device") }
            devices.setDefault(device)
        case "output-volume":
            guard let device = devices.defaultOutput, let level = query["level"].flatMap(Float.init) else { return }
            devices.setVolume(level / 100, for: device)
        case "open", "toggle":
            StatusItemController.shared.toggle()
        case "settings":
            SettingsWindowController.shared.show()
        default:
            fail(url, "unknown command")
        }
    }

    private static func fail(_ url: URL, _ reason: String) {
        log.error("voulum:// \(url.absoluteString, privacy: .public) ignored: \(reason, privacy: .public)")
    }
}
