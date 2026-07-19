import AppIntents

/// System-wide shortcut exposure belongs to the containing application. The
/// interactive intent implementations themselves are also compiled into the
/// widget extension so WidgetKit can execute them without opening the app.
struct AuralisAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAppIntent(),
            phrases: ["Refresh \(.applicationName) audio apps"],
            shortTitle: "Refresh Audio Apps",
            systemImageName: "arrow.clockwise"
        )
    }
}
