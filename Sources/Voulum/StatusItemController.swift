import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import SwiftUI

/// Owns the menu-bar item and its popup panel: the icon (which tracks the
/// output device and volume), opening/closing, and keyboard control of the popup.
@MainActor
final class StatusItemController: NSObject {

    static let shared = StatusItemController()

    private var statusItem: NSStatusItem!
    private var panel: PopupPanel!
    private var host: NSHostingController<AnyView>!
    private var keyMonitor: Any?
    private var clickMonitors: [Any] = []
    private var isOpen = false
    private var cancellables: Set<AnyCancellable> = []
    private var flashUntil: Date?
    private var flashSymbol: String?
    private var lastDefaultOutput: AudioObjectID = .unknown

    private let engine = AudioEngine.shared
    private let devices = DeviceController.shared
    private let prefs = Preferences.shared
    private let model = PopupModel.shared

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Voulum")
        }

        let root = PopupView()
            .environmentObject(engine)
            .environmentObject(devices)
            .environmentObject(prefs)
            .environmentObject(engine.meters)
            .environmentObject(model)
        host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = .preferredContentSize
        panel = PopupPanel(content: host)

        // Follow the content's height (devices expanding, apps coming and
        // going), keeping the top edge pinned under the icon.
        host.publisher(for: \.preferredContentSize)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
        prefs.$popupStyle
            .removeDuplicates()
            .sink { [weak self] style in self?.panel.apply(style) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.close() }
            .store(in: &cancellables)

        Publishers.CombineLatest4(devices.$outputLevels, devices.$defaultOutputID, devices.$outputs, prefs.$iconStyle)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, defaultID, _, _ in
                self?.noteDefaultOutput(defaultID)
                self?.updateIcon()
            }
            .store(in: &cancellables)
        updateIcon()
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        toggle()
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard let button = statusItem.button, !isOpen else { return }
        isOpen = true
        engine.beginLiveUpdates()
        devices.refresh()
        if model.focusedKey.map({ key in !engine.visibleApps.contains { $0.key == key } }) ?? false {
            model.focusedKey = nil
        }
        button.highlight(true)
        reposition()
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installKeyMonitor()
        installClickMonitors()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        statusItem.button?.highlight(false)
        removeMonitors()
        engine.endLiveUpdates()
        Preferences.shared.saveNow()
        let panel = panel!
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A quick reopen may have happened during the fade.
                if self?.isOpen == false { panel.orderOut(nil) }
                panel.alphaValue = 1
            }
        })
    }

    private func reposition() {
        guard let button = statusItem?.button, let host else { return }
        var size = host.preferredContentSize
        if size.width < 1 || size.height < 1 { size = host.view.fittingSize }
        panel.position(below: button, size: size)
    }

    /// Any click outside the popup closes it — in another app (global monitor)
    /// or in one of our other windows, like Settings (local monitor). Clicks on
    /// the icon are left to its own toggle, and clicks in the route picker's
    /// popover belong to the popup.
    private func installClickMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, let window = event.window else { return event }
            let ours = window === self.panel
                || window === self.statusItem.button?.window
                || window.parent === self.panel
                || NSStringFromClass(type(of: window)).contains("Popover")
            if !ours { self.close() }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, event.window === self.panel else { return event }
            // Let text fields (saving an EQ preset) have their keys.
            if event.window?.firstResponder is NSText { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let apps = engine.visibleApps
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting([.shift, .function, .numericPad]).isEmpty else { return false }
        let focused = apps.first { $0.key == model.focusedKey }
        let step = prefs.volumeStep.fraction * (flags.contains(.shift) ? 2 : 1)

        switch Int(event.keyCode) {
        case kVK_DownArrow, kVK_UpArrow:
            guard !apps.isEmpty else { return true }
            let down = Int(event.keyCode) == kVK_DownArrow
            if let current = apps.firstIndex(where: { $0.key == model.focusedKey }) {
                let next = max(0, min(apps.count - 1, current + (down ? 1 : -1)))
                model.focusedKey = apps[next].key
            } else {
                model.focusedKey = (down ? apps.first : apps.last)?.key
            }
            return true
        case kVK_LeftArrow, kVK_RightArrow:
            let delta = Int(event.keyCode) == kVK_RightArrow ? step : -step
            if let focused { engine.step(focused, by: delta) } else { devices.stepDefaultOutput(by: delta) }
            return true
        case kVK_Escape:
            if model.expandedEQ != nil { model.expandedEQ = nil } else { close() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            focused?.bringToFront()
            return focused != nil
        case kVK_Space:
            if let focused, engine.canControlTransport(focused) { engine.togglePlayPause(focused) }
            return true
        case kVK_Tab:
            model.devicesExpanded.toggle()
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m":
            if let focused { engine.toggleMute(focused) } else if let d = devices.defaultOutput { devices.toggleMute(d) }
            return true
        case "e":
            if let focused { model.expandedEQ = model.expandedEQ == focused.key ? nil : focused.key }
            return true
        case "0":
            if let focused { engine.setLevel(1, for: focused) }
            return true
        default:
            return false
        }
    }

    // MARK: Icon

    private func noteDefaultOutput(_ id: AudioObjectID) {
        defer { lastDefaultOutput = id }
        guard lastDefaultOutput.isValid, id != lastDefaultOutput,
              let device = devices.outputs.first(where: { $0.id == id }) else { return }
        // Briefly show the new device's glyph so a switch is noticeable.
        flashSymbol = device.symbol
        flashUntil = Date().addingTimeInterval(1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in self?.updateIcon() }
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let level = devices.defaultOutputLevel
        var symbol = Self.symbol(style: prefs.iconStyle, device: devices.defaultOutput,
                                 volume: level.volume, muted: level.muted)
        if let until = flashUntil, until > Date(), let flash = flashSymbol { symbol = flash }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Voulum")?
            .withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Voulum")
        image?.isTemplate = true
        button.image = image
    }

    static func symbol(style: MenuBarIconStyle, device: AudioDevice?, volume: Float, muted: Bool) -> String {
        let silent = muted || volume < 0.01
        switch style {
        case .adaptive:
            if silent { return "speaker.slash.fill" }
            guard let device else { return speaker(volume) }
            switch device.transport {
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            default:
                if device.symbol.hasPrefix("airpods") || device.symbol.contains("headphones") { return device.symbol }
                if device.symbol == "homepod.fill" || device.symbol == "hifispeaker.fill" { return device.symbol }
                return speaker(volume)
            }
        case .speaker:
            return silent ? "speaker.slash.fill" : speaker(volume)
        case .waveform:
            return silent ? "waveform.slash" : "waveform"
        case .dial:
            if silent { return "speaker.slash" }
            return volume < 0.34 ? "dial.low" : volume < 0.67 ? "dial.medium" : "dial.high"
        }
    }

    private static func speaker(_ volume: Float) -> String {
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
