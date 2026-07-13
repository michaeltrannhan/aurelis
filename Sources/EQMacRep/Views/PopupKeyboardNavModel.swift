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

    /// Return acts on the current row, or on the first visible row when keyboard
    /// navigation has not established a selection yet.
    func returnActionTarget(for current: AudioAppIdentity?) -> AudioAppIdentity? {
        if let current, orderedAppIDs.contains(current) {
            return current
        }
        return orderedAppIDs.first
    }
}

/// Chooses a stable target for the header's quick controls. An explicit popup
/// selection wins; otherwise use the first active row in the persisted display
/// order, then the first row. Live level changes must not retarget a click.
enum PopupQuickActionTargetResolver {
    static func resolve(
        rows: [DisplayableAppRow],
        selectedAppID: AudioAppIdentity?
    ) -> AudioAppIdentity? {
        if let selectedAppID,
           rows.contains(where: { $0.identity == selectedAppID }) {
            return selectedAppID
        }
        if let active = rows.first(where: \.isActive) { return active.identity }
        return rows.first?.identity
    }
}
