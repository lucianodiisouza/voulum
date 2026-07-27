import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Enumerates every process Core Audio knows about and publishes the ones
/// currently playing audio. The list is refreshed when the menu opens and
/// polled on a light timer while it stays open (see `beginLiveUpdates`).
@MainActor
final class AudioProcessController: ObservableObject {

    static let shared = AudioProcessController()

    /// All audio-capable processes, most-recently-active first-ish.
    @Published private(set) var processes: [AudioProcess] = []

    /// Just the ones making sound right now — what the menu shows by default.
    var playing: [AudioProcess] {
        processes.filter(\.isPlaying).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Poll timer that runs only while the menu is open.
    private var pollTimer: Timer?
    /// How often to re-scan while the menu is open.
    private let pollInterval: TimeInterval = 1.0

    // MARK: Per-app volume state

    /// Active taps, one per app the user has adjusted. Created lazily.
    private var taps: [AudioObjectID: ProcessTap] = [:]
    /// Slider position per app (1.0 = unmodified). Persisted only in memory.
    @Published private(set) var volumes: [AudioObjectID: Float] = [:]
    @Published private(set) var muted: Set<AudioObjectID> = []
    /// Last error encountered creating a tap (e.g. permission denied), per app.
    @Published private(set) var tapErrors: [AudioObjectID: String] = [:]

    /// Whether we've ever successfully tapped audio. macOS persists the actual
    /// TCC grant, and we mirror it here so the UI stops nagging about permission
    /// once it's been given — remembered across launches via `UserDefaults`.
    @Published private(set) var audioPermissionGranted: Bool =
        UserDefaults.standard.bool(forKey: "hasGrantedAudioTap")
    private static let permissionKey = "hasGrantedAudioTap"

    /// Range the UI exposes: full mute up to 2x boost.
    static let maxGain: Float = 2.0

    func volume(for process: AudioProcess) -> Float { volumes[process.id] ?? 1.0 }
    func isMuted(_ process: AudioProcess) -> Bool { muted.contains(process.id) }

    func setVolume(_ value: Float, for process: AudioProcess) {
        volumes[process.id] = value
        if value > 0 { muted.remove(process.id) }
        applyGain(for: process)
    }

    func toggleMute(_ process: AudioProcess) {
        if muted.contains(process.id) {
            muted.remove(process.id)
        } else {
            muted.insert(process.id)
        }
        applyGain(for: process)
    }

    /// Effective gain = 0 when muted, else the slider value.
    private func applyGain(for process: AudioProcess) {
        let effective: Float = muted.contains(process.id) ? 0 : (volumes[process.id] ?? 1.0)
        guard let tap = ensureTap(for: process) else { return }
        tap.gain = effective
    }

    /// Lazily create + activate a tap the first time an app is adjusted.
    private func ensureTap(for process: AudioProcess) -> ProcessTap? {
        if let existing = taps[process.id] { return existing }
        let tap = ProcessTap(process: process)
        do {
            try tap.activate()
            taps[process.id] = tap
            tapErrors[process.id] = nil
            rememberPermissionGranted()
            return tap
        } catch {
            let message = String(describing: error)
            tapErrors[process.id] = message
            log.error("Tap activation failed for \(process.name, privacy: .public): \(message, privacy: .public)")
            return nil
        }
    }

    private func rememberPermissionGranted() {
        guard !audioPermissionGranted else { return }
        audioPermissionGranted = true
        UserDefaults.standard.set(true, forKey: Self.permissionKey)
    }

    /// Tear down taps whose process has exited so we don't leak aggregate devices.
    private func pruneVanishedTaps(livingIDs: Set<AudioObjectID>) {
        for (id, tap) in taps where !livingIDs.contains(id) {
            tap.invalidate()
            taps.removeValue(forKey: id)
            volumes.removeValue(forKey: id)
            muted.remove(id)
            tapErrors.removeValue(forKey: id)
        }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        log.info("Voulum starting; enumerating audio processes")
        reload()
        if ProcessInfo.processInfo.environment["VOULUM_SELFTEST"] != nil {
            runSelfTest()
        }
    }

    // MARK: Live updates (menu-open driven)

    /// Call when the menu opens: refresh immediately, then poll while it's open.
    /// Polling — rather than Core Audio property listeners — keeps this simple
    /// and reliably catches apps that start/stop playing while the menu is up.
    func beginLiveUpdates() {
        reload()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Call when the menu closes: stop polling so we do no work in the background.
    func endLiveUpdates() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Headless smoke test of the tap pipeline (no UI needed). Taps the first
    /// playing process, ramps gain 1.0 -> 0.3 -> 0 -> 1.0, and logs each step.
    /// Enable with the VOULUM_SELFTEST env var.
    private func runSelfTest() {
        func note(_ s: String) {
            FileHandle.standardError.write("VOULUM SELFTEST: \(s)\n".data(using: .utf8)!)
            log.info("SELFTEST: \(s, privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            note("playing count = \(self.playing.count); all = \(self.processes.count)")
            guard let target = self.playing.first else {
                note("nothing playing to tap")
                return
            }
            note("tapping \(target.name) (pid \(target.pid))")
            let tap = ProcessTap(process: target)
            do {
                try tap.activate()
                note("tap activated OK")
            } catch {
                note("activate FAILED: \(String(describing: error))")
                return
            }
            self.taps[target.id] = tap
            let ramp: [Float] = [1.0, 0.3, 0.0, 1.0]
            for (i, g) in ramp.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.0) {
                    tap.gain = g
                    note("gain -> \(g)")
                }
            }
        }
    }

    // MARK: Enumeration

    func reload() {
        do {
            let objectIDs: [AudioObjectID] = try AudioObjectID.system.readArray(
                kAudioHardwarePropertyProcessObjectList)

            var result: [AudioProcess] = []
            result.reserveCapacity(objectIDs.count)
            for objectID in objectIDs where objectID.isValid {
                guard let process = makeProcess(objectID) else { continue }
                result.append(process)
            }
            self.processes = result
            pruneVanishedTaps(livingIDs: Set(result.map(\.id)))
        } catch {
            log.error("Failed to read process list: \(String(describing: error))")
        }
    }

    private func makeProcess(_ objectID: AudioObjectID) -> AudioProcess? {
        let pid: pid_t = (try? objectID.read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
        guard pid > 0 else { return nil }

        let bundleID: String? = try? objectID.readCF(kAudioProcessPropertyBundleID, as: String.self) ?? nil
        let isRunningOutput: UInt32 = (try? objectID.read(
            kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

        return AudioProcess(objectID: objectID,
                            pid: pid,
                            bundleID: bundleID,
                            isPlaying: isRunningOutput != 0)
    }
}
