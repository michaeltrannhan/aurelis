import EQMacRepWidgetShared
import SwiftUI
import WidgetKit

/// Timeline entry carrying a `WidgetSnapshot` plus the widget family so views
/// can branch on size.
struct EQMacRepEntry: TimelineEntry {
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
struct EQMacRepProvider: TimelineProvider {
    func placeholder(in context: Context) -> EQMacRepEntry {
        EQMacRepEntry(date: Date(), snapshot: Self.placeholderSnapshot, family: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (EQMacRepEntry) -> Void) {
        let entry = EQMacRepEntry(date: Date(), snapshot: WidgetSnapshotReader.read(), family: context.family)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EQMacRepEntry>) -> Void) {
        let snapshot = WidgetSnapshotReader.read()
        let now = Date()
        let entry = EQMacRepEntry(date: now, snapshot: snapshot, family: context.family)

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
struct EQMacRepMixerWidget: Widget {
    let kind: String = "EQMacRepMixerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EQMacRepProvider()) { entry in
            EQMacRepMixerWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("EQMacRep Mixer")
        .description("Per-app volume, mute, and boost controls on your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// EQ widget — systemLarge shows the mixer plus a 10-band EQ chart for the
/// first active app, with ±0.5 dB buttons per band.
struct EQMacRepEQWidget: Widget {
    let kind: String = "EQMacRepEQWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EQMacRepProvider()) { entry in
            EQMacRepEQWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("EQMacRep EQ")
        .description("10-band equalizer for an active audio app.")
        .supportedFamilies([.systemLarge])
    }
}
