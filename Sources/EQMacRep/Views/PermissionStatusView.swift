import SwiftUI

/// Presentation model that turns the raw `AudioCapturePermissionState` into
/// human copy, tint, icon, and the correct call-to-action for each situation.
/// Shared by the menu-bar banner, the settings tab, and onboarding so every
/// surface tells the same story.
struct PermissionPresentation {
    enum Action {
        case request
        case openSettings
        case relaunch
    }

    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isReady: Bool
    let primary: Action?
    let secondary: Action?

    init(state: AudioCapturePermissionState) {
        isReady = state.allowsProcessTaps

        if state.audioUsageDescription == .missing && state.screenCapture == .granted {
            title = "Audio capture unavailable"
            detail = "Screen Recording is granted, but this build is missing its audio-capture usage description. Launch EQMacRep from the packaged .app bundle."
            systemImage = "xmark.seal.fill"
            tint = .red
            primary = .openSettings
            secondary = nil
            return
        }

        switch state.screenCapture {
        case .granted:
            title = "Audio capture ready"
            detail = "EQMacRep can process other apps’ audio in real time."
            systemImage = "checkmark.seal.fill"
            tint = .green
            primary = nil
            secondary = nil
        case .pendingRestart:
            title = "Relaunch to finish setup"
            detail = "macOS applies Screen & System Audio Recording after a restart. Reopen EQMacRep to activate real-time control."
            systemImage = "arrow.clockwise.circle.fill"
            tint = .blue
            primary = .relaunch
            secondary = .openSettings
        case .notDetermined:
            title = "Enable real-time audio control"
            detail = "Grant Screen & System Audio Recording to control volume, mute, boost and EQ for each app. Discovery works without it."
            systemImage = "waveform.badge.mic"
            tint = .orange
            primary = .request
            secondary = .openSettings
        case .denied:
            title = "Screen Recording is turned off"
            detail = "Turn on EQMacRep under Screen & System Audio Recording in System Settings, then reopen the app."
            systemImage = "exclamationmark.triangle.fill"
            tint = .orange
            primary = .openSettings
            secondary = .request
        }
    }
}

/// A polished, self-contained permission card. Reused across the app so the
/// permission flow always looks and behaves identically.
struct PermissionStatusView: View {
    @ObservedObject var store: AudioControlStore
    /// Compact hides the leading icon chrome for tight spaces (menu bar popover).
    var compact: Bool = false

    private var model: PermissionPresentation {
        PermissionPresentation(state: store.permissionState)
    }

    var body: some View {
        let model = model
        HStack(alignment: .top, spacing: 12) {
            if !compact {
                ZStack {
                    Circle()
                        .fill(model.tint.opacity(0.15))
                    Image(systemName: model.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(model.tint)
                }
                .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if compact {
                        Image(systemName: model.systemImage).foregroundStyle(model.tint)
                    }
                    Text(model.title).font(.subheadline.weight(.semibold))
                }

                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.primary != nil || model.secondary != nil {
                    actionButtons(for: model)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.vertical, compact ? 9 : 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(model.tint.opacity(compact ? 0.10 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(model.tint.opacity(0.25), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actionButtons(for model: PermissionPresentation) -> some View {
        if compact {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    buttons(for: model)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 6) {
                    buttons(for: model)
                }
            }
        } else {
            HStack(spacing: 8) {
                buttons(for: model)
            }
        }
    }

    @ViewBuilder
    private func buttons(for model: PermissionPresentation) -> some View {
        if let primary = model.primary {
            button(for: primary, prominent: true, tint: model.tint)
        }
        if let secondary = model.secondary {
            button(for: secondary, prominent: false, tint: model.tint)
        }
    }

    @ViewBuilder
    private func button(for action: PermissionPresentation.Action, prominent: Bool, tint: Color) -> some View {
        let label = title(for: action)
        if prominent {
            Button(label) { perform(action) }
                .buttonStyle(.borderedProminent)
                .tint(tint)
        } else {
            Button(label) { perform(action) }
                .buttonStyle(.bordered)
        }
    }

    private func title(for action: PermissionPresentation.Action) -> String {
        switch action {
        case .request: "Request Access"
        case .openSettings: "Open System Settings"
        case .relaunch: "Quit & Reopen"
        }
    }

    private func perform(_ action: PermissionPresentation.Action) {
        switch action {
        case .request: store.requestAudioCapturePermission()
        case .openSettings: store.openAudioCapturePrivacySettings()
        case .relaunch: store.relaunchForPermission()
        }
    }
}
