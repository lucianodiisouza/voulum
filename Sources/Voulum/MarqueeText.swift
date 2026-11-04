import SwiftUI

/// A single line of text that truncates with an ellipsis when it's wider than
/// the space available.
///
/// It used to scroll like a ticker. Any animation in the popup makes SwiftUI
/// re-lay out the whole window every frame, so the ticker alone cost about
/// 8% CPU while a long title was on screen; it's static now.
struct MarqueeText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .regular
    var color: Color? = nil

    var body: some View {
        let line = Text(text)
            .font(font)
            .fontWeight(weight)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
        if let color { line.foregroundStyle(color) } else { line }
    }
}
