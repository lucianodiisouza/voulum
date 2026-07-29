import SwiftUI

/// A single line of text that scrolls horizontally when it's wider than the
/// space available, instead of truncating with an ellipsis — the same gentle
/// ticker the system Now Playing widget uses. When the text fits, it's a plain
/// static label.
///
/// Two copies are laid out with a gap and the pair is animated left by exactly
/// one copy-plus-gap, so the loop is seamless: at the end of a cycle the second
/// copy sits precisely where the first began.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .regular

    /// Space between the tail of one copy and the head of the next.
    private let spacing: CGFloat = 44
    /// Scroll speed, in points per second. Deliberately slow so it reads easily.
    private let velocity: Double = 28

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflowing: Bool {
        containerWidth > 0 && textWidth > containerWidth + 1
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in containerWidth = new }
                }
            )
            .onChange(of: text) { _, _ in resync() }
            .onChange(of: textWidth) { _, _ in resync() }
            .onChange(of: containerWidth) { _, _ in resync() }
    }

    @ViewBuilder private var content: some View {
        if overflowing {
            HStack(spacing: spacing) {
                label
                label
            }
            .offset(x: offset)
        } else {
            label
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .fontWeight(weight)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { textWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, new in textWidth = new }
                }
            )
    }

    /// (Re)start the loop for the current text/size. Called on every size or
    /// text change so a new song restarts the scroll from the beginning.
    private func resync() {
        offset = 0
        guard overflowing else { return }
        let distance = textWidth + spacing
        withAnimation(.linear(duration: Double(distance) / velocity).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }
}
