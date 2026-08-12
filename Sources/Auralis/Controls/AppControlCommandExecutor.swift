import Foundation

enum AppControlAction {
    case volumeUp
    case volumeDown
    case muteToggle
}

enum AppControlCommandExecutor {
    static func mutation(for action: AppControlAction, step: Double) -> ControlMutation {
        switch action {
        case .volumeUp: .adjustVolume(step)
        case .volumeDown: .adjustVolume(-step)
        case .muteToggle: .toggleMute
        }
    }
}

/// Applies a control action to the resolved target app through the commanding surface.
@MainActor
struct AppControlStoreExecutor {
    let store: AudioControlStore

    @discardableResult
    func perform(
        _ action: AppControlAction,
        frontmostBundleID: String?,
        selectedAppID: AudioAppIdentity?,
        source: ControlSource = .ui
    ) -> ControlReceipt? {
        guard let identity = AppControlTargetResolver.resolve(
            rows: store.displayRows,
            levels: store.appLevels.levels,
            frontmostBundleID: frontmostBundleID,
            selectedAppID: selectedAppID
        ) else {
            return nil
        }

        let step = store.settings.customization.volumeStep.fraction
        let mutation = AppControlCommandExecutor.mutation(for: action, step: step)
        return store.submit(
            ControlCommand(
                target: .app(identity),
                mutation: mutation,
                source: source
            )
        )
    }
}
