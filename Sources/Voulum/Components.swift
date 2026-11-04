import AppKit
import SwiftUI

// MARK: - Volume slider

/// Voulum's slider. One control covers the whole range: the first three
/// quarters of the track are 0–100%, the last quarter is a tinted *boost zone*
/// up to `maxValue` (4x for apps). Dragging across 100% sticks there briefly so
/// "back to normal" is easy to hit. Scrolling over it nudges by the user's step.
struct VolumeSlider: View {
    @Binding var value: Float
    var maxValue: Float = 1
    var muted = false
    var step: Float = 0.05
    var tint: Color = .accentColor
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragging = false
    @State private var hovering = false

    private var hasBoost: Bool { maxValue > 1 }
    /// Track fraction where 100% sits.
    private var unityPosition: CGFloat { hasBoost ? 0.75 : 1 }

    private func position(for v: Float) -> CGFloat {
        guard hasBoost else { return CGFloat(v / maxValue) }
        if v <= 1 { return CGFloat(v) * unityPosition }
        return unityPosition + CGFloat((v - 1) / (maxValue - 1)) * (1 - unityPosition)
    }

    private func value(for p: CGFloat) -> Float {
        let p = min(1, max(0, p))
        guard hasBoost else { return Float(p) * maxValue }
        if p <= unityPosition { return Float(p / unityPosition) }
        return 1 + Float((p - unityPosition) / (1 - unityPosition)) * (maxValue - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let pos = position(for: muted ? 0 : value)
            let thumb: CGFloat = dragging ? 16 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 5)
                if hasBoost {
                    // The boost zone reads as "extra", not as more of the same.
                    Capsule()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: width * (1 - unityPosition), height: 5)
                        .offset(x: width * unityPosition)
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 1.5, height: 9)
                        .offset(x: width * unityPosition - 0.75)
                }
                Capsule()
                    .fill(fillStyle)
                    .frame(width: max(5, width * pos), height: 5)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: thumb, height: thumb)
                    .offset(x: min(max(0, width * pos - thumb / 2), width - thumb))
                    .opacity(hovering || dragging ? 1 : 0.92)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        var v = value(for: g.location.x / width)
                        // Soft detent at 100%.
                        if hasBoost && abs(v - 1) < 0.06 { v = 1 }
                        value = v
                    }
                    .onEnded { _ in dragging = false; onEditingChanged(false) }
            )
            .background(ScrollWheelReader { delta in
                value = min(maxValue, max(0, (muted ? 0 : value) + (delta > 0 ? step : -step)))
            })
        }
        .frame(height: 18)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: dragging)
        .accessibilityElement()
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(maxValue, value + step)
            case .decrement: value = max(0, value - step)
            @unknown default: break
            }
        }
    }

    private var fillStyle: AnyShapeStyle {
        if muted { return AnyShapeStyle(Color.secondary.opacity(0.4)) }
        if hasBoost && value > 1 {
            return AnyShapeStyle(LinearGradient(colors: [tint, tint, .orange],
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(tint)
    }
}

/// Delivers scroll-wheel / trackpad scrolls over the view it backs, without
/// stealing clicks (it listens through a local monitor rather than hit-testing).
struct ScrollWheelReader: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReaderView)?.onScroll = onScroll
    }

    final class ReaderView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                // Horizontal-ish swipes stay with the scroll view; vertical
                // (or natural horizontal) scroll adjusts the slider.
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
                    ? event.scrollingDeltaY : -event.scrollingDeltaX
                let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                if event.hasPreciseScrollingDeltas {
                    // Trackpads send many tiny deltas; one step per ~12 points.
                    self.accumulated += delta * sign
                    while abs(self.accumulated) >= 12 {
                        self.onScroll?(self.accumulated)
                        self.accumulated -= self.accumulated > 0 ? 12 : -12
                    }
                } else if delta != 0 {
                    self.onScroll?(delta * sign)
                }
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Level ring

/// An app icon wrapped in a ring that lights up with its live output level —
/// the fastest way to spot which app is actually making the noise.
struct AppIconWithLevel: View {
    let icon: NSImage
    var level: Float = 0
    var active = true
    /// Playing but not metered (Voulum leaves untouched apps alone, so there's
    /// no signal to read): breathe gently instead of showing a level.
    var playing = false
    var size: CGFloat = 30

    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 2.5)
            if playing && level < 0.01 {
                Circle()
                    .stroke(Color.green.opacity(breathe ? 0.55 : 0.12), lineWidth: 2.5)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathe)
                    .onAppear { breathe = true }
            }
            Circle()
                .trim(from: 0, to: CGFloat(level))
                .stroke(levelColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.08), value: level)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size - 6, height: size - 6)
                .saturation(active ? 1 : 0)
                .opacity(active ? 1 : 0.55)
        }
        .frame(width: size + 4, height: size + 4)
    }

    private var levelColor: Color {
        level > 0.93 ? .orange : .green
    }
}

// MARK: - Small controls

/// A borderless round icon button with a hover highlight.
struct IconButton: View {
    let systemName: String
    var help: String
    var active = false
    var tint: Color = .accentColor
    var size: CGFloat = 24
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(active ? tint : Color.secondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(active ? tint.opacity(0.16) : Color.primary.opacity(hovering ? 0.09 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Rounded "card" backdrop used for rows that are focused, hovered or expanded.
struct RowBackground: View {
    var highlighted: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.07 : 0))
    }
}

extension Float {
    /// "73%", "250%".
    var percentLabel: String { "\(Int((self * 100).rounded()))%" }
}
