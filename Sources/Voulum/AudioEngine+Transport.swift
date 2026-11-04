import Foundation

/// Per-app play / pause / skip and now-playing metadata, for the apps that can
/// be scripted (see `NowPlayingService` for why the list is an allow-list).
extension AudioEngine {

    func canControlTransport(_ app: AudioApp) -> Bool {
        app.isRunning && NowPlayingService.supportsTransport(app.bundleID)
    }

    func canSkipTracks(_ app: AudioApp) -> Bool {
        app.isRunning && NowPlayingService.supportsSkip(app.bundleID)
    }

    /// Best answer to "is this app making sound": the app's own state where we
    /// can read it, else Core Audio's running-output flag.
    func isPlayingNow(_ app: AudioApp) -> Bool {
        // Browser titles come from their tabs, which say nothing about play state.
        if let track = nowPlaying[app.key], NowPlayingService.supportsMetadata(app.bundleID) { return track.isPlaying }
        return app.isPlaying && pausedAt[app.key] == nil
    }

    func togglePlayPause(_ app: AudioApp) {
        if isPlayingNow(app) { pause(app) } else { resume(app) }
    }

    func pause(_ app: AudioApp) {
        guard let bundleID = app.bundleID, canControlTransport(app) else { return }
        markPaused(true, key: app.key)
        dispatch([TransportJob(key: app.key, bundleID: bundleID, command: .pause)])
    }

    /// Resume this app, first pausing every other playing app when "pause
    /// others" is on. Pauses are queued first so the two never overlap.
    func resume(_ app: AudioApp) {
        guard let bundleID = app.bundleID, canControlTransport(app) else { return }
        var jobs: [TransportJob] = []
        if prefsPauseOthers {
            for other in runningApps where other.key != app.key && canControlTransport(other) && isPlayingNow(other) {
                guard let otherID = other.bundleID else { continue }
                markPaused(true, key: other.key)
                jobs.append(TransportJob(key: other.key, bundleID: otherID, command: .pause))
            }
        }
        markPaused(false, key: app.key)
        jobs.append(TransportJob(key: app.key, bundleID: bundleID, command: .resume))
        dispatch(jobs)
    }

    func skip(_ command: NowPlayingService.Command, _ app: AudioApp) {
        guard let bundleID = app.bundleID, canSkipTracks(app) else { return }
        dispatch([TransportJob(key: app.key, bundleID: bundleID, command: command)])
    }

    private var prefsPauseOthers: Bool { Preferences.shared.pauseOthersOnPlay }

    struct TransportJob {
        let key: String
        let bundleID: String
        let command: NowPlayingService.Command
    }

    /// Flip the paused flag optimistically so the row responds instantly; the
    /// next poll reconciles with what the app actually did.
    private func markPaused(_ paused: Bool, key: String) {
        setPaused(paused ? Date() : nil, key: key)
        if let track = nowPlaying[key] { setNowPlaying(track.settingPlaying(!paused), key: key) }
        setTransportError(nil, key: key)
    }

    /// Run commands in order off the main thread. A failed command rolls its
    /// optimistic flag back, so a row never claims a pause that didn't happen.
    private func dispatch(_ jobs: [TransportJob]) {
        transportQueue.async { [weak self] in
            var failures: [(TransportJob, String)] = []
            for job in jobs {
                if let error = NowPlayingService.send(job.command, bundleID: job.bundleID) {
                    failures.append((job, error.hint))
                }
            }
            Task { @MainActor in
                guard let self else { return }
                for (job, hint) in failures {
                    switch job.command {
                    case .pause: self.setPaused(nil, key: job.key)
                    case .resume: self.setPaused(Date(), key: job.key)
                    default: break
                    }
                    self.setTransportError(hint, key: job.key)
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.reload()
            }
        }
    }

    /// Forget our paused flag once the app is gone, or audibly playing again
    /// (the user hit play in the app itself) after the grace period.
    func reconcilePaused() {
        guard !pausedAt.isEmpty else { return }
        let now = Date()
        for (key, at) in pausedAt {
            guard let app = runningApps.first(where: { $0.key == key }) else {
                setPaused(nil, key: key); continue
            }
            if app.isPlaying && now.timeIntervalSince(at) > 2.5 { setPaused(nil, key: key) }
        }
    }

    /// Read track metadata for listed apps that can report it, off-main.
    /// Browsers are looked up from their tabs, only while the popup is open and
    /// at most every `tabRefreshInterval`, since that can mean a sweep of every tab.
    func refreshNowPlaying() {
        let targets: [(key: String, bundleID: String)] = visibleApps.compactMap { app in
            guard app.isRunning, let id = app.bundleID, NowPlayingService.supportsMetadata(id) else { return nil }
            return (app.key, id)
        }
        // A browser keeps its title while playing, or paused by us.
        let browsers = visibleApps.filter {
            $0.isRunning && NowPlayingService.supportsTabs($0.bundleID)
                && ($0.isPlaying || pausedAt[$0.key] != nil)
        }
        let now = Date()
        let tabTargets: [(key: String, bundleID: String, javaScript: Bool)] = isLive ? browsers.compactMap { app in
            guard let id = app.bundleID, app.isPlaying, pausedAt[app.key] == nil,
                  now.timeIntervalSince(lastTabFetch[app.key] ?? .distantPast) >= Self.tabRefreshInterval else { return nil }
            lastTabFetch[app.key] = now
            let javaScript = now.timeIntervalSince(javaScriptBlockedAt[id] ?? .distantPast) > Self.javaScriptRetryInterval
            return (app.key, id, javaScript)
        } : []

        let keys = Set(targets.map(\.key))
        let keep = keys.union(browsers.map(\.key))
        for key in nowPlaying.keys where !keep.contains(key) {
            setNowPlaying(nil, key: key)
            lastTabFetch[key] = nil
        }
        guard !targets.isEmpty || !tabTargets.isEmpty, beginNowPlayingFetch() else { return }

        transportQueue.async { [weak self] in
            var fetched: [String: NowPlaying] = [:]
            for target in targets {
                if let info = NowPlayingService.fetch(bundleID: target.bundleID) { fetched[target.key] = info }
            }
            var tabs: [String: NowPlaying] = [:]
            var blocked: Set<String> = []
            for target in tabTargets {
                let (info, javaScriptBlocked) = NowPlayingService.fetchTab(bundleID: target.bundleID,
                                                                           javaScriptAllowed: target.javaScript)
                if let info { tabs[target.key] = info }
                if javaScriptBlocked { blocked.insert(target.bundleID) }
            }
            Task { @MainActor in
                guard let self else { return }
                self.endNowPlayingFetch()
                for key in keys { self.setNowPlaying(fetched[key], key: key) }
                for target in tabTargets { self.setNowPlaying(tabs[target.key], key: target.key) }
                for id in blocked { self.javaScriptBlockedAt[id] = Date() }
            }
        }
    }
}
