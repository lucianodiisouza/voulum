import SwiftUI

/// A single line of text that scrolls horizontally when it's wider than the
/// space available, instead of truncating with an ellipsis — the same gentle
/// ticker the system Now Playing widget uses. When the text fits, it's a plain
/// static label.
///
/// Layout is deliberately contained so the row keeps its normal width: an
/// invisible truncating line defines the view's box (a normal, flexible width
/// and the correct line height), and the visible text — static or scrolling —
/// rides in an overlay measured against that box and clipped to it. That keeps
/// the scrolling copies (which are intrinsically far wider than the row) from
/// leaking their width up into the parent and shoving the menu window around.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .regular

    /// Space between the tail of one copy and the head of the next.
    private let spacing: CGFloat = 44
    /// Scroll speed, in points per second. Deliberately slow so it reads easily.
    private let velocity: Double = 28

    /// Rest at the start of each pass so the beginning can be read.
    private let pause: Double = 2

    @State private var textWidth: CGFloat = 0
    /// When the current pass began; reset whenever the text changes.
    @State private var start = Date()
    @Environment(\.onScreen) private var onScreen

    var body: some View {
        // Invisible sizer: a normal truncating line. Defines height + a sane,
        // non-leaking width; the real text is drawn in the overlay.
        lineText
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { visible }
            .background { widthProbe }
            .onChange(of: text) { _, _ in start = Date() }
    }

    /// The visible layer: measures the space it's been given and either shows a
    /// static line or the scrolling pair, always clipped to that width.
    ///
    /// The scroll position is computed from the clock rather than animated: a
    /// `repeatForever` animation also captures any layout change in flight when
    /// it starts (the popover sliding in), which left titles stuck mid-row.
    private var visible: some View {
        GeometryReader { geo in
            let overflowing = textWidth > geo.size.width + 1
            Group {
                if overflowing {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !onScreen)) { context in
                        HStack(spacing: spacing) {
                            lineText.fixedSize()
                            lineText.fixedSize()
                        }
                        .offset(x: offset(at: context.date))
                    }
                } else {
                    lineText
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
    }

    private func offset(at date: Date) -> CGFloat {
        let distance = Double(textWidth + spacing)
        let travel = distance / velocity
        let t = date.timeIntervalSince(start).truncatingRemainder(dividingBy: travel + pause)
        return t < pause ? 0 : -CGFloat((t - pause) * velocity)
    }

    /// Measures the full (untruncated) text width without affecting layout —
    /// it lives in a background, so its intrinsic size never reaches the parent.
    private var widthProbe: some View {
        lineText
            .fixedSize()
            .hidden()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in textWidth = w }
                }
            )
    }

    private var lineText: some View {
        Text(text)
            .font(font)
            .fontWeight(weight)
            .lineLimit(1)
    }
}
