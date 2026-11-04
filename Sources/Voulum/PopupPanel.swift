import AppKit
import SwiftUI

/// The popup's window: a borderless, rounded panel that hangs under the
/// menu-bar icon like Control Center's modules, with no arrow. `NSPopover`
/// can't drop its arrow, and as a `.transient` popover in an accessory app it
/// often stayed open after a click elsewhere, because the app was never
/// active to begin with.
final class PopupPanel: NSPanel {
    static let cornerRadius: CGFloat = 16

    private let backdrop = NSVisualEffectView()

    init(content: NSViewController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 0.5
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        contentViewController = content
        let hosted = content.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(backdrop)
        container.addSubview(hosted)
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    // Borderless windows can't become key by default; the popup needs key
    // status for its keyboard controls and the preset name field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The backdrop the content sits on. Swapped by the popup style setting.
    func setBackdrop(_ view: NSView) {
        guard let container = contentView, let hosted = contentViewController?.view else { return }
        container.subviews.filter { $0 !== hosted }.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .below, relativeTo: hosted)
    }

    /// Place the panel's top edge just under the status item, centred on it
    /// but kept inside the screen.
    func position(below button: NSStatusBarButton, size: NSSize) {
        guard let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = min(anchor.minY - 6, visible.maxY)
        setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
