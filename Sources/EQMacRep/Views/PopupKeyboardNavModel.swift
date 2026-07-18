import Foundation

/// Pure ordering model backing arrow-key navigation in the popup. Editing mode
/// clears the order so keyboard selection is disabled while reordering.
final class PopupKeyboardNavModel {
    static let visibleKeyboardHint = "↑/↓ select · Return EQ · Space mute · ←/→ volume"
    static let accessibilityHint = "Up and Down select an app. Return opens its equalizer. Space toggles mute. Left and Right adjust volume."

    private(set) var orderedAppIDs: [AudioAppIdentity] = []

    func sync(apps: [AudioAppIdentity], isEditing: Bool) {
        orderedAppIDs = isEditing ? [] : apps
    }

    func next(after current: AudioAppIdentity?) -> AudioAppIdentity? {
        guard !orderedAppIDs.isEmpty else { return nil }
        guard let current,
              let index = orderedAppIDs.firstIndex(of: current) else {
            return orderedAppIDs.first
        }
        let nextIndex = index + 1
        return nextIndex < orderedAppIDs.count ? orderedAppIDs[nextIndex] : nil
    }

    func previous(before current: AudioAppIdentity?) -> AudioAppIdentity? {
        guard let current,
              let index = orderedAppIDs.firstIndex(of: current),
              index > 0 else {
            return nil
        }
        return orderedAppIDs[index - 1]
    }

    /// Return acts on the current row, or on the first visible row when keyboard
    /// navigation has not established a selection yet.
    func returnActionTarget(for current: AudioAppIdentity?) -> AudioAppIdentity? {
        if let current, orderedAppIDs.contains(current) {
            return current
        }
        return orderedAppIDs.first
    }
}
