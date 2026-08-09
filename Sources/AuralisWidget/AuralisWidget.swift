import AuralisWidgetShared
import SwiftUI
import WidgetKit

/// Timeline entry carrying a `WidgetSnapshot` plus the widget family so views
/// can branch on size.
struct AuralisEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let family: WidgetFamily
}

/// Provider that reads the shared `WidgetSnapshot` from disk. The app writes
/// the snapshot on every store change; the widget reads it here.
///
/// Refresh policy: poll at one second only while a concrete command ID remains
/// pending or claimed. The host reloads timelines after publishing a result;
/// ordinary snapshots use the normal interval (or the host lease boundary).
struct AuralisProvider: TimelineProvider {
    func placeholder(in context: Context) -> AuralisEntry {
        AuralisEntry(date: Date(), snapshot: Self.placeholderSnapshot, family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (AuralisEntry) -> Void) {
        let snapshot = WidgetSnapshotReader.read()
        WidgetDiagnostics.record(
            "snapshot family=\(String(describing: context.family)) host=\(snapshot.hostState.rawValue) apps=\(snapshot.apps.count)"
        )
        let entry = AuralisEntry(date: Date(), snapshot: snapshot, family: context.family)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AuralisEntry>) -> Void) {
        let snapshot = WidgetSnapshotReader.read()
        WidgetDiagnostics.record(
            "timeline family=\(String(describing: context.family)) host=\(snapshot.hostState.rawValue) apps=\(snapshot.apps.count)"
        )
        let now = Date()
        let entry = AuralisEntry(date: now, snapshot: snapshot, family: context.family)

        let nextRefresh = WidgetTimelineRefreshPolicy.nextRefresh(
            now: now,
            snapshot: snapshot,
            hasPendingCommand: !WidgetCommandQueue.pendingCommandIDs().isEmpty
        )
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    /// Static sample shown in the widget gallery before the app has ever run.
    static let placeholderSnapshot: WidgetSnapshot = {
        let apps = (0..<3).map { index in
            WidgetSnapshot.AppSummary(
                id: "sample-\(index)",
                displayName: ["Music", "Safari", "Spotify"][index],
                isActive: index != 2,
                isPinned: index == 0,
                level: [0.72, 0.45, 0.0][index],
                volume: [0.85, 0.60, 0.50][index],
                isMuted: false,
                boost: [1, 1, 2][index],
                routeLabel: "Follow Default (MacBook Speakers)",
                eqGains: [0, 0, 1, 2, 0, -1, 0, 0, 1.5, 0],
                eqRange: 12
            )
        }
        return WidgetSnapshot(
            generatedAt: Date(),
            hostState: .running,
            hostUpdatedAt: Date(),
            statusMessage: "Loaded 3 apps",
            activeAppCount: 2,
            volumeStep: 0.05,
            devices: [
                WidgetSnapshot.DeviceSummary(id: "default", name: "MacBook Speakers", volume: 0.75, isMuted: false, isDefault: true),
                WidgetSnapshot.DeviceSummary(id: "home", name: "Living Room", volume: 0.62, isMuted: false, isDefault: false),
                WidgetSnapshot.DeviceSummary(id: "display", name: "Studio Display", volume: 0.48, isMuted: false, isDefault: false)
            ],
            apps: apps,
            profiles: [
                WidgetSnapshot.ProfileSummary(
                    id: "11111111-1111-1111-1111-111111111111",
                    name: "Home Speaker",
                    scope: .outputDevice,
                    outputDeviceID: "default"
                ),
                WidgetSnapshot.ProfileSummary(id: "22222222-2222-2222-2222-222222222222", name: "Office"),
                WidgetSnapshot.ProfileSummary(id: "33333333-3333-3333-3333-333333333333", name: "Focus")
            ],
            activeGlobalProfileID: "22222222-2222-2222-2222-222222222222",
            activeLocalProfileID: "11111111-1111-1111-1111-111111111111"
        )
    }()
}

/// Mixer widget — small is a focused master-output remote, medium combines
/// master output with two app rows, and large adds profiles plus output choice.
struct AuralisMixerWidget: Widget {
    let kind: String = "AuralisMixerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AuralisProvider()) { entry in
            AuralisMixerWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("Auralis Mixer")
        .description("Profiles, output selection, master volume, and per-app controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Quick Remote widget (technical kind preserved as AuralisEQWidget so installed
/// large EQ widgets upgrade in place).
struct AuralisEQWidget: Widget {
    let kind: String = "AuralisEQWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AuralisProvider()) { entry in
            AuralisEQWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("Auralis Quick Remote")
        .description("Focused-app volume, mute, boost, route summary, and Open Inspector.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
