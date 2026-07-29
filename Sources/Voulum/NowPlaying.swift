import Foundation

/// Track metadata read from a scriptable media app (Spotify / Apple Music).
struct NowPlaying: Equatable {
    let title: String
    let artist: String
    let album: String?
    let isPlaying: Bool

    /// One-line description under the title: "Artist — Album", or whichever half
    /// we actually have.
    var subtitle: String {
        switch (artist.isEmpty, album?.isEmpty ?? true) {
        case (false, false): return "\(artist) — \(album!)"
        case (false, true):  return artist
        case (true, false):  return album!
        case (true, true):   return ""
        }
    }
}

/// Reads now-playing metadata from the handful of media apps that expose an
/// AppleScript dictionary.
///
/// This is the only path that still works on current macOS. Apple locked the
/// private MediaRemote framework — the generic "now playing" source Control
/// Center uses — behind entitlements only its own binaries carry (macOS 15.4+),
/// so a third-party app can no longer read arbitrary media metadata. Per-app
/// scripting is the supported fallback, at the cost of an allow-list: apps
/// without a scripting dictionary (browsers, most Electron apps, games) simply
/// won't surface a title here, and fall back to the plain "Playing" state.
enum NowPlayingService {
    /// Bundle ids we know how to script, mapped to their AppleScript app name.
    private static let scriptable: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": "Music",
    ]

    /// Whether we have a scripting recipe for this app.
    static func supports(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return scriptable[bundleID] != nil
    }

    /// Transport commands we can send to a scriptable media app.
    enum Command {
        case playPause, next, previous
    }

    /// Send a transport command to the app. Blocking Apple event — call off the
    /// main thread. No-ops for apps we don't script. Uses the same automation
    /// permission the metadata read already established.
    static func send(_ command: Command, bundleID: String) {
        guard let appName = scriptable[bundleID] else { return }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next:      verb = "next track"
        case .previous:  verb = "previous track"
        }
        let source = "tell application \"\(appName)\" to \(verb)"
        guard let script = NSAppleScript(source: source) else { return }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log.error("NowPlaying command \(verb, privacy: .public) failed for \(appName, privacy: .public): \(errorInfo)")
        }
    }

    /// Query the app for its current track. Blocking — it compiles and runs an
    /// Apple event round-trip — so call this off the main thread.
    ///
    /// Callers must only pass apps Core Audio already reports as running output,
    /// so the target is guaranteed to be running; that avoids the auto-launch a
    /// `tell application` block would otherwise trigger. Returns nil if the app
    /// isn't scriptable, has no track loaded, or the Apple event fails (e.g. the
    /// user hasn't granted automation permission).
    static func fetch(bundleID: String) -> NowPlaying? {
        guard let appName = scriptable[bundleID] else { return nil }
        return runScript(appName: appName)
    }

    private static func runScript(appName: String) -> NowPlaying? {
        // `current track` throws when nothing is loaded, so guard the reads and
        // return a sentinel rather than letting the whole script error out.
        let source = """
        tell application "\(appName)"
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set playState to (player state as text)
            on error
                return "\(noTrackSentinel)"
            end try
            return trackName & linefeed & trackArtist & linefeed & trackAlbum & linefeed & playState
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log.error("NowPlaying script failed for \(appName, privacy: .public): \(errorInfo)")
            return nil
        }
        guard let raw = output.stringValue, raw != noTrackSentinel else { return nil }

        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        let album = parts[2].isEmpty ? nil : parts[2]
        let isPlaying = parts[3].caseInsensitiveCompare("playing") == .orderedSame
        return NowPlaying(title: parts[0], artist: parts[1], album: album, isPlaying: isPlaying)
    }

    private static let noTrackSentinel = "__voulum_no_track__"
}
