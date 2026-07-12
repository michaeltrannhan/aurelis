import ApplicationServices
import Foundation

/// Wraps Accessibility trust state, required for the media-key CGEvent tap.
@MainActor
final class AccessibilityPermissionService: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    func requestAccess() {
        // "AXTrustedCheckOptionPrompt" is the documented value of the
        // kAXTrustedCheckOptionPrompt global; used literally to avoid touching
        // that non-concurrency-safe global var under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
