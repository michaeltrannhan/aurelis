import SwiftUI

struct FirstRunView: View {
    @ObservedObject var store: AudioControlStore
    @Environment(\.dismiss) private var dismiss
    @State private var isCommitting = false
    @State private var commitErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            VStack(alignment: .leading, spacing: 18) {
                PermissionStatusView(store: store)

                step(
                    index: 1,
                    title: "Grant audio capture",
                    text: "Screen & System Audio Recording lets Auralis hear which apps are playing. Nothing is recorded or stored.",
                    icon: "waveform.badge.mic",
                    done: store.permissionState.allowsProcessTaps
                )
                step(
                    index: 2,
                    title: "Discover audible apps",
                    text: store.displayRows.isEmpty
                        ? "Play audio in Music or a browser. Auralis refreshes automatically once permission is granted."
                        : "Found \(store.displayRows.count) app\(store.displayRows.count == 1 ? "" : "s"). You can start mixing now.",
                    icon: "dot.radiowaves.left.and.right",
                    done: !store.displayRows.isEmpty
                )

                Text("Media-key control stays off until you enable it later in Controls settings.")
                    .font(AuralisTypography.content(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.permissionState.allowsProcessTaps ? "Ready when you are." : "You can continue in discovery mode.")
                        .font(AuralisTypography.content(.caption))
                        .foregroundStyle(.secondary)
                    if let commitErrorMessage {
                        Text(commitErrorMessage)
                            .font(AuralisTypography.content(.caption2))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Button {
                    completeOnboarding()
                } label: {
                    Text(isCommitting ? "Saving…" : "Continue in discovery mode")
                }
                .disabled(isCommitting)
                .frame(minHeight: AuralisSpacing.controlMinHit)

                Button {
                    completeOnboarding()
                } label: {
                    HStack(spacing: 6) {
                        if isCommitting { ProgressView().controlSize(.small) }
                        Text(isCommitting ? "Saving…" : "Start mixing")
                    }
                }
                .disabled(isCommitting)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AuralisColor.signalCyan)
                .frame(minHeight: AuralisSpacing.controlMinHit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520)
        .background(AuralisColor.canvas)
        .task {
            if store.permissionState.allowsProcessTaps {
                store.refreshIntent()
            }
        }
    }

    private func completeOnboarding() {
        guard !isCommitting else { return }
        isCommitting = true
        commitErrorMessage = nil
        Task { @MainActor in
            do {
                try await store.completeOnboarding()
                dismiss()
            } catch {
                commitErrorMessage = UserFacingFailure.from(error, title: "Couldn’t save setup").message
                isCommitting = false
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(AuralisColor.harmonicViolet)
            VStack(alignment: .leading, spacing: 4) {
                Text("Auralis")
                    .font(AuralisTypography.workspaceTitle(28))
                Text("Grant audio access, then start mixing audible apps. Media keys stay optional.")
                    .font(AuralisTypography.content(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AuralisColor.harmonicViolet.opacity(0.18), AuralisColor.signalCyan.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func step(index: Int, title: String, text: String, icon: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.18) : AuralisColor.signalCyan.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(done ? Color.green : AuralisColor.signalCyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AuralisTypography.content(.headline))
                Text(text)
                    .font(AuralisTypography.content(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(index): \(title). \(text)")
    }
}
