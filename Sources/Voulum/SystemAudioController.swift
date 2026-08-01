import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// One selectable system audio output device (Mac speakers, a Bluetooth headset,
/// AirPlay, an HDMI display, …).
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    /// Core Audio transport type (`kAudioDeviceTransportType*`) — drives the icon.
    let transport: UInt32

    /// SF Symbol representing this device in the picker — the specific device-type
    /// glyph macOS shows in its own Sound menu (AirPods, HomePod, headphones, …).
    var symbolName: String {
        SystemAudioController.deviceSymbol(transport: transport, name: name)
    }
}

/// Owns the *system* side of audio — the output-device list, which one is
/// current, and its mute/volume — so Voulum can stand in for the macOS menu-bar
/// volume control: pick where sound goes, and show an icon that matches it.
///
/// Separate from `AudioProcessController` (which owns per-app taps): this is
/// hardware/output state, that is per-process state. Both watch the default
/// output device, for different reasons — this one to update the picker + icon,
/// the other to re-route active taps.
@MainActor
final class SystemAudioController: ObservableObject {

    static let shared = SystemAudioController()

    /// All real output devices, name-sorted. Excludes Voulum's own private
    /// aggregates and other non-selectable virtual/aggregate devices. This is the
    /// full set shown in the "manage" list; `visibleDevices` is what the picker uses.
    @Published private(set) var devices: [AudioOutputDevice] = []

    /// UIDs the user has hidden from the picker (e.g. monitors they never send
    /// audio to). Persisted across launches, keyed by the stable device UID.
    @Published private(set) var hiddenUIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: SystemAudioController.hiddenKey) ?? [])
    private static let hiddenKey = "hiddenOutputUIDs"

    /// Devices the picker actually offers: everything not hidden, plus the current
    /// default (never hide the output you're using — you'd be unable to see it).
    var visibleDevices: [AudioOutputDevice] {
        devices.filter { !hiddenUIDs.contains($0.uid) || $0.id == currentDeviceID }
    }

    func isHidden(_ device: AudioOutputDevice) -> Bool { hiddenUIDs.contains(device.uid) }

    /// Show or hide a device in the picker; persisted immediately.
    func setHidden(_ device: AudioOutputDevice, _ hidden: Bool) {
        guard !device.uid.isEmpty else { return }
        if hidden { hiddenUIDs.insert(device.uid) } else { hiddenUIDs.remove(device.uid) }
        UserDefaults.standard.set(Array(hiddenUIDs), forKey: Self.hiddenKey)
    }
    /// The current default output device's object id.
    @Published private(set) var currentDeviceID: AudioObjectID = .unknown
    /// System output mute (or volume pinned to 0). Reflected in the icon.
    @Published private(set) var muted: Bool = false
    /// System output volume, 0...1. Best-effort — some devices expose no main
    /// volume element, in which case this stays at its last known value.
    @Published private(set) var volume: Float = 1

    var current: AudioOutputDevice? { devices.first { $0.id == currentDeviceID } }

    /// The menu-bar glyph: adapts to the output device type, mute, and (for
    /// speakers) the volume level.
    var menuBarSymbol: String {
        Self.menuBarSymbol(transport: current?.transport ?? kAudioDeviceTransportTypeBuiltIn,
                           name: current?.name ?? "", muted: muted, volume: volume)
    }

    /// Serial queue for the blocking Core Audio HAL calls, mirroring the pattern
    /// in `AudioProcessController` so we never touch `coreaudiod` on the main thread.
    private let halQueue = DispatchQueue(label: "com.voulum.system-audio", qos: .userInitiated)
    private var started = false

    // Retained listener blocks (Core Audio copies them, but we keep references so
    // ARC doesn't reap them out from under the HAL). The default-device and
    // device-list watches share one block; the vol/mute watch moves between
    // devices so it needs its own.
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceVolMuteListener: AudioObjectPropertyListenerBlock?
    /// The device the vol/mute listener is currently attached to.
    private var listenedDeviceID: AudioObjectID = .unknown

    func start() {
        guard !started else { return }
        started = true
        observeSystem()
        refresh()
    }

    // MARK: Actions

    /// Make `device` the system default output. The default-device listener then
    /// refreshes the picker + icon; `AudioProcessController` re-routes taps.
    func setDefaultOutput(_ device: AudioOutputDevice) {
        let id = device.id
        halQueue.async {
            do { try AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, to: id) }
            catch { log.error("Set default output failed: \(String(describing: error), privacy: .public)") }
        }
        // Optimistic — snap the UI immediately; the listener reconciles.
        currentDeviceID = id
        refreshVolumeMute()
    }

    /// Set the system output volume (0...1) on the current default device.
    func setVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        let unmute = clamped > 0
        volume = clamped
        muted = !unmute
        let dev = currentDeviceID
        guard dev.isValid else { return }
        halQueue.async {
            try? dev.write(kAudioDevicePropertyVolumeScalar,
                           scope: kAudioObjectPropertyScopeOutput, to: Float32(clamped))
            // Also clear the hardware mute flag when raising the level: if the
            // device was muted via `toggleMute`, writing the scalar alone leaves
            // it muted, so the slider moves but nothing comes out.
            try? dev.write(kAudioDevicePropertyMute,
                           scope: kAudioObjectPropertyScopeOutput, to: UInt32(unmute ? 0 : 1))
        }
    }

    /// Toggle system output mute on the current default device.
    func toggleMute() {
        let dev = currentDeviceID
        let newValue = !muted
        muted = newValue
        guard dev.isValid else { return }
        halQueue.async {
            try? dev.write(kAudioDevicePropertyMute,
                           scope: kAudioObjectPropertyScopeOutput, to: UInt32(newValue ? 1 : 0))
        }
    }

    // MARK: Refresh

    /// Re-enumerate output devices and re-read the current default + its vol/mute.
    func refresh() {
        halQueue.async { [weak self] in
            let devices = Self.enumerateOutputDevices()
            let current: AudioObjectID = (try? AudioObjectID.system.read(
                kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)) ?? .unknown
            Task { @MainActor in
                guard let self else { return }
                self.devices = devices
                self.currentDeviceID = current
                self.retargetVolMuteListener(to: current)
                self.refreshVolumeMute()
            }
        }
    }

    /// Re-read mute + volume from the current default device.
    private func refreshVolumeMute() {
        let dev = currentDeviceID
        guard dev.isValid else { muted = false; volume = 1; return }
        halQueue.async { [weak self] in
            let muteVal: UInt32 = (try? dev.read(
                kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
                default: UInt32(0))) ?? 0
            let vol: Float32? = try? dev.read(
                kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput,
                default: Float32(-1))
            Task { @MainActor in
                guard let self else { return }
                if let vol, vol >= 0 { self.volume = Float(vol) }
                self.muted = muteVal != 0 || self.volume == 0
            }
        }
    }

    // MARK: Listeners

    /// Watch the system default output device and the device list (plug/unplug).
    private func observeSystem() {
        let refreshBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        systemListener = refreshBlock

        var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(.system, &defaultAddr, halQueue, refreshBlock)
        AudioObjectAddPropertyListenerBlock(.system, &devicesAddr, halQueue, refreshBlock)
    }

    /// Move the volume/mute listener onto the new default device so the icon
    /// tracks the volume keys for whatever device is now current.
    private func retargetVolMuteListener(to id: AudioObjectID) {
        if let block = deviceVolMuteListener, listenedDeviceID.isValid {
            var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
            var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectRemovePropertyListenerBlock(listenedDeviceID, &volAddr, halQueue, block)
            AudioObjectRemovePropertyListenerBlock(listenedDeviceID, &muteAddr, halQueue, block)
        }
        listenedDeviceID = id
        guard id.isValid else { deviceVolMuteListener = nil; return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshVolumeMute() }
        }
        deviceVolMuteListener = block
        var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        var muteAddr = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectAddPropertyListenerBlock(id, &volAddr, halQueue, block)
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, halQueue, block)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Enumeration (off-main)

    /// Every device that has output streams and is a real, selectable endpoint.
    /// Filters out aggregate/virtual devices — including Voulum's own private
    /// tap aggregates, which must never appear as a pickable output.
    nonisolated private static func enumerateOutputDevices() -> [AudioOutputDevice] {
        guard let ids: [AudioObjectID] = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices) else { return [] }

        var result: [AudioOutputDevice] = []
        for id in ids where id.isValid {
            // Must have at least one output stream to be an output device.
            let streams: [AudioStreamID] = (try? id.readArray(
                kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            guard !streams.isEmpty else { continue }

            let transport: UInt32 = (try? id.read(
                kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
            let uid: String = (try? id.readCF(kAudioDevicePropertyDeviceUID, as: String.self) ?? nil) ?? ""

            // Skip aggregate/virtual endpoints (our private tap aggregates, other
            // apps' aggregates) — they aren't user-selectable outputs.
            guard transport != kAudioDeviceTransportTypeAggregate,
                  transport != kAudioDeviceTransportTypeVirtual,
                  !uid.hasPrefix(ProcessTap.aggregateUIDPrefix) else { continue }

            let name: String = (try? id.readCF(kAudioObjectPropertyName, as: String.self) ?? nil) ?? "Unknown Device"
            result.append(AudioOutputDevice(id: id, uid: uid, name: name, transport: transport))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Icon mapping

    /// The menu-bar glyph. Kept deliberately simple so it stays legible at
    /// menu-bar size: mute wins, then a few device families, otherwise a
    /// volume-scaled speaker. (The picker uses `deviceSymbol` for finer icons.)
    nonisolated static func menuBarSymbol(transport: UInt32, name: String, muted: Bool, volume: Float) -> String {
        if muted { return "speaker.slash.fill" }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return headphoneLike(name) ? "headphones" : "hifispeaker.fill"
        default: // Built-in speakers, and anything else we don't special-case.
            return headphoneLike(name) ? "headphones" : speakerForVolume(volume)
        }
    }

    /// The device-specific glyph macOS itself shows in the Sound menu. Brand name
    /// wins (AirPods/HomePod/Beats), then transport type, so the picker reads the
    /// same as the system control.
    nonisolated static func deviceSymbol(transport: UInt32, name: String) -> String {
        let n = name.lowercased()
        // Brand-specific — matches the icons in macOS's own output list.
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("display") { return "display" }

        switch transport {
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return headphoneLike(name) ? "headphones" : "hifispeaker.fill"
        default: // Built-in speakers.
            return "speaker.wave.2.fill"
        }
    }

    /// Guess whether a device is worn on the head from its name (Bluetooth/USB
    /// covers both headsets and speakers, so the name is the only signal). Covers
    /// several languages, since device names come from the hardware in whatever
    /// locale it was set up — e.g. "Fone"/"fones" (pt), "auricular" (es),
    /// "écouteur"/"casque" (fr), "Kopfhörer" (de).
    nonisolated private static func headphoneLike(_ name: String) -> Bool {
        let n = name.lowercased()
        let keywords = [
            "airpod", "headphone", "headset", "buds", "beats", "earphone", "earbud",
            "fone", "auricular", "audífono", "audifono", "écouteur", "ecouteur",
            "casque", "kopfhörer", "kopfhorer",
        ]
        return keywords.contains { n.contains($0) }
    }

    /// A speaker glyph whose wave count tracks the volume level.
    nonisolated private static func speakerForVolume(_ volume: Float) -> String {
        switch volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default:      return "speaker.wave.3.fill"
        }
    }
}
