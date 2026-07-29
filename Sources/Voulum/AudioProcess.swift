import AppKit
import CoreAudio
import Foundation

/// A process known to Core Audio, enriched with app metadata from AppKit.
struct AudioProcess: Identifiable, Hashable {
    /// The Core Audio process object ID (NOT the pid). Used to build taps.
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// True while the process is actively rendering audio to an output device.
    var isPlaying: Bool

    var id: AudioObjectID { objectID }

    /// Best display name we can resolve: owning-app localized name, then bundle
    /// id, then pid.
    var name: String {
        if let app = runningApp, let n = app.localizedName { return n }
        if let bundleID { return prettyBundleName(bundleID) }
        return "PID \(pid)"
    }

    var icon: NSImage? {
        runningApp?.icon
    }

    /// The bundle id of the user-facing owning app, preferring the resolved
    /// foreground app over Core Audio's raw (often helper) attribution. Used to
    /// decide whether we can read now-playing metadata for this process.
    var resolvedBundleID: String? {
        runningApp?.bundleIdentifier ?? bundleID
    }

    /// The user-facing app that owns this audio process.
    ///
    /// Core Audio often reports a *helper* process (e.g. a Chrome/Electron
    /// renderer, a CLI tool) rather than the app the user recognizes. A direct
    /// `NSRunningApplication(processIdentifier:)` returns nil for those, so we
    /// walk up the parent-PID chain and prefer the first ancestor that presents
    /// as a normal foreground app (has a Dock icon).
    var runningApp: NSRunningApplication? {
        var firstMatch: NSRunningApplication?
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 8 {
            if let app = NSRunningApplication(processIdentifier: p) {
                if app.activationPolicy == .regular { return app }
                if firstMatch == nil { firstMatch = app }
            }
            current = AudioProcess.parentPID(of: p)
            hops += 1
        }
        return firstMatch
    }

    /// Look up a process's parent PID via `sysctl`. Returns nil at the top of
    /// the tree (launchd, pid 1).
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 1 ? ppid : nil
    }

    /// Bring this process's app to the foreground so the user can find the sound.
    func activate() {
        runningApp?.activate(options: [.activateAllWindows])
    }
}

/// Turn a reverse-DNS bundle id into something readable as a last resort
/// (e.g. "com.google.Chrome.helper" -> "Chrome helper").
private func prettyBundleName(_ bundleID: String) -> String {
    let parts = bundleID.split(separator: ".")
    guard parts.count > 2 else { return bundleID }
    return parts.dropFirst(2).joined(separator: " ")
}
