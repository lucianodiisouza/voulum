import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Per-process volume control built on Core Audio process taps (macOS 14.4+).
///
/// Pipeline:
///   1. Create a `CATapDescription` for the target process with
///      `.mutedWhenTapped` — the process's normal output is silenced and its
///      audio is instead delivered to us.
///   2. Build a *private* aggregate device combining the current default output
///      device and that tap.
///   3. Run an IOProc that copies the tapped frames to the output device,
///      multiplied by `gain`. gain 0 = mute, 1 = unity, >1 = boost.
///
/// `gain` is stored behind a stable pointer so the realtime audio thread can
/// read it without locking while the UI writes it from the main thread (aligned
/// 4-byte float access is atomic on Apple Silicon).
/// `@unchecked Sendable`: instances are created on the main thread but activated,
/// torn down, and reaped on `AudioProcessController`'s serial HAL queue, while the
/// UI reads `gain`/`isActive`. Cross-thread access is deliberate — `gain` is
/// pointer-backed (atomic aligned write) and every HAL mutation is serialized on
/// that one queue.
final class ProcessTap: @unchecked Sendable {

    let process: AudioProcess

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.voulum.tap.io", qos: .userInteractive)

    private let gainPtr: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        p.initialize(to: 1.0)
        return p
    }()

    private(set) var isActive = false

    init(process: AudioProcess) {
        self.process = process
    }

    var gain: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0, newValue) }
    }

    // MARK: Lifecycle

    func activate() throws {
        guard !isActive else { return }

        // 1. Tap the process, muting its normal output.
        let description = CATapDescription(
            stereoMixdownOfProcesses: [process.objectID])
        description.name = "\(Self.tapNamePrefix)\(process.pid)"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        // Inclusive list: tap ONLY this process. `isExclusive = true` would flip
        // the list's meaning to "tap everything EXCEPT this process", which routes
        // every *other* app's audio through our aggregate — so lowering one app's
        // slider would mute all the others (and leave the target untouched).
        description.isExclusive = false

        var newTapID: AudioObjectID = .unknown
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID.isValid else {
            throw TapError.create("AudioHardwareCreateProcessTap", status)
        }
        tapID = newTapID

        // 2. Build the aggregate around the current default output device and
        //    start streaming. Split out so it can be rebuilt on its own when the
        //    output device changes (see `rebuildOutput`) without recreating the tap.
        do {
            try buildAggregateAndStart()
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
            throw error
        }

        isActive = true
        log.info("Tap active for \(self.process.name, privacy: .public) (pid \(self.process.pid))")
    }

    /// Rebuild the aggregate device so tapped audio follows the *current* default
    /// output device. Call when `kAudioHardwarePropertyDefaultOutputDevice`
    /// changes (e.g. the user switches from the Mac speakers to a Bluetooth
    /// headset) — the aggregate captured the old device at creation time, so
    /// without this the tapped app keeps playing on the previous output.
    ///
    /// The process tap itself is output-independent, so we keep it and only tear
    /// down and recreate the aggregate + IOProc. `gain` lives behind `gainPtr`, so
    /// the user's volume/mute survives the rebuild. Runs on the HAL queue.
    func rebuildOutput() {
        guard isActive else { return }
        teardownAggregate()
        do {
            try buildAggregateAndStart()
            log.info("Rebuilt output for \(self.process.name, privacy: .public) (pid \(self.process.pid))")
        } catch {
            // Leave the tap in place but inactive; the app is effectively muted
            // until the next activation attempt rather than routed to a dead device.
            isActive = false
            log.error("Failed to rebuild output for \(self.process.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Create the private aggregate device around the current default output
    /// device, install the gain-applying IOProc, and start streaming. Assumes
    /// `tapID` is already a valid process tap.
    private func buildAggregateAndStart() throws {
        // Resolve the current default output device + the tap's UID.
        let outputID: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
        guard outputID.isValid,
              let outputUID: String = try outputID.readCF(kAudioDevicePropertyDeviceUID),
              let tapUID: String = try tapID.readCF(kAudioTapPropertyUID) else {
            throw TapError.setup("Could not resolve output/tap UID")
        }

        let aggregateUID = "\(Self.aggregateUIDPrefix)\(process.pid).\(UUID().uuidString)"
        let description2: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voulum \(process.name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregate: AudioObjectID = .unknown
        var status = AudioHardwareCreateAggregateDevice(description2 as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate.isValid else {
            throw TapError.create("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = newAggregate

        // Install the gain-applying IOProc and start it.
        let gainPtr = self.gainPtr
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, gain: gainPtr.pointee)
        }

        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue, ioBlock)
        guard status == noErr, let procID = newProcID else {
            teardownAggregate()
            throw TapError.create("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            teardownAggregate()
            throw TapError.create("AudioDeviceStart", status)
        }
    }

    func invalidate() {
        guard isActive else { return }
        teardown()
        isActive = false
    }

    /// Stop and destroy the aggregate device + IOProc, leaving the process tap
    /// intact. Used both by full teardown and by `rebuildOutput`.
    private func teardownAggregate() {
        if let procID = ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
    }

    private func teardown() {
        teardownAggregate()
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    deinit {
        teardown()
        gainPtr.deallocate()
    }

    // MARK: Realtime render

    /// Copy tapped input to the output buffers, scaled by `gain`. Runs on the
    /// audio IO thread — no allocations, no locks.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float) {
        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        let pairs = min(inList.count, outList.count)
        var scale = gain

        for i in 0..<outList.count {
            let outBuf = outList[i]
            guard let dst = outBuf.mData else { continue }
            let outFloats = Int(outBuf.mDataByteSize) / MemoryLayout<Float>.size

            if i < pairs, let src = inList[i].mData {
                let n = min(outFloats, Int(inList[i].mDataByteSize) / MemoryLayout<Float>.size)
                vDSP_vsmul(src.assumingMemoryBound(to: Float.self), 1,
                           &scale,
                           dst.assumingMemoryBound(to: Float.self), 1,
                           vDSP_Length(n))
                // Silence any tail the input didn't cover.
                if n < outFloats {
                    memset(dst.advanced(by: n * MemoryLayout<Float>.size), 0,
                           (outFloats - n) * MemoryLayout<Float>.size)
                }
            } else {
                memset(dst, 0, Int(outBuf.mDataByteSize))
            }
        }
    }
}

extension ProcessTap {
    /// UID prefix stamped on every aggregate device we create. Used both to build
    /// new ones and to recognise orphans left behind by a previous crash.
    static let aggregateUIDPrefix = "com.voulum.aggregate."
    /// Prefix on every process-tap description name we create.
    static let tapNamePrefix = "Voulum-"

    /// Destroy any private aggregate devices / process taps this app leaked in a
    /// prior run (e.g. a crash or force-quit that skipped `teardown`). These
    /// accumulate inside coreaudiod and can eventually wedge the whole audio HAL,
    /// so we sweep them at launch. Must run off the main thread — it makes
    /// blocking HAL calls. Safe to call when there's nothing to reap.
    static func reapLeakedDevices() {
        // Orphaned aggregate devices.
        if let devices: [AudioObjectID] = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices) {
            for device in devices where device.isValid {
                guard let uid: String = try? device.readCF(kAudioDevicePropertyDeviceUID),
                      uid.hasPrefix(aggregateUIDPrefix) else { continue }
                let status = AudioHardwareDestroyAggregateDevice(device)
                log.info("Reaped leaked aggregate \(uid, privacy: .public) (status \(status))")
            }
        }

        // Orphaned process taps.
        if let taps: [AudioObjectID] = try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyTapList) {
            for tap in taps where tap.isValid {
                guard let desc: CATapDescription = try? tap.readCF(kAudioTapPropertyDescription),
                      desc.name.hasPrefix(tapNamePrefix) else { continue }
                let name = desc.name
                let status = AudioHardwareDestroyProcessTap(tap)
                log.info("Reaped leaked tap \(name, privacy: .public) (status \(status))")
            }
        }
    }
}

enum TapError: Error, CustomStringConvertible {
    case create(String, OSStatus)
    case setup(String)

    var description: String {
        switch self {
        case let .create(call, status): return "\(call) failed (\(status))"
        case let .setup(message): return message
        }
    }
}
