import Foundation

/// Pure ordering model backing arrow-key navigation in the popup. Editing mode
/// clears the order so keyboard selection is disabled while reordering.
final class PopupKeyboardNavModel {
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
}
