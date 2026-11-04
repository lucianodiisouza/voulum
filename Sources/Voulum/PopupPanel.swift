import AppKit
import SwiftUI

/// The popup's window: a borderless, rounded panel that hangs under the
/// menu-bar icon like Control Center's modules, with no arrow. `NSPopover`
/// can't drop its arrow, and as a `.transient` popover in an accessory app it
/// often stayed open after a click elsewhere, because the app was never
/// active to begin with.
final class PopupPanel: NSPanel {
    static let cornerRadius: CGFloat = 16

    /// The SwiftUI content. Its controller is owned by the caller; the panel
    /// only re-parents the view when the backdrop changes.
    private let hosted: NSView

    init(content: NSViewController) {
        hosted = content.view
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

        apply(.standard)
    }

    // Borderless windows can't become key by default; the popup needs key
    // status for its keyboard controls and the preset name field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Swap the backdrop the content sits on. The SwiftUI content is placed
    /// *inside* it: Liquid Glass only draws around a view that is its
    /// `contentView`, and vibrancy works the same way for the frosted style.
    func apply(_ style: PopupStyle) {
        let size = frame.size
        hosted.removeFromSuperview()
        hosted.translatesAutoresizingMaskIntoConstraints = true
        hosted.autoresizingMask = [.width, .height]
        let backdrop = Self.backdrop(for: style.effective)
        // Clip the content too, so row highlights can't poke past the corners.
        hosted.wantsLayer = true
        hosted.layer?.cornerRadius = Self.cornerRadius
        hosted.layer?.cornerCurve = .continuous
        hosted.layer?.masksToBounds = true
        if #available(macOS 26, *), let glass = backdrop as? NSGlassEffectView {
            glass.contentView = hosted
            // Glass paints a soft halo past its corner radius; inside a
            // borderless window that shows as smudged square corners.
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = Self.cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.frame = clip.bounds
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            contentView = clip
        } else {
            hosted.frame = backdrop.bounds
            backdrop.addSubview(hosted)
            contentView = backdrop
        }
        setContentSize(size)
        // Glass draws its own rim and depth; a window shadow would trace the
        // panel's square frame around the rounded glass.
        hasShadow = style.effective != .glass
        appearance = style.effective == .desk ? NSAppearance(named: .darkAqua) : nil
        invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    private static func backdrop(for style: PopupStyle) -> NSView {
        if style == .glass, #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        if style == .desk {
            // A solid panel, like the desk's metal: nothing shows through.
            let panel = DeskBackdrop()
            panel.wantsLayer = true
            panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
            panel.layer?.borderWidth = 1
            panel.layer?.cornerRadius = cornerRadius
            panel.layer?.cornerCurve = .continuous
            panel.layer?.masksToBounds = true
            return panel
        }
        let frosted = NSVisualEffectView()
        frosted.material = .popover
        frosted.blendingMode = .behindWindow
        frosted.state = .active
        // A mask image, not a layer corner radius: it rounds the blur itself
        // and the window shadow follows it, so no square corners show through.
        frosted.maskImage = roundedMask
        return frosted
    }

    /// Stretchable rounded-rect mask matching the panel's corners.
    private static let roundedMask: NSImage = {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }()

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
        invalidateShadow()
    }
}

/// The desk style's panel: warm dark metal with a fine grain and a lit top
/// edge, the way light catches the front of an old console.
private final class DeskBackdrop: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = PopupPanel.cornerRadius
        let shape = NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r)
        shape.addClip()
        NSGradient(starting: NSColor(srgbRed: 0.14, green: 0.125, blue: 0.105, alpha: 1),
                   ending: NSColor(srgbRed: 0.075, green: 0.068, blue: 0.058, alpha: 1))?
            .draw(in: bounds, angle: 90)
        NSColor(patternImage: Self.grain).setFill()
        bounds.fill(using: .sourceOver)
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSRect(x: r, y: 0, width: bounds.width - r * 2, height: 1).fill(using: .sourceOver)
    }

    /// A tile of random light and dark specks, a few percent opaque.
    private static let grain: NSImage = {
        let side = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: side * 2, bitsPerPixel: 16)!
        let data = rep.bitmapData!
        for i in 0..<(side * side) {
            let alpha = UInt8.random(in: 0...14)
            // Premultiplied: half the specks light, half dark.
            data[i * 2] = Bool.random() ? alpha : 0
            data[i * 2 + 1] = alpha
        }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        image.addRepresentation(rep)
        return image
    }()
}
