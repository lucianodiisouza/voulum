import AppKit
import Combine
import CoreAudio
import Foundation

/// One user-facing app and every Core Audio process that plays on its behalf
/// (a browser's renderer and GPU helpers, an Electron app's workers …).
struct AudioApp: Identifiable, Hashable {
    /// Stable identity: the owning app's bundle id, or "pid:N" for bare tools.
    let key: String
    let name: String
    let bundleID: String?
    let bundleURL: URL?
    let pid: pid_t?
    /// Core Audio process objects to tap. Empty for a pinned app that isn't running.
    var processIDs: [AudioObjectID]
    var isPlaying: Bool

    var id: String { key }
    var isRunning: Bool { !processIDs.isEmpty }

    var icon: NSImage {
        if let pid, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon { return icon }
        if let bundleURL { return NSWorkspace.shared.icon(forFile: bundleURL.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    var known: KnownApp { KnownApp(key: key, name: name, bundlePath: bundleURL?.path) }

    func bringToFront() {
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
        } else if let bundleURL {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init())
        }
    }
}

/// The per-app half of Voulum: discovers which apps are making sound, keeps a
/// tap on every app the user has adjusted, applies their volume / mute / EQ /
/// routing, and drives media transport for the apps that support it.
@MainActor
final class AudioEngine: ObservableObject {

    static let shared = AudioEngine()

    /// Every app that currently owns at least one audio process.
    @Published private(set) var runningApps: [AudioApp] = []
    /// Latest track metadata per app key (scriptable media apps only).
    @Published private(set) var nowPlaying: [String: NowPlaying] = [:]
    /// Apps we paused ourselves, and when (see `pauseGrace`).
    @Published private(set) var pausedAt: [String: Date] = [:]
    @Published private(set) var transportErrors: [String: String] = [:]
    @Published private(set) var tapErrors: [String: String] = [:]
    @Published private(set) var audioPermissionGranted: Bool =
        UserDefaults.standard.bool(forKey: "hasGrantedAudioTap")

    let meters = LevelMeters()

    private let prefs = Preferences.shared
    private let devices = DeviceController.shared
    private var taps: [String: AppTap] = [:]
    /// The concrete device UIDs each tap was last routed to.
    private var appliedRoutes: [String: [String]] = [:]

    private let halQueue = DispatchQueue(label: "com.voulum.hal", qos: .userInitiated)
    /// Blocking AppleScript round-trips run here, off main and off the HAL queue.
    let transportQueue = DispatchQueue(label: "com.voulum.nowplaying", qos: .userInitiated)
    private var reloadInFlight = false
    private var reloadAgain = false
    private var nowPlayingInFlight = false

    // Narrow setters so the transport extension can stay in its own file while
    // the published state stays read-only to everyone else.
    func setPaused(_ date: Date?, key: String) { pausedAt[key] = date }
    func setNowPlaying(_ value: NowPlaying?, key: String) {
        if nowPlaying[key] != value { nowPlaying[key] = value }
    }
    func setTransportError(_ message: String?, key: String) { transportErrors[key] = message }
    func beginNowPlayingFetch() -> Bool {
        guard !nowPlayingInFlight else { return false }
        nowPlayingInFlight = true
        return true
    }
    func endNowPlayingFetch() { nowPlayingInFlight = false }
    private var processListToken: PropertyListenerToken?
    private var pollTimer: Timer?
    private var backgroundTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var hasLoaded = false
    private var readyQueue: [() -> Void] = []

    /// How long our own pause outranks Core Audio's running-output flag, which
    /// lags a beat behind the app actually going quiet.
    private let pauseGrace: TimeInterval = 2.5

    // MARK: Lists

    /// What the popup lists, in order: playing apps, then apps we paused, then
    /// pinned apps that are idle or not running. Ignored apps never appear.
    var visibleApps: [AudioApp] {
        var result: [AudioApp] = []
        var seen: Set<String> = []
        let byName: (AudioApp, AudioApp) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let active = runningApps.filter {
            !prefs.isIgnored($0.key) && ($0.isPlaying || pausedAt[$0.key] != nil)
        }
        for app in active.sorted(by: byName) {
            result.append(app); seen.insert(app.key)
        }
        if prefs.showInactivePinned {
            for pin in prefs.pinned where !seen.contains(pin.key) && !prefs.isIgnored(pin.key) {
                if let running = runningApps.first(where: { $0.key == pin.key }) {
                    result.append(running)
                } else {
                    result.append(AudioApp(key: pin.key, name: pin.name, bundleID: pin.key.contains(":") ? nil : pin.key,
                                           bundleURL: pin.bundlePath.map { URL(fileURLWithPath: $0) },
                                           pid: nil, processIDs: [], isPlaying: false))
                }
            }
        }
        return result
    }

    func app(key: String) -> AudioApp? {
        runningApps.first { $0.key == key } ?? visibleApps.first { $0.key == key }
    }

    /// Resolve an app by bundle id, key, or (case-insensitive) name — for URLs.
    func findApp(_ query: String) -> AudioApp? {
        let q = query.lowercased()
        let pool = runningApps + visibleApps
        return pool.first { $0.key.lowercased() == q || $0.bundleID?.lowercased() == q }
            ?? pool.first { $0.name.lowercased() == q }
            ?? pool.first { $0.name.lowercased().contains(q) }
    }

    /// The app a volume hotkey should act on: the one making sound (preferring
    /// the frontmost if several are), else the frontmost app.
    func hotkeyTarget() -> AudioApp? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let playing = runningApps.filter { $0.isPlaying && !prefs.isIgnored($0.key) }
        if let match = playing.first(where: { $0.bundleID == front }) { return match }
        if let first = playing.first { return first }
        return runningApps.first { $0.bundleID == front }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        log.info("Voulum starting")
        halQueue.async {
            AppTap.reapLeakedDevices()
        }
        processListToken = AudioObjectID.system.listen(
            to: [kAudioHardwarePropertyProcessObjectList], queue: halQueue) { [weak self] _, _ in
            Task { @MainActor in self?.reload() }
        }
        devices.changes
            .sink { [weak self] in self?.reconcileAll() }
            .store(in: &cancellables)
        // A gentle background pulse keeps "who's playing" fresh for hotkeys and
        // auto-applied settings without the popup open. Cheap: one HAL read.
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
        if ProcessInfo.processInfo.environment["VOULUM_SELFTEST"] != nil { runSelfTest() }
    }

    /// Popup opened: refresh now, then poll for play-state, meters and tracks.
    func beginLiveUpdates() {
        reload()
        devices.refreshLevels()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.devices.refreshLevels()
            }
        }
        meters.start { [weak self] in
            guard let self else { return [:] }
            return self.taps.mapValues { $0.isActive ? $0.takeLevels() : (0, 0) }
        }
    }

    func endLiveUpdates() {
        pollTimer?.invalidate()
        pollTimer = nil
        meters.stop()
    }

    func shutdown() {
        let all = Array(taps.values)
        taps.removeAll()
        halQueue.sync { all.forEach { $0.invalidate() } }
    }

    // MARK: Per-app settings

    func settings(_ key: String) -> AppAudioSettings { prefs.settings(for: key) }

    func setLevel(_ level: Float, for app: AudioApp) {
        let clamped = max(0, min(AppAudioSettings.maxLevel, level))
        prefs.update(app.key) {
            $0.level = clamped
            if clamped > 0 { $0.muted = false }
        }
        reconcile(app)
    }

    func step(_ app: AudioApp, by delta: Float) {
        let current = settings(app.key)
        // Volume-up while muted unmutes in the same keystroke.
        let base = current.muted && delta > 0 ? 0 : current.level
        setLevel(base + delta, for: app)
    }

    func toggleMute(_ app: AudioApp) { setMuted(!settings(app.key).muted, for: app) }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        prefs.update(app.key) { $0.muted = muted }
        reconcile(app)
    }

    func setEQ(_ eq: EQSettings, for app: AudioApp) {
        prefs.update(app.key) { $0.eq = eq }
        reconcile(app)
    }

    func setRoute(_ route: OutputRoute, for app: AudioApp) {
        prefs.update(app.key) { $0.route = route }
        reconcile(app)
    }

    func reset(_ app: AudioApp) {
        prefs.update(app.key) { $0 = AppAudioSettings() }
        reconcile(app)
    }

    func setPinned(_ app: AudioApp, _ pinned: Bool) {
        prefs.setPinned(app.known, pinned)
        objectWillChange.send()
    }

    func setIgnored(_ app: AudioApp, _ ignored: Bool) {
        prefs.setIgnored(app.known, ignored)
        reconcile(app)
        objectWillChange.send()
    }

    // MARK: Taps

    private func reconcileAll() {
        for app in runningApps { reconcile(app) }
    }

    /// Make the tap for `app` match its saved settings: create, update, reroute
    /// or tear it down. Untouched apps get no tap at all.
    private func reconcile(_ app: AudioApp) {
        let s = settings(app.key)
        let wanted = s.needsTap && app.isRunning && !prefs.isIgnored(app.key)

        guard wanted else {
            if let tap = taps.removeValue(forKey: app.key) {
                appliedRoutes.removeValue(forKey: app.key)
                // Fade out of our pipeline gracefully: unity first, then drop.
                tap.gain = 1
                halQueue.async { tap.invalidate() }
            }
            tapErrors.removeValue(forKey: app.key)
            return
        }

        let tap = taps[app.key] ?? AppTap(key: app.key, name: app.name)
        let isNew = taps[app.key] == nil
        taps[app.key] = tap
        tap.gain = s.muted ? 0 : Self.gain(forLevel: s.level)
        tap.limiterEnabled = s.level > 1 || s.eq.boosts
        tap.eq.update(s.eq, sampleRate: tap.sampleRate)

        let outputs = resolvedOutputs(s.route)
        let processIDs = app.processIDs.sorted()
        guard isNew || appliedRoutes[app.key] != outputs || tap.processIDs != processIDs || !tap.isActive else { return }
        appliedRoutes[app.key] = outputs
        if isNew { tapErrors.removeValue(forKey: app.key) }

        let key = app.key, name = app.name, eq = s.eq
        halQueue.async { [weak self] in
            do {
                try tap.activate(processIDs: processIDs, outputUIDs: outputs)
                let rate = tap.sampleRate
                Task { @MainActor in
                    tap.eq.update(eq, sampleRate: rate)
                    self?.notePermissionGranted()
                    self?.tapErrors.removeValue(forKey: key)
                }
            } catch {
                let message = String(describing: error)
                log.error("Tap failed for \(name, privacy: .public): \(message, privacy: .public)")
                Task { @MainActor in
                    guard let self, self.taps[key] === tap else { return }
                    self.taps.removeValue(forKey: key)
                    self.appliedRoutes.removeValue(forKey: key)
                    self.tapErrors[key] = message
                }
            }
        }
    }

    /// Concrete device UIDs for a route. Devices that aren't connected are
    /// skipped; if none are, the app falls back to the system output and
    /// returns to its chosen device(s) automatically when they reconnect.
    private func resolvedOutputs(_ route: OutputRoute) -> [String] {
        let connected = route.deviceUIDs.filter { devices.output(uid: $0) != nil }
        if !connected.isEmpty { return connected }
        return devices.defaultOutput.map { [$0.uid] } ?? []
    }

    /// Whether `app`'s chosen device(s) are missing right now.
    func isRouteFallingBack(_ app: AudioApp) -> Bool {
        let uids = settings(app.key).route.deviceUIDs
        return !uids.isEmpty && uids.allSatisfy { devices.output(uid: $0) == nil }
    }

    /// Slider position → linear gain. Below 100% it's squared, which tracks
    /// perceived loudness far better than a straight line (50% ≈ -12 dB).
    /// Above 100% it's linear boost, up to 4x (+12 dB).
    nonisolated static func gain(forLevel level: Float) -> Float {
        level <= 1 ? level * level : level
    }

    private func notePermissionGranted() {
        guard !audioPermissionGranted else { return }
        audioPermissionGranted = true
        UserDefaults.standard.set(true, forKey: "hasGrantedAudioTap")
    }

    // MARK: Enumeration

    func reload() {
        guard !reloadInFlight else { reloadAgain = true; return }
        reloadInFlight = true
        halQueue.async { [weak self] in
            let apps = Self.enumerateApps()
            Task { @MainActor in
                guard let self else { return }
                self.reloadInFlight = false
                self.apply(apps)
                if self.reloadAgain {
                    self.reloadAgain = false
                    self.reload()
                }
            }
        }
    }

    /// Run `work` once the first scan has finished — a `voulum://` link that
    /// launched the app would otherwise look for apps before any are known.
    func whenReady(_ work: @escaping () -> Void) {
        if hasLoaded { work() } else { readyQueue.append(work) }
    }

    private func apply(_ apps: [AudioApp]) {
        if apps != runningApps { runningApps = apps }
        defer {
            if !hasLoaded {
                hasLoaded = true
                readyQueue.forEach { $0() }
                readyQueue.removeAll()
            }
        }
        let living = Set(apps.map(\.key))

        for (key, tap) in taps where !living.contains(key) {
            taps.removeValue(forKey: key)
            appliedRoutes.removeValue(forKey: key)
            halQueue.async { tap.invalidate() }
        }
        tapErrors = tapErrors.filter { living.contains($0.key) }
        transportErrors = transportErrors.filter { living.contains($0.key) }
        reconcilePaused()
        for app in apps { reconcile(app) }
        refreshNowPlaying()
    }

    /// Blocking: read every audio process and group them by owning app.
    nonisolated private static func enumerateApps() -> [AudioApp] {
        guard let objectIDs: [AudioObjectID] = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var groups: [String: AudioApp] = [:]
        var order: [String] = []
        for objectID in objectIDs where objectID.isValid {
            let pid: pid_t = (try? objectID.read(kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
            guard pid > 0, pid != ownPID else { continue }
            // Core Audio reports "" rather than nothing for bundleless processes.
            let rawBundleID: String? = (try? objectID.readCF(kAudioProcessPropertyBundleID, as: String.self) ?? nil)
                .flatMap { $0.isEmpty ? nil : $0 }
            let running: UInt32 = (try? objectID.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

            // A non-app owner (a CLI parent like a shell) says nothing useful
            // about who's playing; only keep it when it's a real app bundle.
            let owner = owningApp(of: pid).flatMap { $0.bundleIdentifier == nil ? nil : $0 }
            // Never list ourselves — see the note on feedback loops in AppTap.
            if owner?.processIdentifier == ownPID { continue }
            let bundleID = owner?.bundleIdentifier ?? rawBundleID
            let executable = processName(pid)
            // Bundleless tools (afplay, mpv, a game binary) are keyed by their
            // executable so their settings survive relaunches like an app's do.
            let key = bundleID ?? executable.map { "exe:\($0)" } ?? "pid:\(pid)"

            if var existing = groups[key] {
                existing.processIDs.append(objectID)
                existing.isPlaying = existing.isPlaying || running != 0
                groups[key] = existing
            } else {
                let ownerName = owner?.localizedName.flatMap { $0.isEmpty ? nil : $0 }
                let name = ownerName ?? bundleID.map(prettyBundleName) ?? executable ?? "PID \(pid)"
                groups[key] = AudioApp(key: key, name: name, bundleID: bundleID, bundleURL: owner?.bundleURL,
                                       pid: owner?.processIdentifier ?? pid,
                                       processIDs: [objectID], isPlaying: running != 0)
                order.append(key)
            }
        }
        return order.compactMap { key in
            groups[key].map { var a = $0; a.processIDs.sort(); return a }
        }
    }

    /// Core Audio often reports a helper process rather than the app the user
    /// recognises. Walk up the parent chain to the first foreground app.
    nonisolated private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var firstMatch: NSRunningApplication?
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 16 {
            if let app = NSRunningApplication(processIdentifier: p) {
                if app.activationPolicy == .regular { return app }
                if firstMatch == nil { firstMatch = app }
            }
            current = parentPID(of: p)
            hops += 1
        }
        // Helpers launched by launchd (XPC) have no parent link; fall back to the
        // app whose bundle contains the helper's executable.
        if let path = executablePath(pid),
           let host = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.bundleURL.map { path.hasPrefix($0.path + "/") } == true
           }) {
            return host
        }
        return firstMatch
    }

    nonisolated private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &info, &size, nil, 0) }
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    nonisolated private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    nonisolated private static func processName(_ pid: pid_t) -> String? {
        executablePath(pid).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    // MARK: Self-test

    /// Headless smoke test (VOULUM_SELFTEST=1): ramps the first playing app.
    private func runSelfTest() {
        func note(_ s: String) {
            FileHandle.standardError.write("VOULUM SELFTEST: \(s)\n".data(using: .utf8)!)
            log.info("SELFTEST: \(s, privacy: .public)")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let target = runningApps.first(where: \.isPlaying) else { return note("nothing playing to tap") }
            note("ramping \(target.name)")
            let before = settings(target.key)
            for level: Float in [1, 0.5, 0, 2, 1] {
                setLevel(level, for: target)
                note("level -> \(level); error: \(tapErrors[target.key] ?? "none")")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            prefs.update(target.key) { $0 = before }
            reconcile(target)
        }
    }
}

/// Turn a reverse-DNS bundle id into something readable as a last resort.
private func prettyBundleName(_ bundleID: String) -> String {
    let parts = bundleID.split(separator: ".")
    guard parts.count > 2 else { return bundleID }
    return parts.dropFirst(2).joined(separator: " ")
}

// MARK: - Meters

/// Per-app output levels for the popup, sampled ~24 times a second while it's
/// open and smoothed with a fast attack / slow release, like a real meter.
/// Separate from `AudioEngine` so only the meters redraw at that rate.
@MainActor
final class LevelMeters: ObservableObject {
    @Published private(set) var levels: [String: Float] = [:]
    /// Apps whose signal is touching full scale — the ring turns orange.
    @Published private(set) var hot: Set<String> = []
    private var timer: Timer?

    func start(sample: @escaping () -> [String: (rms: Float, peak: Float)]) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                var next: [String: Float] = [:]
                var nextHot: Set<String> = []
                for (key, value) in sample() {
                    // Loudness (RMS) on a −54…−6 dBFS scale, so typical music
                    // sits mid-ring and moves with the beat instead of pinning.
                    let db = 20 * log10(max(value.rms, 1e-6))
                    let target = max(0, min(1, (db + 54) / 48))
                    let previous = self.levels[key] ?? 0
                    next[key] = target > previous ? target : max(target, previous - 0.05)
                    if value.peak > 0.98 { nextHot.insert(key) }
                }
                if next != self.levels { self.levels = next }
                if nextHot != self.hot { self.hot = nextHot }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        levels = [:]
        hot = []
    }
}
