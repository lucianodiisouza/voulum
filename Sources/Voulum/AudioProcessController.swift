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

    /// Latest track metadata per process, for the media apps that can report a
    /// track cheaply enough to poll (Spotify, Music, TV, VLC, QuickTime). Absent
    /// for browsers and for everything unscriptable — see `NowPlayingService`
    /// for why the generic path is unavailable.
    @Published private(set) var nowPlaying: [AudioObjectID: NowPlaying] = [:]

    /// Serial queue for the blocking AppleScript round-trips that read track
    /// metadata. Kept off the main thread and off the HAL queue.
    private let scriptQueue = DispatchQueue(label: "com.voulum.nowplaying", qos: .userInitiated)
    /// Skip a metadata sweep if the previous batch is still running.
    private var nowPlayingRefreshInFlight = false

    func nowPlaying(for process: AudioProcess) -> NowPlaying? { nowPlaying[process.id] }

    // MARK: Transport (per-app play / pause)

    /// Apps we paused ourselves, and when.
    ///
    /// Two jobs. It keeps a paused app listed in the menu — Core Audio drops it
    /// from "running output" a beat after the sound stops, which would otherwise
    /// make the row vanish before the user could start it again. And the
    /// timestamp guards against that same lag in reverse: for a moment after we
    /// pause, the HAL still reports the app as playing, so we trust our own flag
    /// over `isRunningOutput` until `pauseGrace` has passed.
    @Published private(set) var pausedAt: [AudioObjectID: Date] = [:]

    /// How long our own pause outranks Core Audio's running-output flag.
    private let pauseGrace: TimeInterval = 2.5

    /// Why the last transport command failed, per app — automation access not
    /// granted, or a browser with JavaScript-from-Apple-Events turned off.
    @Published private(set) var transportErrors: [AudioObjectID: String] = [:]

    /// "Play one, pause the rest." On by default; the menu exposes a toggle.
    @Published var pauseOthersOnPlay: Bool =
        UserDefaults.standard.object(forKey: "pauseOthersOnPlay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOthersOnPlay, forKey: Self.pauseOthersKey) }
    }
    private static let pauseOthersKey = "pauseOthersOnPlay"

    /// What the menu lists: everything making sound, plus anything we paused, so
    /// the user can start it again.
    var visible: [AudioProcess] {
        processes
            .filter { $0.isPlaying || pausedAt[$0.id] != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func canControlTransport(_ process: AudioProcess) -> Bool {
        NowPlayingService.supportsTransport(process.resolvedBundleID)
    }

    func canSkipTracks(_ process: AudioProcess) -> Bool {
        NowPlayingService.supportsSkip(process.resolvedBundleID)
    }

    /// Best available answer to "is this app making sound right now": the app's
    /// own reported state where we can read it, else Core Audio's running-output
    /// flag (which is what browsers fall back on).
    func isPlayingNow(_ process: AudioProcess) -> Bool {
        if let track = nowPlaying[process.id] { return track.isPlaying }
        return process.isPlaying && pausedAt[process.id] == nil
    }

    func togglePlayPause(_ process: AudioProcess) {
        if isPlayingNow(process) { pause(process) } else { resume(process) }
    }

    func pause(_ process: AudioProcess) {
        guard let bundleID = process.resolvedBundleID,
              NowPlayingService.supportsTransport(bundleID) else { return }
        let affected = markPaused(true, bundleID: bundleID)
        dispatch([TransportJob(id: process.id, bundleID: bundleID, command: .pause, affected: affected)])
    }

    /// Resume this app, first pausing everything else that's playing when
    /// `pauseOthersOnPlay` is set. The pauses are queued ahead of the resume so
    /// the two never overlap audibly.
    func resume(_ process: AudioProcess) {
        guard let bundleID = process.resolvedBundleID,
              NowPlayingService.supportsTransport(bundleID) else { return }

        var jobs: [TransportJob] = []
        if pauseOthersOnPlay {
            for other in otherPlayingApps(excluding: bundleID) {
                let affected = markPaused(true, bundleID: other.bundleID)
                jobs.append(TransportJob(id: other.id, bundleID: other.bundleID,
                                         command: .pause, affected: affected))
            }
        }
        let affected = markPaused(false, bundleID: bundleID)
        jobs.append(TransportJob(id: process.id, bundleID: bundleID,
                                 command: .resume, affected: affected))
        dispatch(jobs)
    }

    func skip(_ command: NowPlayingService.Command, to process: AudioProcess) {
        guard let bundleID = process.resolvedBundleID,
              NowPlayingService.supportsSkip(bundleID) else { return }
        dispatch([TransportJob(id: process.id, bundleID: bundleID, command: command, affected: [])])
    }

    private struct TransportJob {
        let id: AudioObjectID
        let bundleID: String
        let command: NowPlayingService.Command
        /// Exactly the processes whose paused flag this job flipped, so a failure
        /// can put back what it changed. One app can back several Core Audio
        /// processes, so this is a list, not just `id`.
        let affected: [AudioObjectID]
    }

    /// Every *other* app currently playing that we can script, deduped by bundle
    /// id — one browser routinely surfaces as several Core Audio helper
    /// processes, and we only want to script it once.
    private func otherPlayingApps(excluding bundleID: String) -> [(id: AudioObjectID, bundleID: String)] {
        var seen: Set<String> = [bundleID]
        var result: [(id: AudioObjectID, bundleID: String)] = []
        for process in visible {
            guard let other = process.resolvedBundleID,
                  !seen.contains(other),
                  NowPlayingService.supportsTransport(other),
                  isPlayingNow(process) else { continue }
            seen.insert(other)
            result.append((process.id, other))
        }
        return result
    }

    /// Flip the paused flag optimistically so the UI responds instantly, across
    /// every process backed by this app — one browser routinely surfaces as
    /// several Core Audio processes, and a scripted pause hits all of them at
    /// once. Returns the ids it actually touched so a failed command can revert
    /// precisely that set. The next poll reconciles with what the app did.
    @discardableResult
    private func markPaused(_ paused: Bool, bundleID: String) -> [AudioObjectID] {
        var touched: [AudioObjectID] = []
        for process in processes where process.resolvedBundleID == bundleID {
            if paused {
                // Only ever flag a row that's already on screen. Flagging an idle
                // helper process would conjure a phantom "Paused" row for
                // something that never made a sound.
                guard process.isPlaying || pausedAt[process.id] != nil else { continue }
                pausedAt[process.id] = Date()
            } else {
                guard pausedAt.removeValue(forKey: process.id) != nil || process.isPlaying else { continue }
            }
            touched.append(process.id)
            if let track = nowPlaying[process.id] {
                nowPlaying[process.id] = track.settingPlaying(!paused)
            }
            transportErrors.removeValue(forKey: process.id)
        }
        return touched
    }

    /// Run scripted commands in order on the script queue, then pull fresh state
    /// once the apps have had a beat to settle. A command that fails rolls its
    /// optimistic flag back, so a row can't claim to be paused when it isn't.
    private func dispatch(_ jobs: [TransportJob]) {
        scriptQueue.async { [weak self] in
            var failures: [(job: TransportJob, hint: String)] = []
            for job in jobs {
                if let error = NowPlayingService.send(job.command, bundleID: job.bundleID) {
                    failures.append((job, error.hint))
                }
            }
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                for failure in failures {
                    // Revert exactly the set the optimistic flag touched. Clearing
                    // only the clicked process would strand its siblings showing
                    // "Paused" for a pause that never happened.
                    for id in failure.job.affected {
                        switch failure.job.command {
                        case .pause:  self.pausedAt.removeValue(forKey: id)
                        case .resume: self.pausedAt[id] = now
                        default:      break
                        }
                    }
                    self.transportErrors[failure.job.id] = failure.hint
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.reload()
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

    /// Range the UI exposes: full mute up to 3x boost.
    static let maxGain: Float = 3.0

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

    /// Retained so the Core Audio listener block stays alive for the app's
    /// lifetime; also lets us remove the listener cleanly if we ever tear down.
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !started else { return }
        started = true
        log.info("Voulum starting; enumerating audio processes")
        // Sweep away any aggregate devices / taps leaked by a previous crash
        // before we start creating new ones — they otherwise pile up in
        // coreaudiod and can wedge the whole audio HAL.
        halQueue.async { ProcessTap.reapLeakedDevices() }
        observeDefaultOutputDevice()
        reload()
        if ProcessInfo.processInfo.environment["VOULUM_SELFTEST"] != nil {
            runSelfTest()
        }
    }

    /// Watch the system's default output device. When it changes (e.g. the user
    /// switches from the Mac speakers to a Bluetooth headset), each active tap's
    /// aggregate still points at the *old* device, so the tapped app keeps
    /// playing there. Rebuild every active tap's aggregate around the new device
    /// so per-app volume follows the output the user actually selected.
    ///
    /// Uses a block listener dispatched on the HAL queue — the same queue every
    /// other blocking Core Audio call runs on, so rebuilds serialize behind any
    /// in-flight activation/teardown instead of racing it.
    private func observeDefaultOutputDevice() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on the HAL queue. Hop to the main actor to read the tap
            // set, then rebuild each one back on the HAL queue.
            Task { @MainActor in self?.rebuildActiveTapsForOutputChange() }
        }
        defaultOutputListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            .system, &defaultOutputListenerAddress, halQueue, block)
        if status != noErr {
            log.error("Failed to observe default output device (status \(status))")
        }
    }

    /// Rebuild the aggregate of every active tap so it follows the current
    /// default output device. Each rebuild runs on the HAL queue.
    private func rebuildActiveTapsForOutputChange() {
        guard !taps.isEmpty else { return }
        log.info("Default output device changed; rebuilding \(self.taps.count) tap(s)")
        for tap in taps.values {
            halQueue.async { tap.rebuildOutput() }
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
                self.transportErrors = self.transportErrors.filter { living.contains($0.key) }
                self.reconcilePaused(with: result)
                self.refreshNowPlaying()
            }
        }
    }

    /// Drop our paused flag for anything that has gone away or is audibly
    /// playing again — the latter meaning the user hit play in the app itself.
    /// Only after `pauseGrace`, because the HAL keeps reporting running-output
    /// for a moment after a pause actually takes effect.
    private func reconcilePaused(with result: [AudioProcess]) {
        guard !pausedAt.isEmpty else { return }
        let now = Date()
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        pausedAt = pausedAt.filter { id, at in
            guard let process = byID[id] else { return false }
            return !(process.isPlaying && now.timeIntervalSince(at) > pauseGrace)
        }
    }

    /// Read track metadata for the listed processes that come from a
    /// scriptable media app, off the main thread, and publish the results.
    /// Coalesced so a slow AppleScript round-trip can't pile up behind the poll.
    private func refreshNowPlaying() {
        guard !nowPlayingRefreshInFlight else { return }

        // Resolve the scripting targets on the main thread (AppKit-backed
        // bundle-id lookup), then hand just the ids off to the script queue.
        // `visible`, not `playing`: an app we paused keeps its row, and its
        // track title should stay with it.
        let targets: [(id: AudioObjectID, bundleID: String)] = visible.compactMap { process in
            guard let bundleID = process.resolvedBundleID,
                  NowPlayingService.supportsMetadata(bundleID) else { return nil }
            return (process.id, bundleID)
        }

        // Drop metadata for anything that has dropped off the list entirely.
        let playingIDs = Set(targets.map(\.id))  // scriptable rows still on screen
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
