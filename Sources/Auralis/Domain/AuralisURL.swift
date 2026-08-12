import Foundation

enum AuralisURL {
    static let accessibilityPrivacySettings = validated(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    static let screenCapturePrivacySettings = validated(
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )
    static let fineTuneRepository = validated("https://github.com/ronitsingh10/FineTune")

    private static func validated(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid bundled URL: \(value)")
        }
        return url
    }
}
