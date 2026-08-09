import SwiftUI

/// Semantic console tokens. These intentionally name the role a colour plays
/// rather than baking a visual choice into each individual view.
enum AuroraConsoleDesign {
    static let workbench = Color(red: 0.957, green: 0.969, blue: 0.984)
    static let nightDeck = Color(red: 0.027, green: 0.078, blue: 0.149)
    static let graphite = Color(red: 0.090, green: 0.125, blue: 0.200)
    static let signalCyan = Color(red: 0.133, green: 0.827, blue: 0.933)
    static let harmonicViolet = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let peakRose = Color(red: 0.957, green: 0.447, blue: 0.714)

    static func workspaceTitle(_ size: CGFloat = 20) -> Font {
        .custom("Avenir Next Condensed Demi Bold", size: size)
    }

    static func data(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The console's one expressive gesture: a confirmed gain path. It is static
/// by design; success is communicated by tint, which keeps Reduce Motion
/// useful and avoids decorative animation during active mixing.
struct AuroraSignalPath: View {
    let outputName: String
    let volume: Double
    let isMuted: Bool

    private var gainLabel: String {
        isMuted ? "Mute" : "\(Int((volume * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 0) {
            pathNode("Music", symbol: "music.note")
            connector
            pathNode(gainLabel, symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            connector
            pathNode("EQ", symbol: "slider.vertical.3")
            connector
            pathNode("2×", symbol: "waveform.path.ecg")
            connector
            pathNode(outputName, symbol: "hifispeaker.fill", expands: true)
        }
        .padding(12)
        .background(AuroraConsoleDesign.nightDeck, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AuroraConsoleDesign.signalCyan.opacity(0.32), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signal path")
        .accessibilityValue("Music, \(gainLabel), equalizer, two times boost, \(outputName)")
    }

    private var connector: some View {
        Rectangle()
            .fill(AuroraConsoleDesign.signalCyan.opacity(0.42))
            .frame(width: 14, height: 1)
            .accessibilityHidden(true)
    }

    private func pathNode(_ title: String, symbol: String, expands: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(title).lineLimit(1)
        }
        .font(AuroraConsoleDesign.data(10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 7)
        .frame(maxWidth: expands ? .infinity : nil, minHeight: 28)
        .background(AuroraConsoleDesign.graphite, in: Capsule())
    }
}
