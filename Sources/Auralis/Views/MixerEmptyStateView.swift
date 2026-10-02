import SwiftUI

struct MixerEmptyStateView: View {
    let state: MixerEmptyState
    var onRefresh: () -> Void
    var onShowInactive: (() -> Void)?
    var onResetFilter: (() -> Void)? = nil
    var compact = false

    var body: some View {
        ContentUnavailableView {
            Label(state.title, systemImage: iconName)
                .font(AuralisTypography.workspaceTitle(compact ? 17 : 20))
        } description: {
            Text(state.message)
                .font(AuralisTypography.content(.callout))
        } actions: {
            HStack(spacing: 10) {
                if state == .starting {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Discovering audio apps")
                } else if let onResetFilter, isFilteredEmpty {
                    Button(state == .noMatchingApps ? "Clear search" : "Show all apps", action: onResetFilter)
                        .buttonStyle(.bordered)
                        .frame(minHeight: AuralisSpacing.controlMinHit)
                } else {
                    Button("Refresh", action: onRefresh)
                    .buttonStyle(.borderedProminent)
                    .tint(AuralisColor.stageAccent(.process))
                    .frame(minHeight: AuralisSpacing.controlMinHit)
                }
                if let onShowInactive, state == .readyEmpty {
                    Button("Show inactive apps", action: onShowInactive)
                        .frame(minHeight: AuralisSpacing.controlMinHit)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: compact ? 116 : 220)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.title). \(state.message)")
    }

    private var iconName: String {
        switch state {
        case .starting: "hourglass"
        case .readyEmpty: "speaker.slash"
        case .permissionLimited: "hand.raised.fill"
        case .degraded: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        case .noMatchingApps: "magnifyingglass"
        case .noPinnedApps: "pin"
        case .noPlayingApps: "speaker.slash"
        }
    }

    private var isFilteredEmpty: Bool {
        state == .noMatchingApps || state == .noPinnedApps || state == .noPlayingApps
    }
}
