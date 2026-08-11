import Foundation

enum AppControlAction {
    case volumeUp
    case volumeDown
    case muteToggle
}

/// Pure command math plus a store-applying executor. Volume-up auto-unmutes;
/// volume-down that reaches zero auto-mutes — applied as one atomic mutation.
enum AppControlCommandExecutor {
    static func nextSettings(settings: AppAudioSettings, action: AppControlAction, step: Double) -> AppAudioSettings {
        var next = settings
        switch action {
        case .volumeUp:
            next.setVolume(next.volume + step)
            next.isMuted = false
        case .volumeDown:
            next.setVolume(next.volume - step)
            if next.volume <= 0.001 {
                next.isMuted = true
            }
        case .muteToggle:
            next.isMuted.toggle()
        }
        return next
    }

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
