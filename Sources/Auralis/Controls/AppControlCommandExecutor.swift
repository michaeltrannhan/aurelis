import Foundation

enum AppControlAction {
    case volumeUp
    case volumeDown
    case muteToggle
}

/// Pure command math plus a store-applying executor. Volume-up auto-unmutes;
/// volume-down that reaches zero auto-mutes.
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
}

/// Applies a control action to the resolved target app through the store.
@MainActor
struct AppControlStoreExecutor {
    let store: AudioControlStore

    func perform(_ action: AppControlAction, frontmostBundleID: String?, selectedAppID: AudioAppIdentity?) {
        guard let identity = AppControlTargetResolver.resolve(
            rows: store.displayRows,
            levels: store.appLevels.levels,
            frontmostBundleID: frontmostBundleID,
            selectedAppID: selectedAppID
        ), let current = store.displayRows.first(where: { $0.identity == identity })?.settings else {
            return
        }

        let step = store.settings.customization.volumeStep.fraction
        let next = AppControlCommandExecutor.nextSettings(settings: current, action: action, step: step)
        if next.volume != current.volume {
            store.setVolumeIntent(next.volume, for: identity)
        }
        if next.isMuted != current.isMuted {
            store.setMutedIntent(next.isMuted, for: identity)
        }
    }
}
