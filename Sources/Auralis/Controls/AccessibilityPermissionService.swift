import ApplicationServices
import AppKit
import Foundation

@MainActor
protocol AccessibilityPermissionClient {
    func isProcessTrusted() -> Bool
    func requestProcessTrust() -> Bool
    @discardableResult func openPrivacySettings() -> Bool
}

@MainActor
struct SystemAccessibilityPermissionClient: AccessibilityPermissionClient {
    func isProcessTrusted() -> Bool { AXIsProcessTrusted() }

    func requestProcessTrust() -> Bool {
        // The string is the documented value of
        // kAXTrustedCheckOptionPrompt; using it avoids importing the mutable
        // global under Swift 6 concurrency checking.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openPrivacySettings() -> Bool {
        NSWorkspace.shared.open(AccessibilityPermissionService.privacySettingsURL)
    }
}

/// Wraps Accessibility trust state, required for the media-key CGEvent tap.
@MainActor
final class AccessibilityPermissionService: ObservableObject {
    @Published private(set) var isTrusted: Bool
    private let client: any AccessibilityPermissionClient

    init(client: any AccessibilityPermissionClient = SystemAccessibilityPermissionClient()) {
        self.client = client
        self.isTrusted = client.isProcessTrusted()
    }

    func refresh() {
        isTrusted = client.isProcessTrusted()
    }

    func requestAccess() {
        _ = client.requestProcessTrust()
        refresh()
    }

    @discardableResult
    func openPrivacySettings() -> Bool {
        client.openPrivacySettings()
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
