import Foundation

/// Snapshot of tap health for status reporting. `failedAppMessages` maps an app
/// to a short reason its tap is not active (unsupported, device gone, etc.).
struct CoreAudioTapHealth: Equatable {
    var activeAppCount: Int
    var failedAppMessages: [AudioAppIdentity: String]
    var backendMessage: String

    init(
        activeAppCount: Int = 0,
        failedAppMessages: [AudioAppIdentity: String] = [:],
        backendMessage: String = ""
    ) {
        self.activeAppCount = activeAppCount
        self.failedAppMessages = failedAppMessages
        self.backendMessage = backendMessage
    }

    var issueCount: Int { failedAppMessages.count }
}
