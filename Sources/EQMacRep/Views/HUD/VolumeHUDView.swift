import SwiftUI

/// SwiftUI content for the volume HUD panel.
struct VolumeHUDView: View {
    let state: VolumeHUDState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: MenuBarIconState.symbolName(style: .speaker, volume: state.volume, isMuted: state.isMuted))
                .font(.system(size: 34))
                .foregroundStyle(.primary)
            Text(state.appName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            ProgressView(value: state.isMuted ? 0 : state.volume)
                .progressViewStyle(.linear)
                .frame(width: 160)
            Text(state.isMuted ? "Muted" : "\(state.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 200, height: 180)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
