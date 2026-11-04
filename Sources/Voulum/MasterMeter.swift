import AudioToolbox
import CoreAudio
import Foundation
import os

/// Measures what actually reaches the output, for the desk style's master
/// meter. It is a read-only tap of every process except the apps Voulum
/// already taps: their sound reaches the speakers through Voulum's own
/// process, after gain and EQ, so counting the originals too would measure
/// them twice. Runs only while the popup is open. Lifecycle calls belong on
/// the engine's HAL queue.
final class MasterMeter: @unchecked Sendable {
    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    /// What the running tap was built for: the excluded processes and the output.
    private var builtFor: (excluded: [AudioObjectID], output: AudioObjectID)?
    private let ioQueue = DispatchQueue(label: "dev.oprimo.voulum.master.io", qos: .userInitiated)

    /// [0] / [1] loudest left / right RMS since last read, [2] peak,
    /// [3] tap buffers (1 = interleaved stereo, 2 = one per channel).
    private let shared: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        p.initialize(from: [0, 0, 0, 1], count: 4)
        return p
    }()

    deinit {
        stop()
        shared.deallocate()
    }

    func takeLevels() -> TapLevels {
        let left = shared[0], right = shared[1]
        let levels = TapLevels(rms: ((left * left + right * right) / 2).squareRoot(),
                               peak: shared[2], left: left, right: right)
        shared[0] = 0; shared[1] = 0; shared[2] = 0
        return levels
    }

    /// Start, or restart when the tapped apps or the output device changed.
    func run(excluding processIDs: [AudioObjectID], output: AudioObjectID) {
        let sorted = processIDs.sorted()
        if let builtFor, builtFor.excluded == sorted, builtFor.output == output { return }
        stop()
        do {
            try start(excluding: sorted)
            builtFor = (sorted, output)
        } catch {
            log.error("Master meter off: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    private func start(excluding processIDs: [AudioObjectID]) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processIDs)
        description.name = "\(AppTap.tapNamePrefix)master"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap.isValid else { throw TapError.create("AudioHardwareCreateProcessTap", status) }
        tapID = newTap

        guard let tapUID: String = try tapID.readCF(kAudioTapPropertyUID) else {
            throw TapError.setup("Could not read tap UID")
        }
        if let format: AudioStreamBasicDescription = try? tapID.read(
            kAudioTapPropertyFormat, default: AudioStreamBasicDescription()),
            format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            shared[3] = 2
        } else {
            shared[3] = 1
        }

        let output = try AppTap.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voulum Master Meter",
            kAudioAggregateDeviceUIDKey: "\(AppTap.aggregateUIDPrefix)master.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var newAggregate: AudioObjectID = .unknown
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate.isValid else { throw TapError.create("AudioHardwareCreateAggregateDevice", status) }
        aggregateID = newAggregate

        let shared = self.shared
        var newProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) { _, input, _, _, _ in
            MasterMeter.measure(input, shared: shared)
        }
        guard status == noErr, let newProc else { throw TapError.create("AudioDeviceCreateIOProcIDWithBlock", status) }
        procID = newProc
        status = AudioDeviceStart(aggregateID, newProc)
        guard status == noErr else { throw TapError.create("AudioDeviceStart", status) }
    }

    func stop() {
        if let procID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID.isValid { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = .unknown
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        tapID = .unknown
        builtFor = nil
    }

    // MARK: Realtime (IO thread — no allocation, no locks)

    /// The tap's buffers come after any inputs of the output device (a
    /// headset's mic), so they are read from the end of the list.
    private static func measure(_ input: UnsafePointer<AudioBufferList>, shared: UnsafeMutablePointer<Float>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tapBuffers = Int(shared[3])
        guard list.count >= tapBuffers else { return }
        var sumLeft: Float = 0, sumRight: Float = 0, peak: Float = 0, frames = 0
        if tapBuffers == 1 {
            let buffer = list[list.count - 1]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / 2
            for f in 0..<frames {
                let l = data[f * 2], r = data[f * 2 + 1]
                sumLeft += l * l; sumRight += r * r
                peak = max(peak, abs(l), abs(r))
            }
        } else {
            let lb = list[list.count - 2], rb = list[list.count - 1]
            guard let l = lb.mData?.assumingMemoryBound(to: Float.self),
                  let r = rb.mData?.assumingMemoryBound(to: Float.self) else { return }
            frames = Int(min(lb.mDataByteSize, rb.mDataByteSize)) / MemoryLayout<Float>.size
            for f in 0..<frames {
                sumLeft += l[f] * l[f]; sumRight += r[f] * r[f]
                peak = max(peak, abs(l[f]), abs(r[f]))
            }
        }
        guard frames > 0 else { return }
        let left = (sumLeft / Float(frames)).squareRoot(), right = (sumRight / Float(frames)).squareRoot()
        if left > shared[0] { shared[0] = left }
        if right > shared[1] { shared[1] = right }
        if peak > shared[2] { shared[2] = peak }
    }
}
