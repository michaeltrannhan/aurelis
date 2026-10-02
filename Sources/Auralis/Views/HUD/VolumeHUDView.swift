import SwiftUI

/// SwiftUI content for the volume HUD, drawn as a console-style channel strip:
/// a vertical LED meter in the stage-accent palette beside a quiet text column.
/// The transient flash becomes the brand moment; nothing else competes with it.
struct VolumeHUDView: View {
    let state: VolumeHUDState
    let peak: Double

    private let segmentCount = 12

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(state.appName)
                    .font(AuralisTypography.workspaceTitle(15))
                    .lineLimit(1)
                Text("APP VOLUME")
                    .font(AuralisTypography.metric(9))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(state.isMuted ? "MUTED" : "\(state.percent)%")
                    .font(AuralisTypography.metric(24))
                    .foregroundStyle(state.isMuted ? AuralisColor.peakRose : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            ChannelStripMeter(
                level: state.isMuted ? 0 : state.volume,
                peak: state.isMuted ? 0 : peak,
                segmentCount: segmentCount
            )
            .frame(width: 18)
        }
        .padding(16)
        .frame(width: 208, height: 148)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(AuralisColor.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.appName) volume")
        .accessibilityValue(state.isMuted ? "Muted" : "\(state.percent) percent")
    }
}

/// Bottom-up LED column. Lit segments run signal cyan; the hot zone (top three)
/// runs peak rose, and the highest segment reached by `peak` stays rose after
/// the level drops — the channel-strip peak hold.
private struct ChannelStripMeter: View {
    let level: Double
    let peak: Double
    let segmentCount: Int

    private var hotZoneStart: Int { segmentCount - 3 }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: litFraction)
        .animation(.easeOut(duration: 0.12), value: peakIndex)
        .accessibilityHidden(true)
    }

    private var litFraction: Double { min(max(level, 0), 1) }

    private var peakIndex: Int {
        Int((min(max(peak, 0), 1) * Double(segmentCount - 1)).rounded())
    }

    private func color(for index: Int) -> Color {
        let position = Double(segmentCount - 1 - index) // 0 = bottom, 11 = top
        let litTop = litFraction * Double(segmentCount - 1)

        if peak > litFraction, Int(position.rounded()) == peakIndex {
            return AuralisColor.peakRose.opacity(0.55)
        }
        guard litFraction > 0, position <= litTop + 0.001 else {
            return Color.primary.opacity(0.10)
        }
        return position >= Double(hotZoneStart) ? AuralisColor.peakRose : AuralisColor.signalCyan
    }
}
