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

    /// Serial queue for every blocking Core Audio HAL call (enumeration, tap
    /// activation/teardown, leak reaping). Keeps `coreaudiod` round-trips off the
    /// main thread so a slow or wedged HAL never freezes the menu-bar UI.
    private let halQueue = DispatchQueue(label: "com.voulum.hal", qos: .userInitiated)
    /// Coalesce reloads: skip a scan if the previous one is still on the HAL queue.
    private var reloadInFlight = false

    // MARK: Now-playing metadata

    /// Latest track metadata per process, for the scriptable media apps we
    /// support (Spotify / Apple Music). Absent for everything else — see
    /// `NowPlayingService` for why the generic path is unavailable.
    @Published private(set) var nowPlaying: [AudioObjectID: NowPlaying] = [:]

    /// Serial queue for the blocking AppleScript round-trips that read track
    /// metadata. Kept off the main thread and off the HAL queue.
    private let scriptQueue = DispatchQueue(label: "com.voulum.nowplaying", qos: .userInitiated)
    /// Skip a metadata sweep if the previous batch is still running.
    private var nowPlayingRefreshInFlight = false

    func nowPlaying(for process: AudioProcess) -> NowPlaying? { nowPlaying[process.id] }

    /// Send a transport command (play/pause, next, previous) to the media app
    /// backing this process, if it's one we can script. The play/pause icon is
    /// flipped optimistically so it responds instantly; the next poll (or the
    /// short follow-up refresh below) reconciles it with the app's real state.
    func sendMediaCommand(_ command: NowPlayingService.Command, to process: AudioProcess) {
        guard let bundleID = process.resolvedBundleID,
              NowPlayingService.supports(bundleID) else { return }

        if command == .playPause, let current = nowPlaying[process.id] {
            nowPlaying[process.id] = NowPlaying(title: current.title,
                                                artist: current.artist,
                                                album: current.album,
                                                isPlaying: !current.isPlaying)
        }

        scriptQueue.async { [weak self] in
            NowPlayingService.send(command, bundleID: bundleID)
            // Give the app a beat to settle on the new track/state, then pull
            // fresh metadata so next/previous update the title promptly.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.refreshNowPlaying()
            }
        }
    }

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

    /// Lazily create a tap the first time an app is adjusted, then activate it off
    /// the main thread. The tap is registered immediately so the caller's
    /// `tap.gain = …` write lands on the right object; the pointer-backed gain is
    /// read once the IOProc actually starts, so setting it before activation
    /// finishes is fine. Activation makes blocking HAL calls, so it must not run
    /// on the main thread — that was the source of the launch/interaction hang.
    private func ensureTap(for process: AudioProcess) -> ProcessTap? {
        if let existing = taps[process.id] { return existing }
        let tap = ProcessTap(process: process)
        taps[process.id] = tap
        tapErrors[process.id] = nil

        let id = process.id
        let name = process.name  // resolve AppKit-backed name on the main thread
        halQueue.async { [weak self] in
            do {
                try tap.activate()
                Task { @MainActor in self?.rememberPermissionGranted() }
            } catch {
                let message = String(describing: error)
                log.error("Tap activation failed for \(name, privacy: .public): \(message, privacy: .public)")
                Task { @MainActor in
                    guard let self else { return }
                    // Only clear it if this exact tap is still the registered one.
                    if self.taps[id] === tap {
                        self.taps.removeValue(forKey: id)
                        self.tapErrors[id] = message
                    }
                }
            }
        }
        return tap
    }

    private func rememberPermissionGranted() {
        guard !audioPermissionGranted else { return }
        audioPermissionGranted = true
        UserDefaults.standard.set(true, forKey: Self.permissionKey)
    }

    /// Tear down taps whose process has exited so we don't leak aggregate devices.
    private func pruneVanishedTaps(livingIDs: Set<AudioObjectID>) {
        for (id, tap) in taps where !livingIDs.contains(id) {
            halQueue.async { tap.invalidate() }  // blocking HAL teardown, off-main
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
        // Sweep away any aggregate devices / taps leaked by a previous crash
        // before we start creating new ones — they otherwise pile up in
        // coreaudiod and can wedge the whole audio HAL.
        halQueue.async { ProcessTap.reapLeakedDevices() }
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

    /// Kick off a scan on the HAL queue and publish the result back on the main
    /// thread. Enumeration hits `coreaudiod`, so it must not run on the main
    /// thread. Coalesced: a scan that fires while another is still running is
    /// dropped (the poll will pick it up next tick).
    func reload() {
        guard !reloadInFlight else { return }
        reloadInFlight = true
        halQueue.async { [weak self] in
            let result = Self.enumerateProcesses()
            Task { @MainActor in
                guard let self else { return }
                self.reloadInFlight = false
                self.processes = result
                let living = Set(result.map(\.id))
                self.pruneVanishedTaps(livingIDs: living)
                self.nowPlaying = self.nowPlaying.filter { living.contains($0.key) }
                self.refreshNowPlaying()
            }
        }
    }

    /// Read track metadata for the currently playing processes that come from a
    /// scriptable media app, off the main thread, and publish the results.
    /// Coalesced so a slow AppleScript round-trip can't pile up behind the poll.
    private func refreshNowPlaying() {
        guard !nowPlayingRefreshInFlight else { return }

        // Resolve the scripting targets on the main thread (AppKit-backed
        // bundle-id lookup), then hand just the ids off to the script queue.
        let targets: [(id: AudioObjectID, bundleID: String)] = playing.compactMap { process in
            guard let bundleID = process.resolvedBundleID,
                  NowPlayingService.supports(bundleID) else { return nil }
            return (process.id, bundleID)
        }

        // Drop metadata for anything no longer playing (e.g. paused mid-session).
        let playingIDs = Set(targets.map(\.id))
        if nowPlaying.keys.contains(where: { !playingIDs.contains($0) }) {
            nowPlaying = nowPlaying.filter { playingIDs.contains($0.key) }
        }
        guard !targets.isEmpty else { return }

        nowPlayingRefreshInFlight = true
        scriptQueue.async { [weak self] in
            var fetched: [AudioObjectID: NowPlaying] = [:]
            for target in targets {
                if let info = NowPlayingService.fetch(bundleID: target.bundleID) {
                    fetched[target.id] = info
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.nowPlayingRefreshInFlight = false
                for (id, info) in fetched { self.nowPlaying[id] = info }
                // Clear entries whose fetch came back empty this round.
                for id in playingIDs where fetched[id] == nil {
                    self.nowPlaying.removeValue(forKey: id)
                }
            }
        }
    }

    /// Blocking HAL enumeration of every audio-capable process. Runs on the HAL
    /// queue; touches no actor-isolated state.
    nonisolated private static func enumerateProcesses() -> [AudioProcess] {
        do {
            let objectIDs: [AudioObjectID] = try AudioObjectID.system.readArray(
                kAudioHardwarePropertyProcessObjectList)

            var result: [AudioProcess] = []
            result.reserveCapacity(objectIDs.count)
            for objectID in objectIDs where objectID.isValid {
                guard let process = makeProcess(objectID) else { continue }
                result.append(process)
            }
            return result
        } catch {
            log.error("Failed to read process list: \(String(describing: error))")
            return []
        }
    }

    /// Our own pid — never list or tap ourselves. Because Voulum re-plays the
    /// audio it taps, Core Audio attributes that output to us, so we'd otherwise
    /// appear as a "playing" app; tapping ourselves would mute-and-reroute our own
    /// output into our own input, a feedback loop that kills all audio until quit.
    nonisolated private static let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier

    nonisolated private static func makeProcess(_ objectID: AudioObjectID) -> AudioProcess? {
        let pid: pid_t = (try? objectID.read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
        guard pid > 0, pid != ownPID else { return nil }

        let bundleID: String? = try? objectID.readCF(kAudioProcessPropertyBundleID, as: String.self) ?? nil
        let isRunningOutput: UInt32 = (try? objectID.read(
            kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

        return AudioProcess(objectID: objectID,
                            pid: pid,
                            bundleID: bundleID,
                            isPlaying: isRunningOutput != 0)
    }
}
