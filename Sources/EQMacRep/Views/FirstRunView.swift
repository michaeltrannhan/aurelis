import SwiftUI

struct FirstRunView: View {
    @ObservedObject var store: AudioControlStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero

            VStack(alignment: .leading, spacing: 20) {
                PermissionStatusView(store: store)

                VStack(alignment: .leading, spacing: 14) {
                    step(
                        index: 1,
                        title: "Grant audio capture",
                        text: "Screen & System Audio Recording lets EQMacRep process other apps’ audio. It never records or stores anything.",
                        icon: "waveform.badge.mic",
                        done: store.permissionState.allowsProcessTaps
                    )
                    step(
                        index: 2,
                        title: "Media keys are optional",
                        text: "Accessibility is only needed for media-key control. Skip it and every popup control still works.",
                        icon: "keyboard",
                        done: false
                    )
                    step(
                        index: 3,
                        title: "Play something and refresh",
                        text: "Start audio in Music or a browser, refresh the app list, then move that app’s volume slider.",
                        icon: "play.circle",
                        done: false
                    )
                }
            }
            .padding(24)

            Divider()

            HStack {
                Text(store.permissionState.allowsProcessTaps ? "You’re all set." : "You can finish this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    store.completeOnboardingIntent()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to EQMacRep")
                    .font(.title2.bold())
                Text("Per-app volume, mute, output routing, boost, and a 10-band EQ — right from your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func step(index: Int, title: String, text: String, icon: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(done ? Color.green : Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
