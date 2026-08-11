import SwiftUI

struct MixerEmptyStateView: View {
    let state: MixerEmptyState
    var onRefresh: () -> Void
    var onShowInactive: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: iconName)
                .font(AuralisTypography.workspaceTitle(20))
        } description: {
            Text(state.message)
                .font(AuralisTypography.content(.callout))
        } actions: {
            HStack(spacing: 10) {
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.borderedProminent)
                    .tint(AuralisColor.signalCyan)
                    .frame(minHeight: AuralisSpacing.controlMinHit)
                if let onShowInactive, state == .readyEmpty {
                    Button("Show inactive apps", action: onShowInactive)
                        .frame(minHeight: AuralisSpacing.controlMinHit)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.title). \(state.message)")
    }

    private var iconName: String {
        switch state {
        case .starting: "hourglass"
        case .refreshing: "arrow.triangle.2.circlepath"
        case .readyEmpty: "speaker.slash"
        case .permissionLimited: "hand.raised.fill"
        case .degraded: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        }
    }
}
