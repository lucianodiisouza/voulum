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

    /// Copy with a forced play state, for optimistic UI updates before the next
    /// poll confirms what the app actually did.
    func settingPlaying(_ playing: Bool) -> NowPlaying {
        NowPlaying(title: title, artist: artist, album: album, isPlaying: playing)
    }
}

/// Drives transport (pause / resume / skip) and reads now-playing metadata for
/// the apps we know how to script.
///
/// There is no universal way to pause an arbitrary macOS app. Apple locked the
/// private MediaRemote framework — the generic "now playing" source Control
/// Center uses — behind entitlements only its own binaries carry (macOS 15.4+),
/// so a third-party app can neither read arbitrary media metadata nor send a
/// targeted transport command. Per-app scripting is the supported fallback, at
/// the cost of an allow-list. Apps outside it (Electron apps, Apple Podcasts)
/// can still be muted via the volume slider, but not paused.
///
/// Two tiers of support, deliberately separate:
///  - **Transport** (every recipe): pause / resume, and skip where meaningful.
///  - **Metadata** (`Recipe.metadata != nil`): title/artist/album, read on the
///    1 s poll. Browsers opt out — finding the audible tab means running
///    JavaScript in *every* tab, far too expensive to do once a second. Their
///    play state comes from Core Audio's `isRunningOutput` instead, which is an
///    accurate "is this app making sound" signal anyway.
enum NowPlayingService {

    /// Transport commands. Deliberately explicit rather than a `playPause`
    /// toggle: "play this app, pause the others" needs to *pause* a specific
    /// app, and a toggle sent to an already-paused app would start it playing.
    enum Command {
        case pause, resume, next, previous
    }

    /// Why a scripted command didn't land, in terms the UI can act on.
    enum ScriptError: Error {
        /// The user hasn't granted Voulum automation access to the target app.
        case automationDenied
        /// A Chromium/Safari browser with "Allow JavaScript from Apple Events"
        /// off. Carries the app-specific menu path — it differs per browser, and
        /// "it's in a menu somewhere" is not an instruction anyone can follow.
        case javaScriptDisabled(String)
        case failed(String)
        /// The script ran fine but never reached the audio — in a browser, the
        /// media is inside a cross-origin iframe.
        case unreachableMedia

        /// Short, actionable line for the menu row.
        var hint: String {
            switch self {
            case .automationDenied:
                return "Allow Voulum to control this app in System Settings ▸ Privacy & Security ▸ Automation."
            case .javaScriptDisabled(let instruction):
                return instruction
            case .failed:
                return "Couldn't reach this app's playback controls."
            case .unreachableMedia:
                return "This is playing inside an embedded player Voulum can't control. Mute and the volume slider still work on it."
            }
        }
    }

    /// Per-app scripting dialect. Media apps share no verbs: Spotify/Music use
    /// `play`/`pause` on `current track`, VLC's `play` is a toggle over
    /// `current item` (title only), QuickTime addresses `front document`, and
    /// browsers are driven entirely through injected JavaScript.
    private struct Recipe {
        /// AppleScript returning four linefeed-joined fields — title, artist,
        /// album, play-state ("playing" when playing) — or `noTrackSentinel`
        /// when nothing is loaded. `nil` when the app can't report a track
        /// cheaply enough to poll (browsers).
        let metadata: String?
        let pause: String
        let resume: String
        /// `nil` when the app has no track-skipping concept (browsers, QuickTime).
        let next: String?
        let previous: String?
        /// Exact menu path to switch on Apple-Events JavaScript, for the browsers
        /// where that being off is the usual reason a command does nothing.
        var javaScriptHint: String? = nil
        /// Whether the script returns how many media elements it actually
        /// touched. Browsers do, and a count of zero is the difference between
        /// "paused it" and "silently reached nothing".
        var countsAffected: Bool = false
    }

    /// Bundle ids we know how to script, mapped to their scripting recipe.
    private static let recipes: [String: Recipe] = [
        // Native media apps — full metadata + skip.
        "com.spotify.client": iTunesStyle("Spotify"),
        "com.apple.Music": iTunesStyle("Music"),
        "com.apple.TV": iTunesStyle("TV"),
        "org.videolan.vlc": vlcStyle("VLC"),
        "com.apple.QuickTimePlayerX": quickTimeStyle("QuickTime Player"),

        // Browsers — transport only, via injected JavaScript.
        "com.apple.Safari": safariStyle("Safari"),
        "com.google.Chrome": chromiumStyle("Google Chrome"),
        "com.google.Chrome.canary": chromiumStyle("Google Chrome Canary"),
        "com.brave.Browser": chromiumStyle("Brave Browser"),
        "com.microsoft.edgemac": chromiumStyle("Microsoft Edge"),
        "com.vivaldi.Vivaldi": chromiumStyle("Vivaldi"),
        "org.chromium.Chromium": chromiumStyle("Chromium"),
    ]

    /// Whether we can pause/resume this app at all.
    static func supportsTransport(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return recipes[bundleID] != nil
    }

    /// Whether this app can report a track cheaply enough for the poll.
    static func supportsMetadata(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return recipes[bundleID]?.metadata != nil
    }

    /// Whether next/previous mean anything for this app.
    static func supportsSkip(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return recipes[bundleID]?.next != nil
    }

    /// Send a transport command to the app. Blocking Apple event — call off the
    /// main thread. Returns nil on success, or why it failed. No-ops (nil) for
    /// apps we don't script and for commands the app doesn't support.
    @discardableResult
    static func send(_ command: Command, bundleID: String) -> ScriptError? {
        guard let recipe = recipes[bundleID] else { return nil }
        let source: String?
        switch command {
        case .pause:    source = recipe.pause
        case .resume:   source = recipe.resume
        case .next:     source = recipe.next
        case .previous: source = recipe.previous
        }
        guard let source else { return nil }

        switch run(source, context: "command \(command)", javaScriptHint: recipe.javaScriptHint) {
        case .failure(let error):
            return error
        case .success(let output):
            // Browser recipes swallow per-tab errors so one unscriptable tab
            // can't abort the sweep, and report the first one back inline.
            guard let output else { return nil }
            if output.hasPrefix(errorSentinel) {
                return classify(message: String(output.dropFirst(errorSentinel.count)),
                                javaScriptHint: recipe.javaScriptHint)
            }
            // A browser sweep that touched nothing ran perfectly and still did
            // nothing — the media is somewhere the injection can't reach. Report
            // it rather than letting the row claim a pause that never happened.
            if recipe.countsAffected,
               let affected = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
               affected == 0 {
                return .unreachableMedia
            }
            return nil
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
        guard let metadata = recipes[bundleID]?.metadata else { return nil }
        guard case .success(let raw?) = run(metadata, context: "metadata"),
              raw != noTrackSentinel else { return nil }

        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        let album = parts[2].isEmpty ? nil : parts[2]
        let isPlaying = parts[3].caseInsensitiveCompare("playing") == .orderedSame
        return NowPlaying(title: parts[0], artist: parts[1], album: album, isPlaying: isPlaying)
    }

    /// Compile and run an AppleScript, returning its string result.
    private static func run(_ source: String,
                            context: String,
                            javaScriptHint: String? = nil) -> Result<String?, ScriptError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.failed("Could not compile script"))
        }
        var errorInfo: NSDictionary?
        let output = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log.error("NowPlaying \(context, privacy: .public) failed: \(errorInfo)")
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
            // -1743: the user denied (or hasn't granted) Automation access.
            if number == -1743 { return .failure(.automationDenied) }
            return .failure(classify(message: message, javaScriptHint: javaScriptHint))
        }
        return .success(output.stringValue)
    }

    /// Map a raw AppleScript error message onto something the UI can explain.
    private static func classify(message: String, javaScriptHint: String?) -> ScriptError {
        let lowered = message.lowercased()
        if lowered.contains("javascript"), let javaScriptHint {
            return .javaScriptDisabled(javaScriptHint)
        }
        if lowered.contains("not allowed") || lowered.contains("not authorized") {
            return .automationDenied
        }
        return .failed(message)
    }

    // MARK: Native recipes

    /// Spotify / Apple Music / TV: `current track` with artist + album, and
    /// distinct `play` / `pause` verbs.
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
        func verb(_ command: String) -> String {
            """
            tell application "\(appName)"
                try
                    \(command)
                end try
            end tell
            """
        }
        return Recipe(metadata: metadata,
                      pause: verb("pause"),
                      resume: verb("play"),
                      next: verb("next track"),
                      previous: verb("previous track"))
    }

    /// VLC: `current item` exposes only a title (no artist/album), play-state is
    /// the `playing` boolean, and `play` is a *toggle* — so pause and resume both
    /// have to check the current state first.
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
        func guarded(_ body: String) -> String {
            """
            tell application "\(appName)"
                try
                    \(body)
                end try
            end tell
            """
        }
        return Recipe(metadata: metadata,
                      pause: guarded("if playing then play"),
                      resume: guarded("if not playing then play"),
                      next: guarded("next"),
                      previous: guarded("previous"))
    }

    /// QuickTime Player: everything addresses `front document`; no track list, so
    /// no skip.
    private static func quickTimeStyle(_ appName: String) -> Recipe {
        let metadata = """
        tell application "\(appName)"
            try
                if (count documents) is 0 then return "\(noTrackSentinel)"
                set trackName to name of front document
                set playState to "paused"
                if (playing of front document) then set playState to "playing"
                return trackName & linefeed & "" & linefeed & "" & linefeed & playState
            on error
                return "\(noTrackSentinel)"
            end try
        end tell
        """
        func guarded(_ body: String) -> String {
            """
            tell application "\(appName)"
                try
                    if (count documents) > 0 then \(body)
                end try
            end tell
            """
        }
        return Recipe(metadata: metadata,
                      pause: guarded("pause front document"),
                      resume: guarded("play front document"),
                      next: nil,
                      previous: nil)
    }

    // MARK: Browser recipes

    /// Pause every playing `<video>`/`<audio>` in the tab, tagging each one we
    /// touched so `resumeJS` can put back exactly what we stopped — rather than
    /// blindly starting the first media element it finds.
    ///
    /// Walks into nested iframes, since plenty of players live in one and
    /// `document.querySelectorAll` only sees the top document. A *cross-origin*
    /// frame throws on `contentDocument` and is skipped: neither browser's
    /// scripting API can reach into one, so media inside a third-party embed
    /// stays out of reach.
    ///
    /// Written on one line with single quotes only: it gets embedded in a
    /// double-quoted AppleScript string literal, which can neither span lines nor
    /// carry an unescaped `"`. Newlines are built with `String.fromCharCode` for
    /// the same reason — a `\n` escape would be resolved by AppleScript first and
    /// break the JavaScript string.
    private static let pauseJS = "(function(){function d(x,a){a.push(x);var f=x.querySelectorAll('iframe,frame');for(var i=0;i<f.length;i++){try{var c=f[i].contentDocument;if(c)d(c,a);}catch(e){}}return a;}var ds=d(document,[]);var n=0;for(var j=0;j<ds.length;j++){var e=ds[j].querySelectorAll('video,audio');for(var i=0;i<e.length;i++){var x=e[i];if(!x.paused&&!x.ended){x.setAttribute('data-voulum-paused','1');x.pause();n++;}}}return n;})()"

    private static let resumeJS = "(function(){function d(x,a){a.push(x);var f=x.querySelectorAll('iframe,frame');for(var i=0;i<f.length;i++){try{var c=f[i].contentDocument;if(c)d(c,a);}catch(e){}}return a;}var ds=d(document,[]);var n=0;for(var j=0;j<ds.length;j++){var e=ds[j].querySelectorAll('[data-voulum-paused]');for(var i=0;i<e.length;i++){var x=e[i];x.removeAttribute('data-voulum-paused');try{var p=x.play();if(p&&p.catch){p.catch(function(){});}}catch(err){}n++;}}return n;})()"

    /// Chromium family (Chrome, Brave, Edge, Vivaldi): `execute <tab> javascript`.
    private static func chromiumStyle(_ appName: String) -> Recipe {
        Recipe(metadata: nil,
               pause: browserSweep(appName, inject: "execute t javascript \"\(pauseJS)\""),
               resume: browserSweep(appName, inject: "execute t javascript \"\(resumeJS)\""),
               next: nil,
               previous: nil,
               // Path lifted from Chromium's own error string for this case.
               javaScriptHint: "Turn on “Allow JavaScript from Apple Events” in \(appName): View ▸ Developer.",
               countsAffected: true)
    }

    /// Safari: `do JavaScript … in <tab>`.
    private static func safariStyle(_ appName: String) -> Recipe {
        Recipe(metadata: nil,
               pause: browserSweep(appName, inject: "do JavaScript \"\(pauseJS)\" in t"),
               resume: browserSweep(appName, inject: "do JavaScript \"\(resumeJS)\" in t"),
               next: nil,
               previous: nil,
               // The Develop menu is itself hidden until switched on, so that
               // step has to be part of the instruction.
               javaScriptHint: "Turn on “Allow JavaScript from Apple Events” in \(appName): Settings ▸ Advanced ▸ Show features for web developers, then the Develop menu.",
               countsAffected: true)
    }

    /// Run an injection across every tab of every window.
    ///
    /// Audio usually plays in a *background* tab, and neither browser's scripting
    /// dictionary exposes an "audible" flag, so there's nothing to target — we
    /// have to sweep. Each tab is wrapped in its own `try` so one unscriptable
    /// tab (chrome://, the PDF viewer) can't abort the rest; the first error is
    /// carried back inline instead of being swallowed, because the common one —
    /// "Allow JavaScript from Apple Events" being off — is worth telling the user
    /// about.
    private static func browserSweep(_ appName: String, inject: String) -> String {
        """
        tell application "\(appName)"
            set errMsg to ""
            set touched to 0
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set touched to touched + (\(inject))
                    on error m
                        if errMsg is "" then set errMsg to m
                    end try
                end repeat
            end repeat
            if errMsg is not "" then return "\(errorSentinel)" & errMsg
            return touched as text
        end tell
        """
    }

    private static let noTrackSentinel = "__voulum_no_track__"
    /// Marks a script result that carries an error message rather than a value.
    private static let errorSentinel = "__voulum_err__"
}
