import Combine
import Foundation

/// Where an app's audio goes.
enum OutputRoute: Codable, Equatable, Hashable {
    /// Whatever the system default output is — follows it when it changes.
    case system
    /// One or more specific devices, by UID. Several = play on all at once.
    case devices([String])

    var deviceUIDs: [String] {
        if case .devices(let uids) = self { return uids }
        return []
    }
}

/// Everything Voulum remembers about one app, keyed by its bundle id so it
/// survives the app quitting and relaunching (and Voulum restarting).
struct AppAudioSettings: Codable, Equatable {
    /// 0...maxLevel where 1 == 100%, i.e. untouched. Above 1 is boost.
    var level: Float = 1
    var muted = false
    var eq = EQSettings()
    var route: OutputRoute = .system

    static let maxLevel: Float = 4

    /// Whether the app needs a tap at all. An untouched app is left alone so it
    /// costs nothing and plays exactly as macOS would play it.
    var needsTap: Bool {
        muted || abs(level - 1) > 0.001 || (eq.enabled && !eq.isFlat) || route != .system
    }

    var isDefault: Bool { self == AppAudioSettings() }
}

/// An app referenced by the pinned / ignored lists, with enough to draw it
/// while it isn't running.
struct KnownApp: Codable, Hashable, Identifiable {
    let key: String
    var name: String
    var bundlePath: String?

    var id: String { key }
}

enum MenuBarIconStyle: String, CaseIterable, Codable, Identifiable {
    /// Follows the output device (headphones / speaker / TV …) and volume.
    case adaptive
    /// A speaker whose waves track the output volume.
    case speaker
    case waveform
    case dial

    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: return String(localized: "Adaptive")
        case .speaker: return String(localized: "Speaker")
        case .waveform: return String(localized: "Waveform")
        case .dial: return String(localized: "Dial")
        }
    }
}

/// How far one keyboard / scroll / hotkey nudge moves a volume.
/// The popup's backdrop.
enum PopupStyle: String, CaseIterable, Codable, Identifiable {
    /// A dark mixing desk: LED meters over the faders, square mute keys.
    /// Always dark, whatever the Mac is set to. The default.
    case desk
    /// The system's frosted popover material.
    case standard
    /// macOS 26 Liquid Glass: clearer, refracting what's behind it.
    case glass

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return String(localized: "Frosted")
        case .glass: return String(localized: "Liquid Glass")
        case .desk: return String(localized: "Mixing Desk")
        }
    }
    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    /// The style actually drawn: Liquid Glass falls back on older systems.
    var effective: PopupStyle { self == .glass && !Self.glassAvailable ? .standard : self }
}

enum VolumeStep: Int, CaseIterable, Codable, Identifiable {
    case fine = 2, normal = 5, coarse = 10
    var id: Int { rawValue }
    var fraction: Float { Float(rawValue) / 100 }
    var title: String {
        switch self {
        case .fine: return String(localized: "Fine (2%)")
        case .normal: return String(localized: "Normal (5%)")
        case .coarse: return String(localized: "Coarse (10%)")
        }
    }
}

/// All persisted state, in one place. Writes are coalesced so dragging a slider
/// doesn't hammer `UserDefaults` sixty times a second.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    @Published var apps: [String: AppAudioSettings] { didSet { scheduleSave() } }
    @Published var pinned: [KnownApp] { didSet { scheduleSave() } }
    @Published var ignored: [KnownApp] { didSet { scheduleSave() } }
    @Published var userPresets: [EQPreset] { didSet { scheduleSave() } }

    @Published var iconStyle: MenuBarIconStyle { didSet { scheduleSave() } }
    @Published var popupStyle: PopupStyle { didSet { scheduleSave() } }
    @Published var volumeStep: VolumeStep { didSet { scheduleSave() } }
    @Published var pauseOthersOnPlay: Bool { didSet { scheduleSave() } }
    @Published var showDevices: Bool { didSet { scheduleSave() } }
    @Published var showInactivePinned: Bool { didSet { scheduleSave() } }

    /// Output device UIDs, most preferred first.
    @Published var devicePriority: [String] { didSet { scheduleSave() } }
    /// When a device higher in `devicePriority` appears, make it the default.
    @Published var autoSwitchToPreferred: Bool { didSet { scheduleSave() } }
    @Published var hiddenDevices: Set<String> { didSet { scheduleSave() } }

    @Published var hotkeys: [HotkeyAction: Hotkey] { didSet { scheduleSave() } }

    private let defaults: UserDefaults
    private var saveWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyDomain(into: defaults)
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        apps = load(Keys.apps, [:])
        pinned = load(Keys.pinned, [])
        ignored = load(Keys.ignored, [])
        userPresets = load(Keys.userPresets, [])
        iconStyle = MenuBarIconStyle(rawValue: defaults.string(forKey: Keys.iconStyle) ?? "") ?? .adaptive
        popupStyle = PopupStyle(rawValue: defaults.string(forKey: Keys.popupStyle) ?? "") ?? .desk
        volumeStep = VolumeStep(rawValue: defaults.integer(forKey: Keys.volumeStep)) ?? .normal
        // Legacy keys from 0.4.x keep their meaning.
        pauseOthersOnPlay = defaults.object(forKey: Keys.pauseOthers) as? Bool ?? true
        showDevices = defaults.object(forKey: Keys.showDevices) as? Bool ?? true
        showInactivePinned = defaults.object(forKey: Keys.showInactivePinned) as? Bool ?? true
        devicePriority = defaults.stringArray(forKey: Keys.devicePriority) ?? []
        autoSwitchToPreferred = defaults.object(forKey: Keys.autoSwitch) as? Bool ?? false
        hiddenDevices = Set(defaults.stringArray(forKey: Keys.hiddenDevices) ?? [])
        hotkeys = load(Keys.hotkeys, [:])
    }

    // MARK: Per-app helpers

    func settings(for key: String) -> AppAudioSettings { apps[key] ?? AppAudioSettings() }

    func update(_ key: String, _ change: (inout AppAudioSettings) -> Void) {
        var value = settings(for: key)
        change(&value)
        // Don't keep rows for apps that are back to stock — unless they're
        // pinned, where the entry is what the user is configuring in advance.
        if value.isDefault && !isPinned(key) {
            apps.removeValue(forKey: key)
        } else {
            apps[key] = value
        }
    }

    func isPinned(_ key: String) -> Bool { pinned.contains { $0.key == key } }
    func isIgnored(_ key: String) -> Bool { ignored.contains { $0.key == key } }

    func setPinned(_ app: KnownApp, _ on: Bool) {
        pinned.removeAll { $0.key == app.key }
        if on { pinned.append(app) }
    }

    func setIgnored(_ app: KnownApp, _ on: Bool) {
        ignored.removeAll { $0.key == app.key }
        if on {
            ignored.append(app)
            pinned.removeAll { $0.key == app.key }
        }
    }

    // MARK: EQ presets

    var allPresets: [EQPreset] { EQPreset.builtIn + userPresets }

    func preset(id: String?) -> EQPreset? {
        guard let id else { return nil }
        return allPresets.first { $0.id == id }
    }

    @discardableResult
    func saveUserPreset(name: String, gains: [Float]) -> EQPreset {
        let preset = EQPreset(id: "user-\(UUID().uuidString)", name: name, gains: gains, category: .user)
        userPresets.append(preset)
        return preset
    }

    func renameUserPreset(_ id: String, to name: String) {
        guard let i = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[i].name = name
    }

    func deleteUserPreset(_ id: String) {
        userPresets.removeAll { $0.id == id }
        // Apps using it keep their gains, now labelled "Custom".
        for (key, value) in apps where value.eq.presetID == id {
            apps[key]?.eq.presetID = nil
        }
    }

    // MARK: Device priority

    /// Rank of a device UID; unknown devices sort after every ranked one.
    func priority(of uid: String) -> Int { devicePriority.firstIndex(of: uid) ?? Int.max }

    func notePriorityCandidate(_ uid: String) {
        if !devicePriority.contains(uid) { devicePriority.append(uid) }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        func store<T: Encodable>(_ value: T, _ key: String) {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        }
        store(apps, Keys.apps)
        store(pinned, Keys.pinned)
        store(ignored, Keys.ignored)
        store(userPresets, Keys.userPresets)
        store(hotkeys, Keys.hotkeys)
        defaults.set(iconStyle.rawValue, forKey: Keys.iconStyle)
        defaults.set(popupStyle.rawValue, forKey: Keys.popupStyle)
        defaults.set(volumeStep.rawValue, forKey: Keys.volumeStep)
        defaults.set(pauseOthersOnPlay, forKey: Keys.pauseOthers)
        defaults.set(showDevices, forKey: Keys.showDevices)
        defaults.set(showInactivePinned, forKey: Keys.showInactivePinned)
        defaults.set(devicePriority, forKey: Keys.devicePriority)
        defaults.set(autoSwitchToPreferred, forKey: Keys.autoSwitch)
        defaults.set(Array(hiddenDevices), forKey: Keys.hiddenDevices)
    }

    /// 0.4.1 and older shipped as com.voulum.app. The first launch under the new
    /// identifier copies that domain over, so volumes, presets and shortcuts
    /// survive the rename. Keys already set here win.
    static let legacyDomain = "com.voulum.app"

    private static func migrateLegacyDomain(into defaults: UserDefaults) {
        guard Bundle.main.bundleIdentifier != legacyDomain,
              !defaults.bool(forKey: Keys.migratedLegacyDomain),
              let old = UserDefaults.standard.persistentDomain(forName: legacyDomain) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: Keys.migratedLegacyDomain)
        log.info("Copied \(old.count) settings from \(legacyDomain, privacy: .public)")
    }

    private enum Keys {
        static let migratedLegacyDomain = "migratedLegacyDomain"
        static let apps = "apps.v1"
        static let pinned = "pinnedApps"
        static let ignored = "ignoredApps"
        static let userPresets = "userEQPresets"
        static let hotkeys = "hotkeys"
        static let iconStyle = "menuBarIconStyle"
        static let popupStyle = "popupStyle"
        static let volumeStep = "volumeStep"
        static let pauseOthers = "pauseOthersOnPlay"          // 0.4.x key
        static let showDevices = "outputSectionExpanded"      // 0.4.x key
        static let showInactivePinned = "showInactivePinned"
        static let devicePriority = "devicePriority"
        static let autoSwitch = "autoSwitchToPreferredDevice"
        static let hiddenDevices = "hiddenOutputUIDs"         // 0.4.x key
    }
}
