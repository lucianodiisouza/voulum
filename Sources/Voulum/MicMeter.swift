import AVFoundation
import CoreAudio
import Foundation

/// Reads the current microphone's level for the desk style's mic channel.
/// It listens to the input device directly, so it needs microphone access
/// and macOS shows its orange dot while it runs: only while the popup is
/// open in that style. Lifecycle calls belong on the engine's HAL queue.
final class MicMeter: @unchecked Sendable {
    private var deviceID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "dev.oprimo.voulum.mic.io", qos: .userInitiated)

    /// [0] / [1] loudest left / right RMS since last read, [2] peak.
    private let shared: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }()

    deinit {
        stop()
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
    func run(device: AudioObjectID) {
        guard device != deviceID else { return }
        stop()
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
        status = AudioDeviceStart(device, newProc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, newProc)
            log.error("Mic meter off: start failed (\(status))")
            return
        }
        deviceID = device
        procID = newProc
    }

    func stop() {
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
