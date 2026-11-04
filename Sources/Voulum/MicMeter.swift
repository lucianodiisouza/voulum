import AVFoundation
import CoreAudio
import Foundation
import os

/// Reads the current microphone's level for the desk style's mic channel.
/// It listens to the input device directly, so it needs microphone access
/// and macOS shows its orange dot while it runs: only while the popup is
/// open in that style.
///
/// Starting an input device can block for a long time inside Core Audio
/// (seen stuck in `AudioDeviceStart` for minutes on the built-in mic), so
/// the meter starts and stops on its own queue, never the engine's HAL
/// queue: a stuck mic must not hold up the app taps behind it. Requests
/// only record the wanted device; whatever is wanted once the queue frees
/// up is what runs.
final class MicMeter: @unchecked Sendable {
    /// Touched only on `control`.
    private var deviceID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "dev.oprimo.voulum.mic.io", qos: .userInitiated)
    private let control = DispatchQueue(label: "dev.oprimo.voulum.mic.control", qos: .userInitiated)
    /// The device the meter should listen to, `.unknown` for off.
    private let wanted = OSAllocatedUnfairLock<AudioObjectID>(initialState: .unknown)

    /// [0] / [1] loudest left / right RMS since last read, [2] peak.
    private let shared: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }()

    deinit {
        // Queued blocks retain `self`, so none are pending by now.
        apply(.unknown)
        shared.deallocate()
    }

    static var accessGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var accessUndecided: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined }

    func takeLevels() -> TapLevels {
        let left = shared[0], right = shared[1]
        let levels = TapLevels(rms: ((left * left + right * right) / 2).squareRoot(),
                               peak: shared[2], left: left, right: right)
        shared[0] = 0; shared[1] = 0; shared[2] = 0
        return levels
    }

    /// Listen to `device`, switching when the default input changes.
    /// Returns at once; the device starts on the meter's own queue.
    func run(device: AudioObjectID) { request(device) }

    func stop() { request(.unknown) }

    private func request(_ device: AudioObjectID) {
        let changed = wanted.withLock { current in
            defer { current = device }
            return current != device
        }
        guard changed else { return }
        control.async { [self] in apply(wanted.withLock { $0 }) }
    }

    private func apply(_ device: AudioObjectID) {
        guard device != deviceID else { return }
        // If it doesn't start, forget the request so the next poll retries.
        defer { if deviceID != device { wanted.withLock { if $0 == device { $0 = .unknown } } } }
        stopNow()
        guard device.isValid else { return }
        let shared = self.shared
        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, device, ioQueue) { _, input, _, _, _ in
            MicMeter.measure(input, shared: shared)
        }
        guard status == noErr, let newProc else {
            log.error("Mic meter off: IOProc failed (\(status))")
            return
        }
        let started = Date()
        status = AudioDeviceStart(device, newProc)
        let took = Date().timeIntervalSince(started)
        if took > 1 { log.warning("Mic meter took \(took, format: .fixed(precision: 1))s to start") }
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, newProc)
            log.error("Mic meter off: start failed (\(status))")
            return
        }
        deviceID = device
        procID = newProc
    }

    private func stopNow() {
        if let procID, deviceID.isValid {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = .unknown
    }

    // MARK: Realtime (IO thread — no allocation, no locks)

    /// The first input stream; its first two channels are left and right
    /// (a mono mic feeds both rows).
    private static func measure(_ input: UnsafePointer<AudioBufferList>, shared: UnsafeMutablePointer<Float>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        var sumLeft: Float = 0, sumRight: Float = 0, peak: Float = 0
        for f in 0..<frames {
            let l = data[f * channels]
            let r = channels > 1 ? data[f * channels + 1] : l
            sumLeft += l * l; sumRight += r * r
            peak = max(peak, abs(l), abs(r))
        }
        let left = (sumLeft / Float(frames)).squareRoot(), right = (sumRight / Float(frames)).squareRoot()
        if left > shared[0] { shared[0] = left }
        if right > shared[1] { shared[1] = right }
        if peak > shared[2] { shared[2] = peak }
    }
}
