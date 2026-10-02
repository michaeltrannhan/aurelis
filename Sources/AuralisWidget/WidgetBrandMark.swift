import AuralisWidgetShared
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

// Opaque rails and adaptive panels mirror the host mixer without importing
// host-only audio models into the widget extension.
enum WidgetPalette {
    static let cyan = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.25, green: 0.83, blue: 0.92, alpha: 1)
            : NSColor(red: 0.02, green: 0.43, blue: 0.50, alpha: 1)
    })
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let rail = Color(nsColor: .separatorColor)
}

struct WidgetVolumeRail: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetPalette.rail)
                Capsule().fill(isMuted ? Color.secondary : WidgetPalette.cyan)
                    .frame(width: geometry.size.width * min(max(volume, 0), 1))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct WidgetOpenLink: View {
    var body: some View {
        Link(destination: AuralisDeepLink.openMixer) {
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(WidgetPalette.panel, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("Open Auralis mixer")
    }
}
