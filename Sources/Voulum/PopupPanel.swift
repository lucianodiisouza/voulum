import AppKit
import SwiftUI

/// The popup's window: a borderless, rounded panel that hangs under the
/// menu-bar icon like Control Center's modules, with no arrow. `NSPopover`
/// can't drop its arrow, and as a `.transient` popover in an accessory app it
/// often stayed open after a click elsewhere, because the app was never
/// active to begin with.
final class PopupPanel: NSPanel {
    static let cornerRadius: CGFloat = 16

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

        contentViewController = content
        let hosted = content.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        apply(.standard)
    }

    // Borderless windows can't become key by default; the popup needs key
    // status for its keyboard controls and the preset name field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Swap the backdrop the content sits on.
    func apply(_ style: PopupStyle) {
        guard let container = contentView, let hosted = contentViewController?.view else { return }
        container.subviews.filter { $0 !== hosted }.forEach { $0.removeFromSuperview() }
        let backdrop = Self.backdrop(for: style.effective)
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop, positioned: .below, relativeTo: hosted)
        invalidateShadow()
    }

    private static func backdrop(for style: PopupStyle) -> NSView {
        if style == .glass, #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        let frosted = NSVisualEffectView()
        frosted.material = .popover
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        frosted.wantsLayer = true
        frosted.layer?.cornerRadius = cornerRadius
        frosted.layer?.cornerCurve = .continuous
        frosted.layer?.masksToBounds = true
        frosted.layer?.borderWidth = 0.5
        frosted.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        return frosted
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
