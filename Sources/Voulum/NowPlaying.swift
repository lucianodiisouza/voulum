import Foundation

/// Track metadata read from a scriptable media app.
struct NowPlaying: Equatable {
    let title: String
    let artist: String
    let album: String?
    let isPlaying: Bool

    /// One-line description under the title: "Artist · Album", or whichever half
    /// we actually have. Empty when the app exposes no artist/album (e.g. VLC),
    /// in which case the UI falls back to the app name.
    var subtitle: String {
        switch (artist.isEmpty, album?.isEmpty ?? true) {
        case (false, false): return "\(artist) · \(album!)"
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
///    1 s poll. Browsers use `fetchTab` instead, on a slower cadence: they have
///    no "current track", so we find the tab that's playing (see there). Their
///    play state comes from Core Audio's `isRunningOutput`, which is an
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
                return String(localized: "Allow Voulum to control this app in System Settings ▸ Privacy & Security ▸ Automation.")
            case .javaScriptDisabled(let instruction):
                return instruction
            case .failed:
                return String(localized: "Couldn't reach this app's playback controls.")
            case .unreachableMedia:
                return String(localized: "This is playing inside an embedded player Voulum can't control. Mute and the volume slider still work on it.")
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
        /// Browsers: how to list tabs and run JavaScript in one, for `fetchTab`.
        var tabs: TabDialect? = nil
    }

    /// The two browser scripting dictionaries.
    enum TabDialect {
        /// Chromium family: `title of t`, `active tab index`, `execute t javascript`.
        case chromium(String)
        /// Safari: `name of t`, `current tab`, `do JavaScript … in t`.
        case safari(String)
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
        "company.thebrowser.Browser": chromiumStyle("Arc"),
        "com.operasoftware.Opera": chromiumStyle("Opera"),
        "dev.oprimo.flecha.browser": chromiumStyle("Flecha"),
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

    /// Whether we can name what this app is playing from its tabs (browsers).
    static func supportsTabs(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return recipes[bundleID]?.tabs != nil
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
               javaScriptHint: String(localized: "Turn on “Allow JavaScript from Apple Events” in \(appName): View ▸ Developer."),
               countsAffected: true,
               tabs: .chromium(appName))
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
               javaScriptHint: String(localized: "Turn on “Allow JavaScript from Apple Events” in \(appName): Settings ▸ Advanced ▸ Show features for web developers, then the Develop menu."),
               countsAffected: true,
               tabs: .safari(appName))
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

    // MARK: Browser tabs

    /// What a browser is playing, named after the tab it's coming from.
    /// Blocking (one or two Apple events) — call off the main thread, and not
    /// every second.
    ///
    /// Two ways in, best first:
    ///  1. JavaScript, where the user allowed it: the first tab with a playing
    ///     `<video>`/`<audio>` reports its Media Session metadata — the same
    ///     title/artist the page hands to Control Center — or its page title.
    ///  2. Tab titles, which need no JavaScript: the most likely media tab (a
    ///     known music/video site, preferring the one in front) gives its
    ///     title, with the site's own " - YouTube" style suffix trimmed off.
    ///
    /// `javaScriptAllowed` is false once (1) has failed for that reason, so we
    /// don't pay for an error round-trip on every refresh.
    static func fetchTab(bundleID: String, javaScriptAllowed: Bool) -> (NowPlaying?, javaScriptBlocked: Bool) {
        guard let dialect = recipes[bundleID]?.tabs else { return (nil, false) }
        var blocked = false
        if javaScriptAllowed {
            switch run(tabScript(dialect, javaScript: true), context: "tab media") {
            case .success(let raw?):
                if raw.hasPrefix(errorSentinel) {
                    blocked = raw.lowercased().contains("javascript")
                } else if let track = parseMediaSession(raw) {
                    return (track, false)
                }
            case .success(nil):
                break
            case .failure(let error):
                if case .javaScriptDisabled = error { blocked = true }
            }
        }
        guard case .success(let raw?) = run(tabScript(dialect, javaScript: false), context: "tab titles") else {
            return (nil, blocked)
        }
        return (bestTab(in: raw), blocked)
    }

    /// Lines of `active<TAB>URL<TAB>title` per tab, or — with `javaScript` —
    /// `title<LF>artist<LF>album<LF>host` from the first tab that's playing.
    private static func tabScript(_ dialect: TabDialect, javaScript: Bool) -> String {
        // `tab` is a class in both dictionaries, so the tab character is spelled out.
        let field = "(character id 9)"
        switch dialect {
        case .chromium(let app):
            if javaScript {
                return mediaSweep(app, inject: "execute t javascript \"\(mediaJS)\"")
            }
            return """
            tell application "\(app)"
                set out to ""
                repeat with w in windows
                    set a to active tab index of w
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set out to out & ((i = a) as text) & \(field) & (URL of t) & \(field) & (title of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        case .safari(let app):
            if javaScript {
                return mediaSweep(app, inject: "do JavaScript \"\(mediaJS)\" in t")
            }
            return """
            tell application "\(app)"
                set out to ""
                repeat with w in windows
                    set a to index of current tab of w
                    repeat with t in tabs of w
                        set out to out & (((index of t) = a) as text) & \(field) & (URL of t) & \(field) & (name of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        }
    }

    /// Run `mediaJS` tab by tab until one reports something playing.
    private static func mediaSweep(_ app: String, inject: String) -> String {
        """
        tell application "\(app)"
            set errMsg to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set r to (\(inject))
                        if r is not missing value and r is not "" then return r
                    on error m
                        if errMsg is "" then set errMsg to m
                    end try
                end repeat
            end repeat
            if errMsg is not "" then return "\(errorSentinel)" & errMsg
            return ""
        end tell
        """
    }

    /// Empty unless a media element is playing; then the page's Media Session
    /// metadata (falling back to its title) and host, newline-separated. Same
    /// one-line, single-quote constraints as `pauseJS`.
    private static let mediaJS = "(function(){var p=false;var e=document.querySelectorAll('video,audio');for(var i=0;i<e.length;i++){if(!e[i].paused&&!e[i].ended){p=true;break;}}if(!p)return '';var m=navigator.mediaSession&&navigator.mediaSession.metadata;var n=String.fromCharCode(10);return ((m&&m.title)||document.title)+n+((m&&m.artist)||'')+n+((m&&m.album)||'')+n+location.hostname;})()"

    private static func parseMediaSession(_ raw: String) -> NowPlaying? {
        let parts = raw.components(separatedBy: "\n")
        guard parts.count >= 4 else { return nil }
        let title = cleanTitle(parts[0])
        guard !title.isEmpty else { return nil }
        let artist = parts[1].isEmpty ? siteName(host: parts[3]) : parts[1]
        return NowPlaying(title: title, artist: artist, album: parts[2].isEmpty ? nil : parts[2], isPlaying: true)
    }

    /// Sites that are almost always the source when a browser makes sound,
    /// best first, with the name shown under the title.
    private static let mediaSites: [(host: String, name: String)] = [
        ("music.youtube.com", "YouTube Music"),
        ("open.spotify.com", "Spotify"),
        ("music.apple.com", "Apple Music"),
        ("soundcloud.com", "SoundCloud"),
        ("deezer.com", "Deezer"),
        ("tidal.com", "Tidal"),
        ("bandcamp.com", "Bandcamp"),
        ("mixcloud.com", "Mixcloud"),
        ("pandora.com", "Pandora"),
        ("youtube.com", "YouTube"),
        ("twitch.tv", "Twitch"),
        ("netflix.com", "Netflix"),
        ("primevideo.com", "Prime Video"),
        ("disneyplus.com", "Disney+"),
        ("max.com", "Max"),
        ("vimeo.com", "Vimeo"),
        ("podcasts.apple.com", "Apple Podcasts"),
    ]

    private static func site(for urlString: String) -> (rank: Int, name: String)? {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        for (rank, site) in mediaSites.enumerated()
        where host == site.host || host.hasSuffix("." + site.host) {
            // A YouTube home or search page isn't playing anything.
            if site.host == "youtube.com", !urlString.contains("/watch"), !urlString.contains("/live") { return nil }
            return (rank, site.name)
        }
        return nil
    }

    private static func siteName(host: String) -> String {
        let host = host.lowercased()
        return mediaSites.first { host == $0.host || host.hasSuffix("." + $0.host) }?.name
            ?? host.replacingOccurrences(of: "www.", with: "")
    }

    /// Pick the tab most likely to be the one playing.
    private static func bestTab(in raw: String) -> NowPlaying? {
        var best: (score: Int, title: String, name: String)?
        for line in raw.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let site = site(for: fields[1]) else { continue }
            let title = cleanTitle(fields[2])
            guard !title.isEmpty, title.caseInsensitiveCompare(site.name) != .orderedSame else { continue }
            let score = (mediaSites.count - site.rank) * 2 + (fields[0] == "true" ? 1 : 0)
            if best == nil || score > best!.score { best = (score, title, site.name) }
        }
        guard let best else { return nil }
        return NowPlaying(title: best.title, artist: best.name, album: nil, isPlaying: true)
    }

    /// "(3) Song name - YouTube" → "Song name".
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = title.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
            title.removeSubrange(match)
        }
        for suffix in [" - YouTube Music", " - YouTube", " | Spotify", " - Twitch", " | Netflix",
                       " | SoundCloud", " | Free Listening on SoundCloud", " on Vimeo", " - Deezer",
                       " on Apple Music", " | TIDAL", " - Prime Video", " | Disney+", " | Max"] {
            if title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        }
        // Spotify's web player prefixes "Spotify – ".
        if title.hasPrefix("Spotify – ") { title.removeFirst("Spotify – ".count) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static let noTrackSentinel = "__voulum_no_track__"
    /// Marks a script result that carries an error message rather than a value.
    private static let errorSentinel = "__voulum_err__"
}
