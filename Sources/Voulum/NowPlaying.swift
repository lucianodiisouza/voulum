import Foundation

/// Track metadata read from a scriptable media app.
struct NowPlaying: Equatable {
    let title: String
    let artist: String
    let album: String?
    let isPlaying: Bool

    /// One-line description under the title: "Artist — Album", or whichever half
    /// we actually have. Empty when the app exposes no artist/album (e.g. VLC),
    /// in which case the UI falls back to the app name.
    var subtitle: String {
        switch (artist.isEmpty, album?.isEmpty ?? true) {
        case (false, false): return "\(artist) — \(album!)"
        case (false, true):  return artist
        case (true, false):  return album!
        case (true, true):   return ""
        }
    }
}

/// Reads now-playing metadata (and drives transport) for the handful of media
/// apps that expose an AppleScript dictionary.
///
/// This is the only path that still works on current macOS. Apple locked the
/// private MediaRemote framework — the generic "now playing" source Control
/// Center uses — behind entitlements only its own binaries carry (macOS 15.4+),
/// so a third-party app can no longer read arbitrary media metadata. Per-app
/// scripting is the supported fallback, at the cost of an allow-list: apps
/// without a scripting dictionary (browsers, most Electron apps, Apple Podcasts)
/// simply won't surface a title here, and fall back to the plain "Playing" state
/// with no controls.
enum NowPlayingService {

    /// Transport commands we can send to a scriptable media app.
    enum Command {
        case playPause, next, previous
    }

    /// Per-app scripting dialect. Media apps don't share verbs: Spotify/Music
    /// read `current track` and use `playpause`/`next track`, while VLC reads
    /// `current item` (title only, no artist/album) and uses `play`/`next`.
    private struct Recipe {
        /// AppleScript returning four linefeed-joined fields — title, artist,
        /// album, play-state ("playing" when playing) — or `noTrackSentinel`
        /// when nothing is loaded / the read fails.
        let metadata: String
        let playPause: String
        let next: String
        let previous: String
    }

    /// Bundle ids we know how to script, mapped to their scripting recipe.
    private static let recipes: [String: Recipe] = [
        "com.spotify.client": iTunesStyle("Spotify"),
        "com.apple.Music": iTunesStyle("Music"),
        "org.videolan.vlc": vlcStyle("VLC"),
    ]

    /// Whether we have a scripting recipe for this app.
    static func supports(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return recipes[bundleID] != nil
    }

    /// Send a transport command to the app. Blocking Apple event — call off the
    /// main thread. No-ops for apps we don't script. Uses the same automation
    /// permission the metadata read already established.
    static func send(_ command: Command, bundleID: String) {
        guard let recipe = recipes[bundleID] else { return }
        let source: String
        switch command {
        case .playPause: source = recipe.playPause
        case .next:      source = recipe.next
        case .previous:  source = recipe.previous
        }
        run(source, context: "command \(command)")
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
        guard let recipe = recipes[bundleID] else { return nil }
        guard let raw = run(recipe.metadata, context: "metadata"),
              raw != noTrackSentinel else { return nil }

        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        let album = parts[2].isEmpty ? nil : parts[2]
        let isPlaying = parts[3].caseInsensitiveCompare("playing") == .orderedSame
        return NowPlaying(title: parts[0], artist: parts[1], album: album, isPlaying: isPlaying)
    }

    /// Compile and run an AppleScript, returning its string result. Logs and
    /// swallows errors (a denied automation grant surfaces here as a nil).
    @discardableResult
    private static func run(_ source: String, context: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log.error("NowPlaying \(context, privacy: .public) failed: \(errorInfo)")
            return nil
        }
        return output.stringValue
    }

    // MARK: Recipes

    /// Spotify / Apple Music: `current track` with artist + album, `playpause`.
    private static func iTunesStyle(_ appName: String) -> Recipe {
        let metadata = """
        tell application "\(appName)"
            try
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set playState to (player state as text)
                return trackName & linefeed & trackArtist & linefeed & trackAlbum & linefeed & playState
            on error
                return "\(noTrackSentinel)"
            end try
        end tell
        """
        return Recipe(
            metadata: metadata,
            playPause: "tell application \"\(appName)\" to playpause",
            next: "tell application \"\(appName)\" to next track",
            previous: "tell application \"\(appName)\" to previous track")
    }

    /// VLC: `current item` exposes only a title (no artist/album), play-state is
    /// the `playing` boolean, and `play` toggles play/pause.
    private static func vlcStyle(_ appName: String) -> Recipe {
        let metadata = """
        tell application "\(appName)"
            try
                set trackName to name of current item
                if trackName is missing value then set trackName to ""
                set playState to "paused"
                if (playing) then set playState to "playing"
                if trackName is "" then return "\(noTrackSentinel)"
                return trackName & linefeed & "" & linefeed & "" & linefeed & playState
            on error
                return "\(noTrackSentinel)"
            end try
        end tell
        """
        return Recipe(
            metadata: metadata,
            playPause: "tell application \"\(appName)\" to play",
            next: "tell application \"\(appName)\" to next",
            previous: "tell application \"\(appName)\" to previous")
    }

    private static let noTrackSentinel = "__voulum_no_track__"
}
