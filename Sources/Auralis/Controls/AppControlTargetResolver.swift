import Foundation

/// Chooses which app a media key / hotkey should control. Priority: the loudest
/// audible app, else the frontmost app if it is in the list, else the current
/// selection, else the first pinned app, else the first row.
enum AppControlTargetResolver {
    static let audibleThreshold = 0.05

    static func resolve(
        rows: [DisplayableAppRow],
        frontmostBundleID: String?,
        selectedAppID: AudioAppIdentity?
    ) -> AudioAppIdentity? {
        if let audible = rows.filter({ $0.level >= audibleThreshold }).max(by: { $0.level < $1.level }) {
            return audible.identity
        }
        if let frontmostBundleID,
           let row = rows.first(where: { $0.identity.rawValue == frontmostBundleID || $0.settings.displayName == frontmostBundleID }) {
            return row.identity
        }
        if let selectedAppID, rows.contains(where: { $0.identity == selectedAppID }) {
            return selectedAppID
        }
        return rows.first(where: \.isPinned)?.identity ?? rows.first?.identity
    }
}
