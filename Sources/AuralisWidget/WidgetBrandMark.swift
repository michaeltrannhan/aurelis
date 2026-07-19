import SwiftUI

struct AuralisWidgetMark: View {
    var body: some View {
        Image("AuralisMark")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct AuralisAudioGlyph: View {
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            Capsule().frame(width: 2, height: 7)
            Capsule().frame(width: 2, height: 13)
            Capsule().frame(width: 2, height: 9)
            Capsule().frame(width: 2, height: 16)
            Capsule().frame(width: 2, height: 6)
        }
        .foregroundStyle(
            LinearGradient(
                colors: [Color.cyan, Color.purple, Color.pink],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
        )
        .accessibilityHidden(true)
    }
}
