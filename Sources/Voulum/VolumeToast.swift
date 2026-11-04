import AppKit
import SwiftUI

/// A small, click-through toast near the bottom of the screen confirming a
/// hotkey change: which app, its new level, muted or not. Without it, a global
/// shortcut that adjusts a background app gives no feedback at all.
@MainActor
final class VolumeToast {
    static let shared = VolumeToast()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(app: AudioApp, settings: AppAudioSettings) {
        let content = ToastView(icon: app.icon, name: app.name, level: settings.level, muted: settings.muted)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 90))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

private struct ToastView: View {
    let icon: NSImage
    let name: String
    let level: Float
    let muted: Bool

    /// Same scale as the popup slider: 100% at three quarters, boost beyond.
    private var fill: CGFloat {
        if muted { return 0 }
        if level <= 1 { return CGFloat(level) * 0.75 }
        return 0.75 + CGFloat((level - 1) / (AppAudioSettings.maxLevel - 1)) * 0.25
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(muted ? "Muted" : level.percentLabel)
                        .font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(muted ? Color.red : (level > 1 ? .orange : .secondary))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(muted ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(level > 1 ? Color.orange : .accentColor))
                            .frame(width: geo.size.width * fill)
                    }
                }
                .frame(height: 5)
            }
            .frame(width: 190)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .padding(10)
    }
}
