import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// One real audio device (speakers, a headset, a USB interface, a display …).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let hasOutput: Bool
    let hasInput: Bool

    var symbol: String { Self.symbol(transport: transport, name: name, input: !hasOutput) }

    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return String(localized: "Built-in")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: return String(localized: "Virtual")
        default: return String(localized: "Audio device")
        }
    }

    /// The device-type glyph macOS itself uses in its Sound menu. Brand names
    /// win (AirPods / HomePod / Beats), then the transport type.
    static func symbol(transport: UInt32, name: String, input: Bool = false) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("beats") { return "beats.headphones" }
        if input {
            return headphoneLike(name) ? "headphones" : "mic.fill"
        }
        if n.contains("display") { return "display" }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return headphoneLike(name) ? "headphones" : "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual:
            return "waveform.circle"
        default:
            return headphoneLike(name) ? "headphones" : "laptopcomputer"
        }
    }

    /// Bluetooth/USB covers both headsets and speakers, so the name is the only
    /// signal. Several languages, since names come from the hardware's locale.
    static func headphoneLike(_ name: String) -> Bool {
        let n = name.lowercased()
        let keywords = [
            "airpod", "headphone", "headset", "buds", "beats", "earphone", "earbud",
            "fone", "auricular", "audífono", "audifono", "écouteur", "ecouteur",
            "casque", "kopfhörer", "kopfhorer",
        ]
        return keywords.contains { n.contains($0) }
    }
}

/// Live level of one device direction.
struct DeviceLevel: Equatable {
    var volume: Float = 1
    var muted = false
    /// False for devices whose hardware exposes no volume (many HDMI/DP outputs).
    var adjustable = false
}

/// Owns the system side of audio: which devices exist, which are default, and
/// their hardware volume/mute. Per-app taps live in `AudioEngine`, which
/// subscribes to `changes` to re-route when devices come and go.
@MainActor
final class DeviceController: ObservableObject {

    static let shared = DeviceController()

    @Published private(set) var outputs: [AudioDevice] = []
    @Published private(set) var inputs: [AudioDevice] = []
    @Published private(set) var defaultOutputID: AudioObjectID = .unknown
    @Published private(set) var defaultInputID: AudioObjectID = .unknown
    @Published private(set) var outputLevels: [AudioObjectID: DeviceLevel] = [:]
    @Published private(set) var inputLevels: [AudioObjectID: DeviceLevel] = [:]

    /// Fires after the device list or the default output changes.
    let changes = PassthroughSubject<Void, Never>()

    private let prefs = Preferences.shared
    private let halQueue = DispatchQueue(label: "dev.oprimo.voulum.devices", qos: .userInitiated)
    private var systemToken: PropertyListenerToken?
    private var defaultVolumeToken: PropertyListenerToken?
    private var knownOutputUIDs: Set<String>?
    private var started = false

    var defaultOutput: AudioDevice? { outputs.first { $0.id == defaultOutputID } }
    var defaultInput: AudioDevice? { inputs.first { $0.id == defaultInputID } }
    var defaultOutputLevel: DeviceLevel { outputLevels[defaultOutputID] ?? DeviceLevel() }

    /// Devices shown in the popup: everything not hidden, plus the current
    /// default (hiding the device you're listening on would leave you stranded).
    var visibleOutputs: [AudioDevice] {
        outputs.filter { !prefs.hiddenDevices.contains($0.uid) || $0.id == defaultOutputID }
    }
    var visibleInputs: [AudioDevice] {
        inputs.filter { !prefs.hiddenDevices.contains($0.uid) || $0.id == defaultInputID }
    }

    func output(uid: String) -> AudioDevice? { outputs.first { $0.uid == uid } }

    func start() {
        guard !started else { return }
        started = true
        systemToken = AudioObjectID.system.listen(
            to: [kAudioHardwarePropertyDevices,
                 kAudioHardwarePropertyDefaultOutputDevice,
                 kAudioHardwarePropertyDefaultInputDevice],
            queue: halQueue) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    // MARK: Actions

    func setDefault(_ device: AudioDevice) {
        let selector = device.hasOutput ? kAudioHardwarePropertyDefaultOutputDevice
                                        : kAudioHardwarePropertyDefaultInputDevice
        if device.hasOutput { defaultOutputID = device.id } else { defaultInputID = device.id }
        let id = device.id
        halQueue.async {
            do {
                try AudioObjectID.system.write(selector, to: id)
                if selector == kAudioHardwarePropertyDefaultOutputDevice {
                    // Keep alerts on the same device, as the Sound menu does.
                    try? AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, to: id)
                }
            } catch {
                log.error("Set default device failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func setVolume(_ value: Float, for device: AudioDevice, input: Bool = false) {
        let clamped = max(0, min(1, value))
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        mutateLevel(device.id, input: input) {
            $0.volume = clamped
            if clamped > 0 { $0.muted = false }
        }
        let id = device.id
        halQueue.async {
            id.setVirtualMainVolume(clamped, scope: scope)
            // Raising the level should also lift a hardware mute, or the slider
            // moves and nothing comes out.
            if clamped > 0, id.isSettable(kAudioDevicePropertyMute, scope: scope) {
                try? id.write(kAudioDevicePropertyMute, scope: scope, to: UInt32(0))
            }
        }
    }

    func toggleMute(_ device: AudioDevice, input: Bool = false) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let current = (input ? inputLevels : outputLevels)[device.id] ?? DeviceLevel()
        let newValue = !current.muted
        mutateLevel(device.id, input: input) { $0.muted = newValue }
        let id = device.id
        let restoreVolume = current.volume == 0 ? Float(0.25) : nil
        halQueue.async {
            if id.isSettable(kAudioDevicePropertyMute, scope: scope) {
                try? id.write(kAudioDevicePropertyMute, scope: scope, to: UInt32(newValue ? 1 : 0))
            } else if newValue {
                id.setVirtualMainVolume(0, scope: scope)
            }
            if !newValue, let restoreVolume { id.setVirtualMainVolume(restoreVolume, scope: scope) }
        }
    }

    /// Nudge the default output by `delta` (used by the speaker row's scroll).
    func stepDefaultOutput(by delta: Float) {
        guard let device = defaultOutput else { return }
        setVolume(defaultOutputLevel.volume + delta, for: device)
    }

    private func mutateLevel(_ id: AudioObjectID, input: Bool, _ change: (inout DeviceLevel) -> Void) {
        if input {
            var level = inputLevels[id] ?? DeviceLevel()
            change(&level)
            inputLevels[id] = level
        } else {
            var level = outputLevels[id] ?? DeviceLevel()
            change(&level)
            outputLevels[id] = level
        }
    }

    // MARK: Refresh

    func refresh() {
        halQueue.async { [weak self] in
            let all = Self.enumerateDevices()
            let defOut: AudioObjectID = (try? AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)) ?? .unknown
            let defIn: AudioObjectID = (try? AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID.unknown)) ?? .unknown
            Task { @MainActor in self?.apply(all, defaultOutput: defOut, defaultInput: defIn) }
        }
    }

    private func apply(_ all: [AudioDevice], defaultOutput: AudioObjectID, defaultInput: AudioObjectID) {
        let outs = all.filter(\.hasOutput)
        for device in outs { prefs.notePriorityCandidate(device.uid) }
        let sorted = outs.sorted {
            let (a, b) = (prefs.priority(of: $0.uid), prefs.priority(of: $1.uid))
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let defaultChanged = defaultOutput != defaultOutputID
        let listChanged = Set(outs.map(\.uid)) != Set(outputs.map(\.uid))

        outputs = sorted
        inputs = all.filter(\.hasInput)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        defaultOutputID = defaultOutput
        defaultInputID = defaultInput

        if defaultChanged || defaultVolumeToken == nil { watchDefaultOutputVolume() }
        refreshLevels()
        autoSwitchIfNeeded(newOutputs: outs)
        if defaultChanged || listChanged { changes.send() }
    }

    /// A device the user ranked above the current default just connected:
    /// switch to it, the way plugging in headphones takes over the speakers.
    private func autoSwitchIfNeeded(newOutputs: [AudioDevice]) {
        let uids = Set(newOutputs.map(\.uid))
        defer { knownOutputUIDs = uids }
        guard let known = knownOutputUIDs, prefs.autoSwitchToPreferred else { return }
        let arrivals = newOutputs.filter { !known.contains($0.uid) && !prefs.hiddenDevices.contains($0.uid) }
        guard let best = arrivals.min(by: { prefs.priority(of: $0.uid) < prefs.priority(of: $1.uid) }) else { return }
        let currentRank = defaultOutput.map { prefs.priority(of: $0.uid) } ?? Int.max
        if prefs.priority(of: best.uid) < currentRank {
            log.info("Auto-switching output to \(best.name, privacy: .public)")
            setDefault(best)
        }
    }

    /// Re-read every visible device's hardware level.
    func refreshLevels() {
        let outs = outputs.map(\.id)
        let ins = inputs.map(\.id)
        halQueue.async { [weak self] in
            let o = Dictionary(uniqueKeysWithValues: outs.map { ($0, Self.readLevel($0, scope: kAudioObjectPropertyScopeOutput)) })
            let i = Dictionary(uniqueKeysWithValues: ins.map { ($0, Self.readLevel($0, scope: kAudioObjectPropertyScopeInput)) })
            Task { @MainActor in
                guard let self else { return }
                if self.outputLevels != o { self.outputLevels = o }
                if self.inputLevels != i { self.inputLevels = i }
            }
        }
    }

    /// The menu-bar icon tracks the default output's volume even while the
    /// popup is closed, so follow that one device with a listener.
    private func watchDefaultOutputVolume() {
        defaultVolumeToken?.cancel()
        let id = defaultOutputID
        guard id.isValid else { defaultVolumeToken = nil; return }
        defaultVolumeToken = id.listen(
            to: [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                 kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute],
            scope: kAudioObjectPropertyScopeOutput, queue: halQueue) { [weak self] _, _ in
            let level = Self.readLevel(id, scope: kAudioObjectPropertyScopeOutput)
            Task { @MainActor in
                guard let self, self.outputLevels[id] != level else { return }
                self.outputLevels[id] = level
            }
        }
    }

    nonisolated private static func readLevel(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> DeviceLevel {
        let volume = id.virtualMainVolume(scope: scope)
        let mute: UInt32 = (try? id.read(kAudioDevicePropertyMute, scope: scope, default: UInt32(0))) ?? 0
        return DeviceLevel(volume: volume ?? 1,
                           muted: mute != 0,
                           adjustable: volume != nil && id.canSetVirtualMainVolume(scope: scope))
    }

    // MARK: Enumeration (off-main)

    /// Every real, selectable device. Aggregates and Voulum's own private tap
    /// devices are filtered out — they must never be offered as outputs.
    nonisolated static func enumerateDevices() -> [AudioDevice] {
        guard let ids: [AudioObjectID] = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices) else { return [] }
        var result: [AudioDevice] = []
        for id in ids where id.isValid {
            let outStreams: [AudioStreamID] = (try? id.readArray(
                kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            let inStreams: [AudioStreamID] = (try? id.readArray(
                kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
            guard !outStreams.isEmpty || !inStreams.isEmpty else { continue }

            let transport: UInt32 = (try? id.read(kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            let uid: String = (try? id.readCF(kAudioDevicePropertyDeviceUID, as: String.self) ?? nil) ?? ""
            guard !uid.isEmpty,
                  transport != kAudioDeviceTransportTypeAggregate,
                  !uid.hasPrefix(AppTap.aggregateUIDPrefix) else { continue }
            // Hidden helper devices (e.g. the CADefaultDeviceAggregate) aren't
            // meant for users.
            let hidden: UInt32 = (try? id.read(kAudioDevicePropertyIsHidden, default: UInt32(0))) ?? 0
            guard hidden == 0 else { continue }

            let name: String = (try? id.readCF(kAudioObjectPropertyName, as: String.self) ?? nil) ?? String(localized: "Unknown Device")
            result.append(AudioDevice(id: id, uid: uid, name: name, transport: transport,
                                      hasOutput: !outStreams.isEmpty, hasInput: !inStreams.isEmpty))
        }
        return result
    }
}

// Split devices that are both (a headset) into one entry per direction, so the
// output list and input list can each hold their own copy.
private extension Array where Element == AudioDevice {
    func filter(_ keyPath: KeyPath<AudioDevice, Bool>) -> [AudioDevice] {
        compactMap { device in
            guard device[keyPath: keyPath] else { return nil }
            let isOutput = keyPath == \AudioDevice.hasOutput
            return AudioDevice(id: device.id, uid: device.uid, name: device.name, transport: device.transport,
                               hasOutput: isOutput, hasInput: !isOutput)
        }
    }
}
