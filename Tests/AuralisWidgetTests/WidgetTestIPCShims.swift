import AuralisWidgetShared
import Foundation

// Rendering tests compile the production widget views and AppIntent types in
// an ordinary XCTest bundle. The transport itself is exercised by the app
// test target; these shims keep rendering deterministic and side-effect free.
enum WidgetSnapshotReader {
    static func read() -> WidgetSnapshot { .empty }
}

enum WidgetCommandQueue {
    static func pendingCommandIDs() -> [UUID] { [] }

    @discardableResult
    static func enqueue(_ command: WidgetCommand) throws -> Bool {
        _ = command
        return true
    }
}
