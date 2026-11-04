import Foundation
import os

// MARK: - Model

/// The ten fixed EQ bands, one octave apart. The two outer bands are shelves so
/// "more bass" lifts everything below 32 Hz too, instead of a narrow bump.
enum EQBand {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let count = frequencies.count
    /// Per-band gain limit, in dB.
    static let range: ClosedRange<Float> = -12...12

    static func label(_ index: Int) -> String {
        let f = frequencies[index]
        return f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))"
    }
}

/// One app's EQ: on/off, the band gains in dB, and the preset they came from
/// (nil once the user drags a band away from it — shown as "Custom").
struct EQSettings: Codable, Equatable {
    var enabled = false
    var gains: [Float] = Array(repeating: 0, count: EQBand.count)
    var presetID: String? = EQPreset.flat.id

    var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }
    /// Whether any band boosts — the limiter only needs to engage then.
    var boosts: Bool { enabled && gains.contains { $0 > 0.05 } }
}

struct EQPreset: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var gains: [Float]
    var category: Category
    var isUser: Bool { category == .user }

    enum Category: String, Codable, CaseIterable {
        case basic = "Basics", voice = "Voice", music = "Music", listening = "Listening", user = "My Presets"

        var title: String {
            switch self {
            case .basic: return String(localized: "Basics")
            case .voice: return String(localized: "Voice")
            case .music: return String(localized: "Music")
            case .listening: return String(localized: "Listening")
            case .user: return String(localized: "My Presets")
            }
        }
    }

    static let flat = EQPreset(id: "flat", name: String(localized: "Flat"), gains: Array(repeating: 0, count: 10), category: .basic)

    static let builtIn: [EQPreset] = [
        flat,
        EQPreset(id: "bass-boost", name: String(localized: "Bass Boost"), gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0], category: .basic),
        EQPreset(id: "bass-cut", name: String(localized: "Less Bass"), gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0], category: .basic),
        EQPreset(id: "treble-boost", name: String(localized: "Treble Boost"), gains: [0, 0, 0, 0, 0, 1, 3, 4, 5, 6], category: .basic),
        EQPreset(id: "treble-cut", name: String(localized: "Less Treble"), gains: [0, 0, 0, 0, 0, -1, -3, -4, -5, -6], category: .basic),
        EQPreset(id: "voice", name: String(localized: "Clear Voice"), gains: [-3, -2, -1, 1, 3, 4, 4, 3, 1, 0], category: .voice),
        EQPreset(id: "podcast", name: String(localized: "Podcast"), gains: [-6, -4, -1, 1, 3, 3, 2, 1, 0, -1], category: .voice),
        EQPreset(id: "calls", name: String(localized: "Video Calls"), gains: [-8, -6, -2, 0, 2, 3, 3, 2, -1, -3], category: .voice),
        EQPreset(id: "rock", name: String(localized: "Rock"), gains: [4, 3, 2, 0, -1, -1, 1, 2, 3, 4], category: .music),
        EQPreset(id: "pop", name: String(localized: "Pop"), gains: [-1, 0, 2, 3, 4, 3, 1, 0, 0, -1], category: .music),
        EQPreset(id: "electronic", name: String(localized: "Electronic"), gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5], category: .music),
        EQPreset(id: "hiphop", name: String(localized: "Hip-Hop"), gains: [5, 4, 1, 3, -1, -1, 1, -1, 2, 3], category: .music),
        EQPreset(id: "jazz", name: String(localized: "Jazz"), gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3], category: .music),
        EQPreset(id: "classical", name: String(localized: "Classical"), gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4], category: .music),
        EQPreset(id: "acoustic", name: String(localized: "Acoustic"), gains: [4, 3, 2, 1, 1, 1, 2, 3, 2, 1], category: .music),
        EQPreset(id: "loudness", name: String(localized: "Loudness"), gains: [5, 4, 1, 0, -1, 0, 1, 2, 4, 4], category: .listening),
        EQPreset(id: "late-night", name: String(localized: "Late Night"), gains: [-5, -4, -2, 0, 1, 2, 2, 1, 0, -1], category: .listening),
        EQPreset(id: "small-speakers", name: String(localized: "Small Speakers"), gains: [-4, 3, 4, 2, 0, 0, 0, 1, 2, 1], category: .listening),
        EQPreset(id: "warm", name: String(localized: "Warm"), gains: [3, 3, 2, 1, 0, 0, -1, -2, -3, -3], category: .listening),
        EQPreset(id: "bright", name: String(localized: "Bright"), gains: [-2, -1, 0, 0, 0, 1, 2, 3, 4, 4], category: .listening),
    ]
}

// MARK: - Filter math

/// Normalised biquad coefficients (a0 == 1), Direct Form II Transposed.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    static let identity = Biquad()

    /// RBJ "Audio EQ Cookbook" filters. `index` picks the shape: the first band
    /// is a low shelf, the last a high shelf, everything else a peaking bell.
    static func band(_ index: Int, gainDB: Float, sampleRate: Double) -> Biquad {
        guard abs(gainDB) > 0.01, sampleRate > 0 else { return .identity }
        let f0 = min(EQBand.frequencies[index], sampleRate * 0.45)
        let a = pow(10, Double(gainDB) / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw = cos(w0), sinw = sin(w0)

        var b0, b1, b2, a0, a1, a2: Double
        if index == 0 || index == EQBand.count - 1 {
            let alpha = sinw / 2 * sqrt(2)          // shelf slope S = 1
            let k = 2 * sqrt(a) * alpha
            if index == 0 {
                b0 = a * ((a + 1) - (a - 1) * cosw + k)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
                b2 = a * ((a + 1) - (a - 1) * cosw - k)
                a0 = (a + 1) + (a - 1) * cosw + k
                a1 = -2 * ((a - 1) + (a + 1) * cosw)
                a2 = (a + 1) + (a - 1) * cosw - k
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosw + k)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
                b2 = a * ((a + 1) + (a - 1) * cosw - k)
                a0 = (a + 1) - (a - 1) * cosw + k
                a1 = 2 * ((a - 1) - (a + 1) * cosw)
                a2 = (a + 1) - (a - 1) * cosw - k
            }
        } else {
            let q = 1.41                            // ~one octave wide
            let alpha = sinw / (2 * q)
            b0 = 1 + alpha * a
            b1 = -2 * cosw
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosw
            a2 = 1 - alpha / a
        }
        return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
                      a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// Magnitude response in dB at `frequency` — used to draw the EQ curve.
    func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2
        let ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2
        let di = -(Double(a1) * s1 + Double(a2) * s2)
        let mag = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-12))
        return 20 * log10(max(mag, 1e-9))
    }
}

extension EQSettings {
    func coefficients(sampleRate: Double) -> [Biquad] {
        (0..<EQBand.count).map { Biquad.band($0, gainDB: enabled ? gains[$0] : 0, sampleRate: sampleRate) }
    }

    /// Combined response of all bands, for the curve display.
    func responseDB(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        coefficients(sampleRate: sampleRate).reduce(0) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }
}

// MARK: - Realtime processor

/// Applies the 10-band cascade to interleaved float audio on the IO thread.
///
/// All storage is allocated up front. New coefficients are published from the
/// main thread under an unfair lock; the render thread only ever *try*-locks,
/// so it never blocks — if the UI happens to hold the lock, that buffer keeps
/// the previous coefficients and picks the new ones up on the next callback.
final class EQProcessor: @unchecked Sendable {
    static let maxChannels = 8

    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    /// Coefficients the UI wants (guarded by `lock`).
    private let pending = UnsafeMutablePointer<Biquad>.allocate(capacity: EQBand.count)
    private let pendingFlags = UnsafeMutablePointer<Bool>.allocate(capacity: 2) // [dirty, enabled]
    /// Coefficients the render thread is using.
    private let active = UnsafeMutablePointer<Biquad>.allocate(capacity: EQBand.count)
    private var activeEnabled = false
    /// Filter state: z1/z2 per band per channel.
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: EQBand.count * maxChannels * 2)

    init() {
        pending.initialize(repeating: .identity, count: EQBand.count)
        active.initialize(repeating: .identity, count: EQBand.count)
        pendingFlags.initialize(repeating: false, count: 2)
        state.initialize(repeating: 0, count: EQBand.count * Self.maxChannels * 2)
    }

    deinit {
        lock.deallocate(); pending.deallocate(); pendingFlags.deallocate()
        active.deallocate(); state.deallocate()
    }

    /// Main thread: publish new settings for the given sample rate.
    func update(_ settings: EQSettings, sampleRate: Double) {
        let coeffs = settings.coefficients(sampleRate: sampleRate)
        os_unfair_lock_lock(lock)
        for i in 0..<EQBand.count { pending[i] = coeffs[i] }
        pendingFlags[0] = true
        pendingFlags[1] = settings.enabled && !settings.isFlat
        os_unfair_lock_unlock(lock)
    }

    /// IO thread: filter `frames` interleaved frames of `channels` in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        if os_unfair_lock_trylock(lock) {
            if pendingFlags[0] {
                for i in 0..<EQBand.count { active[i] = pending[i] }
                let wasEnabled = activeEnabled
                activeEnabled = pendingFlags[1]
                pendingFlags[0] = false
                // Coming back from bypass: stale state would click.
                if activeEnabled && !wasEnabled {
                    state.update(repeating: 0, count: EQBand.count * Self.maxChannels * 2)
                }
            }
            os_unfair_lock_unlock(lock)
        }
        guard activeEnabled else { return }

        let ch = min(channels, Self.maxChannels)
        for band in 0..<EQBand.count {
            let c = active[band]
            for channel in 0..<ch {
                let s = state.advanced(by: (band * Self.maxChannels + channel) * 2)
                var z1 = s[0], z2 = s[1]
                var idx = channel
                for _ in 0..<frames {
                    let x = samples[idx]
                    let y = c.b0 * x + z1
                    z1 = c.b1 * x - c.a1 * y + z2
                    z2 = c.b2 * x - c.a2 * y
                    samples[idx] = y
                    idx += channels
                }
                // Flush denormals so a long silence can't spike CPU.
                s[0] = abs(z1) < 1e-15 ? 0 : z1
                s[1] = abs(z2) < 1e-15 ? 0 : z2
            }
        }
    }
}
