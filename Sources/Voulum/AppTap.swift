import AudioToolbox
import CoreAudio
import Foundation

/// Intercepts one app's audio (all of its Core Audio processes at once) and
/// plays it back through Voulum's own pipeline:
///
///   process tap (`.mutedWhenTapped`) ─▶ private aggregate device ─▶ IOProc
///      gain (smoothed) → 10-band EQ → soft limiter → meter → output device(s)
///
/// The aggregate holds the tap plus one or more output devices. With several
/// outputs, the same signal is written to every device's streams, which is how
/// "play on AirPods *and* the speakers" works.
///
/// Threading: created and mutated on `AudioEngine`'s serial HAL queue; the IO
/// thread reads only the preallocated pointers below; the UI writes `gain`,
/// `limiterEnabled` and the EQ (all safe for concurrent single-word access or
/// guarded inside `EQProcessor`).
final class AppTap: @unchecked Sendable {

    static let aggregateUIDPrefix = "com.voulum.aggregate."
    static let tapNamePrefix = "Voulum-"

    let key: String
    let name: String
    private(set) var processIDs: [AudioObjectID] = []
    private(set) var outputUIDs: [String] = []
    private(set) var isActive = false
    private(set) var sampleRate: Double = 48_000

    let eq = EQProcessor()

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "dev.oprimo.voulum.tap.io", qos: .userInteractive)

    /// [0] target gain, [1] current (ramped) gain, [2] peak since last read,
    /// [3] limiter on (0/1), [4] loudest buffer RMS since last read.
    private let shared: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 5)
        p.initialize(from: [1, 1, 0, 0, 0], count: 5)
        return p
    }()

    /// Where the tap's frames sit in the aggregate's input buffer list, and how
    /// each output buffer maps onto its device's channels. Rebuilt with the
    /// aggregate; read-only on the IO thread.
    private let layout = UnsafeMutablePointer<Int32>.allocate(capacity: AppTap.maxBuffers * 2 + 4)
    private static let maxBuffers = 64

    private static let maxFrames = 16_384
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)

    init(key: String, name: String) {
        self.key = key
        self.name = name
        layout.initialize(repeating: 0, count: Self.maxBuffers * 2 + 4)
        scratch.initialize(repeating: 0, count: Self.maxFrames * 2)
    }

    deinit {
        teardown()
        shared.deallocate()
        layout.deallocate()
        scratch.deallocate()
    }

    var gain: Float {
        get { shared[0] }
        set { shared[0] = max(0, newValue) }
    }

    var limiterEnabled: Bool {
        get { shared[3] != 0 }
        set { shared[3] = newValue ? 1 : 0 }
    }

    /// Loudest buffer RMS and sample peak since the previous call (0...~1).
    func takeLevels() -> (rms: Float, peak: Float) {
        let levels = (shared[4], shared[2])
        shared[2] = 0
        shared[4] = 0
        return levels
    }

    // MARK: Lifecycle (HAL queue)

    /// Create (or recreate) the tap for `processIDs` and route it to `outputUIDs`.
    func activate(processIDs: [AudioObjectID], outputUIDs: [String]) throws {
        if isActive && processIDs == self.processIDs {
            if outputUIDs != self.outputUIDs { try reroute(to: outputUIDs) }
            return
        }
        teardown()

        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "\(Self.tapNamePrefix)\(key)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        // Inclusive list: tap ONLY these processes. `isExclusive = true` flips
        // the meaning to "everything except", which would capture every other app.
        description.isExclusive = false

        var newTap: AudioObjectID = .unknown
        let status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap.isValid else {
            throw TapError.create("AudioHardwareCreateProcessTap", status)
        }
        tapID = newTap
        self.processIDs = processIDs

        do {
            try buildAggregate(outputUIDs: outputUIDs)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
            throw error
        }
        isActive = true
        log.info("Tap active for \(self.name, privacy: .public) → \(outputUIDs.count) output(s)")
    }

    /// Move the tapped audio to other device(s) without recreating the tap.
    func reroute(to outputUIDs: [String]) throws {
        guard tapID.isValid else { return }
        teardownAggregate()
        do {
            try buildAggregate(outputUIDs: outputUIDs)
            isActive = true
        } catch {
            isActive = false
            throw error
        }
    }

    func invalidate() {
        teardown()
    }

    private func buildAggregate(outputUIDs requested: [String]) throws {
        guard let tapUID: String = try tapID.readCF(kAudioTapPropertyUID) else {
            throw TapError.setup("Could not read tap UID")
        }
        let outputs = requested.isEmpty ? [try Self.defaultOutputUID()] : requested
        let subDevices: [[String: Any]] = outputs.enumerated().map { index, uid in
            // The first device is the clock; the others are resampled to it.
            [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1]
        }
        let aggregateUID = "\(Self.aggregateUIDPrefix)\(key).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Voulum \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]

        var newAggregate: AudioObjectID = .unknown
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate.isValid else {
            throw TapError.create("AudioHardwareCreateAggregateDevice", status)
        }
        aggregateID = newAggregate
        outputUIDs = requested

        let rate: Float64 = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        if rate > 0 { sampleRate = rate }
        computeLayout(outputs: outputs)

        let shared = self.shared, layout = self.layout, scratch = self.scratch, eq = self.eq
        let ioBlock: AudioDeviceIOBlock = { _, input, _, output, _ in
            AppTap.render(input: input, output: output, shared: shared,
                          layout: layout, scratch: scratch, eq: eq)
        }
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, ioBlock)
        guard status == noErr, let procID else {
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

    /// Work out, once, where the tap's samples land in the input list and what
    /// each output buffer is (its device's channel offset and channel count).
    ///
    /// layout[0] = index of the first tap input buffer
    /// layout[1] = number of tap buffers (1 if interleaved, else one per channel)
    /// layout[2] = tap channels per buffer
    /// layout[3] = number of described output buffers
    /// then per output buffer: (channel offset within its device, device channels)
    private func computeLayout(outputs: [String]) {
        // Tap format → interleaved or not.
        var tapChannels: Int32 = 2, tapBuffers: Int32 = 1
        if let asbd: AudioStreamBasicDescription = try? tapID.read(
            kAudioTapPropertyFormat, default: AudioStreamBasicDescription()) {
            let ch = Int32(max(1, asbd.mChannelsPerFrame))
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                tapChannels = 1; tapBuffers = ch
            } else {
                tapChannels = ch; tapBuffers = 1
            }
        }
        // Inputs on the sub-devices (a headset's mic) come before the tap.
        var deviceInputBuffers: Int32 = 0
        var outputBuffers: [(offset: Int32, channels: Int32)] = []
        for uid in outputs {
            guard let device = Self.device(uid: uid) else { continue }
            let inStreams: [AudioStreamID] = (try? device.readArray(
                kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)) ?? []
            deviceInputBuffers += Int32(inStreams.count)

            let outStreams: [AudioStreamID] = (try? device.readArray(
                kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            let widths: [Int32] = outStreams.map { stream in
                let f: AudioStreamBasicDescription = (try? stream.read(
                    kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
                return Int32(max(1, f.mChannelsPerFrame))
            }
            let total = widths.reduce(0, +)
            var offset: Int32 = 0
            for w in widths {
                outputBuffers.append((offset, total))
                offset += w
            }
        }
        layout[0] = deviceInputBuffers
        layout[1] = tapBuffers
        layout[2] = tapChannels
        let n = min(outputBuffers.count, Self.maxBuffers)
        layout[3] = Int32(n)
        for i in 0..<n {
            layout[4 + i * 2] = outputBuffers[i].offset
            layout[5 + i * 2] = outputBuffers[i].channels
        }
    }

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
        isActive = false
    }

    // MARK: Realtime render (IO thread — no allocation, no locks)

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               shared: UnsafeMutablePointer<Float>,
                               layout: UnsafeMutablePointer<Int32>,
                               scratch: UnsafeMutablePointer<Float>,
                               eq: EQProcessor) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // 1. Gather the tap's frames into interleaved stereo scratch.
        var first = Int(layout[0])
        let tapBuffers = Int(layout[1]), tapChannels = Int(layout[2])
        // If the input list is shorter than expected (device changed under us),
        // assume the tap is at the end — never read a microphone by mistake.
        if first + tapBuffers > inList.count { first = max(0, inList.count - tapBuffers) }
        var frames = 0
        if first < inList.count, let src = inList[first].mData?.assumingMemoryBound(to: Float.self) {
            let bytes = Int(inList[first].mDataByteSize) / MemoryLayout<Float>.size
            if tapBuffers == 1 {
                let ch = max(1, tapChannels)
                frames = min(bytes / ch, maxFrames)
                for f in 0..<frames {
                    let l = src[f * ch]
                    scratch[f * 2] = l
                    scratch[f * 2 + 1] = ch > 1 ? src[f * ch + 1] : l
                }
            } else {
                frames = min(bytes, maxFrames)
                let right = first + 1 < inList.count
                    ? inList[first + 1].mData?.assumingMemoryBound(to: Float.self) : nil
                for f in 0..<frames {
                    scratch[f * 2] = src[f]
                    scratch[f * 2 + 1] = right?[f] ?? src[f]
                }
            }
        }

        // 2. Gain, ramped across the buffer so changes never click.
        if frames > 0 {
            let target = shared[0]
            var g = shared[1]
            let step = (target - g) / Float(frames)
            for f in 0..<frames {
                g += step
                scratch[f * 2] *= g
                scratch[f * 2 + 1] *= g
            }
            shared[1] = target

            // 3. EQ.
            eq.process(scratch, frames: frames, channels: 2)

            // 4. Soft limiter (only when boosting), then metering.
            let limit = shared[3] != 0
            var peak: Float = 0
            var sumSquares: Float = 0
            let knee: Float = 0.89
            for i in 0..<(frames * 2) {
                var x = scratch[i]
                if limit {
                    let a = abs(x)
                    if a > knee {
                        let y = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
                        x = x < 0 ? -y : y
                        scratch[i] = x
                    }
                }
                let a = abs(x)
                if a > peak { peak = a }
                sumSquares += x * x
            }
            if peak > shared[2] { shared[2] = peak }
            let rms = (sumSquares / Float(frames * 2)).squareRoot()
            if rms > shared[4] { shared[4] = rms }
        }

        // 5. Fan out to every output buffer, mapping L/R onto device channels.
        let described = Int(layout[3])
        for b in 0..<outList.count {
            let buffer = outList[b]
            guard let dst = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let width = max(1, Int(buffer.mNumberChannels))
            let outFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / width
            let offset = b < described ? Int(layout[4 + b * 2]) : 0
            let deviceChannels = b < described ? Int(layout[5 + b * 2]) : width
            let n = min(outFrames, frames)
            for c in 0..<width {
                let deviceChannel = offset + c
                for f in 0..<n {
                    let v: Float
                    if deviceChannels == 1 {
                        v = (scratch[f * 2] + scratch[f * 2 + 1]) * 0.5
                    } else if deviceChannel < 2 {
                        v = scratch[f * 2 + deviceChannel]
                    } else {
                        v = 0
                    }
                    dst[f * width + c] = v
                }
            }
            if n < outFrames {
                memset(dst.advanced(by: n * width), 0, (outFrames - n) * width * MemoryLayout<Float>.size)
            }
        }
    }

    // MARK: Helpers

    static func defaultOutputUID() throws -> String {
        let id: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
        guard id.isValid, let uid: String = try id.readCF(kAudioDevicePropertyDeviceUID) else {
            throw TapError.setup("No default output device")
        }
        return uid
    }

    static func device(uid: String) -> AudioObjectID? {
        var uidRef = uid as CFString
        var id = AudioObjectID.unknown
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<CFString>.size), ptr, &size, &id)
        }
        return status == noErr && id.isValid ? id : nil
    }

    /// Destroy aggregate devices / taps a previous run leaked (crash, force
    /// quit). They pile up in coreaudiod otherwise. Blocking — HAL queue only.
    static func reapLeakedDevices() {
        if let devices: [AudioObjectID] = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices) {
            for device in devices where device.isValid {
                guard let uid: String = try? device.readCF(kAudioDevicePropertyDeviceUID),
                      uid.hasPrefix(aggregateUIDPrefix) else { continue }
                let status = AudioHardwareDestroyAggregateDevice(device)
                log.info("Reaped leaked aggregate \(uid, privacy: .public) (status \(status))")
            }
        }
        if let taps: [AudioObjectID] = try? AudioObjectID.system.readArray(kAudioHardwarePropertyTapList) {
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
