import SwiftUI

enum AudioIssuePresentationModel {
    static func visibleIssues(
        _ issues: [AudioIssue],
        permissionState: AudioCapturePermissionState,
        hidesAudioPermissionIssue: Bool
    ) -> [AudioIssue] {
        issues.filter { issue in
            !(hidesAudioPermissionIssue
                && !permissionState.allowsProcessTaps
                && issue.id == "audio-permission")
        }
    }

    static func recoveryTitle(_ recovery: AudioRecoveryAction) -> String {
        switch recovery {
        case .retry: "Retry"
        case .retryExternalControls: "Retry Controls"
        case .requestAudioPermission: "Request Access"
        case .openAudioPrivacySettings: "Open Settings"
        case .requestAccessibilityPermission: "Request Accessibility"
        case .openAccessibilitySettings: "Open Settings"
        case .followDefaultOutput: "Use Default Output"
        case .ignoreApp: "Ignore App"
        }
    }
}

/// Presents every current issue and exhaustively wires every advertised
/// recovery action. Permission cards may hide their duplicate store issue while
/// still showing unrelated backend, tap, persistence, widget, and control faults.
struct AudioIssueListView: View {
    @ObservedObject var store: AudioControlStore
    @EnvironmentObject private var controls: ExternalControlsCoordinator
    let issues: [AudioIssue]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ForEach(issues) { issue in
                issueBanner(issue)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio issues")
    }

    private func issueBanner(_ issue: AudioIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.message)
                    .font(compact ? .caption : .callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = issue.recovery {
                    Button(AudioIssuePresentationModel.recoveryTitle(recovery)) {
                        perform(recovery)
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 4)
            Button {
                store.dismissIssue(id: issue.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss issue")
            .accessibilityLabel("Dismiss issue")
        }
        .padding(compact ? 10 : 12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func perform(_ recovery: AudioRecoveryAction) {
        switch recovery {
        case .retry:
            store.refreshIntent()
        case .retryExternalControls:
            controls.applySettings()
        case .requestAudioPermission:
            store.requestAudioCapturePermission()
        case .openAudioPrivacySettings:
            store.openAudioCapturePrivacySettings()
        case .requestAccessibilityPermission:
            controls.requestAccessibilityAccess()
        case .openAccessibilitySettings:
            controls.openAccessibilitySettings()
        case let .followDefaultOutput(identity):
            Task { try? await store.setRoute(.followDefault, for: identity) }
        case let .ignoreApp(identity):
            Task { try? await store.ignore(identity) }
        }
    }
}
