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
                WidgetSnapshot.DeviceSummary(id: "default", name: "MacBook Speakers", volume: 0.75, isMuted: false, isDefault: true)
            ],
            apps: apps
        )
    }()
}

/// Mixer widget — systemMedium shows device output + per-app rows with mute
/// toggle, volume up/down, and boost cycle. systemSmall shows a compact
/// output-volume summary with mute toggle.
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
        .description("Per-app volume, mute, and boost controls on your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// EQ widget — systemLarge shows a focused 10-band EQ for the first active app,
/// with five bands per row and ±0.5 dB buttons.
struct AuralisEQWidget: Widget {
    let kind: String = "AuralisEQWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AuralisProvider()) { entry in
            AuralisEQWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("Auralis EQ")
        .description("10-band equalizer for an active audio app.")
        .supportedFamilies([.systemLarge])
    }
}
