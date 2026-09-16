import AppKit
import SwiftUI

struct LaunchAtLoginSection: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        Section("Startup") {
            LaunchAtLoginToggle(controller: controller, isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0, opensLoginItemsIfNeeded: true) }
            ))
            Button("Open Login Items Settings") {
                controller.openLoginItemsSettings()
            }
            LaunchAtLoginFooter(controller: controller)
        }
    }
}

struct LaunchAtLoginToggle: View {
    @ObservedObject var controller: LaunchAtLoginController
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Open at login", isOn: $isOn)
            .disabled(!controller.canChange)
            .onAppear { controller.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                controller.refresh()
            }
    }
}

struct LaunchAtLoginFooter: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        Group {
            if controller.status == .requiresApproval {
                settingsHelper("Allow Auralis under System Settings → General → Login Items, then return here.")
            } else if controller.status == .unavailable {
                settingsHelper("Install the signed Auralis.app to start mixing automatically after login.")
            } else {
                settingsHelper("Starts Auralis when you log in so mixing is ready after restart.")
            }
            if let lastErrorMessage = controller.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
