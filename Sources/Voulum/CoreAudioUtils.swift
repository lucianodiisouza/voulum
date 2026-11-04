import AudioToolbox
import CoreAudio
import Foundation
import OSLog

let log = Logger(subsystem: "com.voulum.app", category: "audio")

/// Small, throwing wrappers around the Core Audio property C API so the rest of
/// the code can read/write typed values without manual `AudioObjectID` juggling.
extension AudioObjectID {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != Self.unknown && self != 0 }

    // MARK: Reading

    /// Reads a single fixed-size value (e.g. `pid_t`, `UInt32`, `AudioObjectID`).
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 default defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError.status(status, selector) }
        return value
    }

    /// Reads a variable-length array property (e.g. the process object list).
    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                      of type: T.Type = T.self) throws -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CoreAudioError.status(status, selector) }

        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        // Allocate raw storage rather than seeding an Array with a fake zero:
        // `unsafeBitCast(0, to: T.self)` crashes when T isn't 8 bytes wide.
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, buffer.baseAddress!)
        guard status == noErr else { throw CoreAudioError.status(status, selector) }
        return Array(buffer)
    }

    /// Reads a CoreFoundation-typed property (returns a retained object bridged to Swift).
    func readCF<T>(_ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                   as type: T.Type = T.self) throws -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: CFTypeRef? = nil
        var size = UInt32(MemoryLayout<CFTypeRef?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw)
            }
        }
        guard status == noErr else { throw CoreAudioError.status(status, selector) }
        return value as? T
    }

    // MARK: Writing

    /// Writes a single fixed-size value (e.g. set the default output device, a
    /// device's mute flag, or its scalar volume).
    func write<T>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                  to value: T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectSetPropertyData(self, &address, 0, nil, size, &value)
        guard status == noErr else { throw CoreAudioError.status(status, selector) }
    }

    // MARK: Existence

    func hasProperty(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    // MARK: Virtual main volume

    /// The device's "virtual main" volume (0...1) — the single value macOS's own
    /// volume slider drives. Unlike `kAudioDevicePropertyVolumeScalar` on the main
    /// element, it works on devices that only expose per-channel volume (most
    /// USB and Bluetooth hardware). nil when the device has no volume control.
    func virtualMainVolume(scope: AudioObjectPropertyScope) -> Float? {
        let selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        guard hasProperty(selector, scope: scope) else { return nil }
        return try? read(selector, scope: scope, default: Float32(0))
    }

    func canSetVirtualMainVolume(scope: AudioObjectPropertyScope) -> Bool {
        isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
    }

    @discardableResult
    func setVirtualMainVolume(_ volume: Float, scope: AudioObjectPropertyScope) -> Bool {
        let value = Float32(Swift.max(0, Swift.min(1, volume)))
        return (try? write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: scope, to: value)) != nil
    }

    // MARK: Listening

    /// Register one block for several properties of this object. Returns a token
    /// that removes every registration when cancelled.
    func listen(to selectors: [AudioObjectPropertySelector],
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                queue: DispatchQueue,
                _ block: @escaping AudioObjectPropertyListenerBlock) -> PropertyListenerToken {
        var addresses: [AudioObjectPropertyAddress] = []
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(self, &address, queue, block) == noErr {
                addresses.append(address)
            }
        }
        return PropertyListenerToken(objectID: self, addresses: addresses, queue: queue, block: block)
    }
}

/// Keeps a Core Audio listener block alive and removes it on `cancel()`.
final class PropertyListenerToken {
    private let objectID: AudioObjectID
    private var addresses: [AudioObjectPropertyAddress]
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID, addresses: [AudioObjectPropertyAddress],
         queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.addresses = addresses
        self.queue = queue
        self.block = block
    }

    func cancel() {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
        }
        addresses.removeAll()
    }

    deinit { cancel() }
}

enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus, AudioObjectPropertySelector)

    var description: String {
        switch self {
        case let .status(status, selector):
            return "CoreAudio error \(status) for selector \(selector.fourCC)"
        }
    }
}

extension AudioObjectPropertySelector {
    /// Human-readable four-character-code, handy in logs.
    var fourCC: String {
        let value = UInt32(self)
        let chars = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        if chars.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return String(bytes: chars, encoding: .ascii) ?? "\(value)"
        }
        return "\(value)"
    }
}
