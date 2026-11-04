import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The popup is drawn as a mixing desk (`PopupStyle.desk`).
    @Entry var deskStyle = false
}

extension Color {
    /// The desk's amber: unity marks, the boost zone, warnings.
    static let deskAmber = Color(red: 1, green: 0.69, blue: 0.13)
    /// Old silkscreen and bone-coloured plastic: the desk's text, caps and keys.
    static let deskCream = Color(red: 0.93, green: 0.9, blue: 0.82)
}

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
    @State private var inDetent = false
    @Environment(\.deskStyle) private var desk

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
            Group {
                if desk {
                    deskFader(width: width, pos: pos)
                } else {
                    roundSlider(width: width, pos: pos, thumb: thumb)
                }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        var v = value(for: g.location.x / width)
                        // Soft detent at 100%, felt on the trackpad as it catches.
                        let caught = hasBoost && abs(v - 1) < 0.06
                        if caught { v = 1 }
                        if caught && !inDetent { Haptics.detent() }
                        inDetent = caught
                        value = v
                    }
                    .onEnded { _ in dragging = false; inDetent = false; onEditingChanged(false) }
            )
            .background(ScrollWheelReader { delta in
                value = min(maxValue, max(0, (muted ? 0 : value) + (delta > 0 ? step : -step)))
            })
        }
        .frame(height: desk ? 31 : 18)
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

    /// A fader on a desk: a recessed slot with its scale printed under it
    /// (∞, U for unity in amber, 4×) and a chunky ribbed cap. No fill: the
    /// cap's place is the reading, and the meter above shows the sound.
    private func deskFader(width: CGFloat, pos: CGFloat) -> some View {
        let cap = CGSize(width: 15, height: 22)
        let label = Font.system(size: 7.5, weight: .medium, design: .monospaced)
        return VStack(spacing: 1) {
            ZStack(alignment: .leading) {
                ForEach([0, 0.25, 0.5, 0.75], id: \.self) { mark in
                    Rectangle()
                        .fill(Color.white.opacity(0.13))
                        .frame(width: 1, height: 12)
                        .offset(x: width * position(for: Float(mark)) - 0.5)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.08), lineWidth: 0.5).offset(y: 0.5))
                    .frame(height: 4)
                if hasBoost {
                    Rectangle()
                        .fill(Color.deskAmber.opacity(0.85))
                        .frame(width: 1.5, height: 14)
                        .offset(x: width * unityPosition - 0.75)
                }
                DeskFaderCap(muted: muted, pressed: dragging)
                    .frame(width: cap.width, height: cap.height)
                    .offset(x: min(max(0, width * pos - cap.width / 2), width - cap.width))
            }
            .frame(height: cap.height)
            ZStack(alignment: .leading) {
                Text(verbatim: "∞")
                if hasBoost {
                    Text(verbatim: "U").foregroundStyle(Color.deskAmber).offset(x: width * unityPosition - 2.5)
                    Text(verbatim: "4×").frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(verbatim: "U").foregroundStyle(Color.deskAmber).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(label)
            .foregroundStyle(.tertiary)
            .frame(height: 8)
        }
    }

    private func roundSlider(width: CGFloat, pos: CGFloat, thumb: CGFloat) -> some View {
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

/// Force Touch trackpad feedback.
enum Haptics {
    /// The 100% detent. macOS doesn't expose a strength, and a single tap is
    /// easy to miss mid-drag, so it's a "level change" with a second tap
    /// right behind it: one firm click.
    static func detent() {
        let performer = NSHapticFeedbackManager.defaultPerformer
        performer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            performer.perform(.levelChange, performanceTime: .now)
        }
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
    /// Signal touching full scale.
    var clipping = false
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

    @Environment(\.deskStyle) private var desk

    private var levelColor: Color {
        if desk { return clipping ? .deskAmber : Color(red: 0.62, green: 0.88, blue: 0.36) }
        return clipping ? .orange : .green
    }
}

// MARK: - Desk parts

/// The desk style's meter: two rows of square LEDs, left over right, set in
/// a black well. Green, then amber, then red at the top of the scale; levels
/// are 0...1 on the same scale as the level ring.
struct LEDMeter: View {
    var left: Float
    var right: Float
    var clipping = false
    var segments = 24

    var body: some View {
        VStack(spacing: 2) {
            row(left)
            row(right)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 0.5))
        )
        .accessibilityHidden(true)
    }

    private func row(_ level: Float) -> some View {
        let lit = Int((level * Float(segments)).rounded())
        return HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let on = i < lit || (clipping && i == segments - 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? color(i) : Color(white: 0.15))
                    .shadow(color: on ? color(i).opacity(0.55) : .clear, radius: 1.5)
            }
        }
        .frame(height: 5)
    }

    private func color(_ i: Int) -> Color {
        if i >= segments - 2 { return Color(red: 1, green: 0.27, blue: 0.2) }
        if i >= segments - 5 { return .deskAmber }
        return Color(red: 0.42, green: 0.95, blue: 0.36)
    }
}

/// A desk fader cap: a dark block lit from above, with its white line.
struct DeskFaderCap: View {
    var muted = false
    var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: pressed ? 0.42 : 0.37), Color(white: 0.16)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .overlay(Rectangle()
                .fill(Color.white.opacity(muted ? 0.3 : 0.92))
                .frame(width: 2, height: 13))
            .shadow(color: .black.opacity(0.7), radius: 2.5, y: 2)
    }
}

/// The desk style's square key, lit from inside when on (mute, mostly).
struct DeskKey: View {
    let label: String
    var help: String
    var active = false
    var tint: Color = .red
    var size: CGFloat = 22
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Color.white : Color.deskCream.opacity(hovering ? 0.85 : 0.55))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(active ? AnyShapeStyle(tint.gradient)
                                     : AnyShapeStyle(LinearGradient(colors: [Color(white: hovering ? 0.3 : 0.26), Color(white: 0.15)],
                                                                    startPoint: .top, endPoint: .bottom)))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .black.opacity(0.6)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                        .shadow(color: active ? tint.opacity(0.7) : .black.opacity(0.6), radius: active ? 5 : 1.5, y: active ? 0 : 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
    @Environment(\.deskStyle) private var desk

    /// On the desk, "on" lights amber instead of the system accent.
    private var color: Color { desk && tint == .accentColor ? .deskAmber : tint }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(active ? color : Color.secondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(active ? color.opacity(0.16) : Color.primary.opacity(hovering ? 0.09 : 0))
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
