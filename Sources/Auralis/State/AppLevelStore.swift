import Combine
import Foundation

/// Live per-app audio levels, published on their own object so that the ~10 Hz
/// meter stream invalidates only the small meter leaf views — never the whole
/// window. Writing here does not fire `AudioControlStore.objectWillChange`, so
/// the app list, rows, menu-bar scene, and `onChange(of: displayRows)` handlers
/// no longer re-evaluate and re-layout on every meter tick.
@MainActor
final class AppLevelStore: ObservableObject {
    @Published private(set) var levels: [AudioAppIdentity: Double] = [:]

    func level(for identity: AudioAppIdentity) -> Double {
        levels[identity] ?? 0
    }

    /// Replaces the level map, but only publishes when a value moved by more
    /// than `changeThreshold` (or the set of apps changed). This keeps tiny
    /// sub-perceptual fluctuations from driving continuous meter animations.
    @discardableResult
    func apply(_ newLevels: [AudioAppIdentity: Double], changeThreshold: Double = 0.01) -> Bool {
        var changed = newLevels.count != levels.count
        if !changed {
            for (identity, value) in newLevels where abs((levels[identity] ?? 0) - value) > changeThreshold {
                changed = true
                break
            }
        }
        guard changed else { return false }
        levels = newLevels
        return true
    }

    func clear() {
        if !levels.isEmpty { levels = [:] }
    }
}
