import AppKit
import Carbon.HIToolbox
import SwiftUI

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case volumeUp, volumeDown, toggleMute, togglePopup

    var id: String { rawValue }
    var title: String {
        switch self {
        case .volumeUp: return "Turn up the app that's playing"
        case .volumeDown: return "Turn down the app that's playing"
        case .toggleMute: return "Mute the app that's playing"
        case .togglePopup: return "Open or close Voulum"
        }
    }
    /// Volume keys repeat while held, like the system volume keys.
    var repeats: Bool { self == .volumeUp || self == .volumeDown }
}

/// A key + modifier combination, stored in Carbon terms (what
/// `RegisterEventHotKey` wants) along with a ready-made label.
struct Hotkey: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        let key = Self.keyName(event.keyCode) ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        // A bare letter would steal normal typing system-wide; require a
        // modifier unless it's a function key.
        let isFunctionKey = Self.functionKeys[event.keyCode] != nil
        guard carbon != 0 || isFunctionKey else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        display = label + key
    }

    private static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19",
    ]

    private static func keyName(_ code: UInt16) -> String? {
        if let f = functionKeys[code] { return f }
        switch Int(code) {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_Tab: return "⇥"
        default: return nil
        }
    }
}

/// Registers the user's global shortcuts with Carbon's hot-key API. Unlike an
/// `NSEvent` global monitor this needs no Accessibility permission, and the
/// shortcut is consumed rather than also reaching the frontmost app.
@MainActor
final class HotkeyCenter {

    static let shared = HotkeyCenter()

    var handler: ((HotkeyAction) -> Void)?

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var repeatTimer: Timer?
    /// While the recorder is capturing a new shortcut, don't fire actions.
    var isSuspended = false

    private static let signature: OSType = 0x564F_554C // 'VOUL'

    func apply(_ hotkeys: [HotkeyAction: Hotkey]) {
        installHandlerIfNeeded()
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        for action in HotkeyAction.allCases {
            guard let key = hotkeys[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature,
                                   id: UInt32(HotkeyAction.allCases.firstIndex(of: action)!))
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
            } else {
                log.error("Couldn't register hotkey \(key.display, privacy: .public) (\(status))")
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let index = Int(hotKeyID.id)
            MainActor.assumeIsolated {
                HotkeyCenter.shared.handle(index: index, pressed: pressed)
            }
            return noErr
        }, types.count, &types, nil, &eventHandler)
    }

    private func handle(index: Int, pressed: Bool) {
        guard HotkeyAction.allCases.indices.contains(index), !isSuspended else { return }
        let action = HotkeyAction.allCases[index]
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard pressed else { return }
        handler?(action)
        guard action.repeats else { return }
        // Same rhythm as key repeat: a pause, then a steady stream until release.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in
                    Task { @MainActor in self.handler?(action) }
                }
            }
        }
    }
}

/// Click, press a shortcut, done. Escape cancels, Delete clears.
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Type shortcut…" : (hotkey?.display ?? "Record Shortcut"))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(recording ? Color.accentColor : (hotkey == nil ? .secondary : .primary))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)

            if hotkey != nil && !recording {
                Button {
                    hotkey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotkeyCenter.shared.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                hotkey = nil
                stop()
            default:
                if let key = Hotkey(event: event) {
                    hotkey = key
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        HotkeyCenter.shared.isSuspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
