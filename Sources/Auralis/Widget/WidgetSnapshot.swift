import Darwin
import AuralisWidgetShared
import Foundation

enum WidgetIPCError: LocalizedError {
    case appGroupUnavailable(String)
    case cannotCreateDirectory(URL, Error)
    case cannotEncode(String, Error)
    case cannotWrite(URL, Error)
    case cannotRead(URL, Error)
    case invalidCommandFile(String)

    var errorDescription: String? {
        switch self {
        case let .appGroupUnavailable(identifier):
            "Widget configuration error: the App Group \(identifier) is unavailable. Verify signing and App Group entitlements for both the app and widget extension."
        case let .cannotCreateDirectory(url, error):
            "Couldn’t create the widget IPC directory at \(url.path): \(error.localizedDescription)"
        case let .cannotEncode(kind, error):
            "Couldn’t encode widget \(kind): \(error.localizedDescription)"
        case let .cannotWrite(url, error):
            "Couldn’t write widget IPC data at \(url.path): \(error.localizedDescription)"
        case let .cannotRead(url, error):
            "Couldn’t read widget IPC data at \(url.path): \(error.localizedDescription)"
        case let .invalidCommandFile(name):
            "Invalid widget command filename: \(name)"
        }
    }
}

struct WidgetSharedLayout: Equatable, Sendable {
    let rootURL: URL

    var snapshotURL: URL { rootURL.appendingPathComponent("snapshot.json") }
    var stagingURL: URL { rootURL.appendingPathComponent("staging", isDirectory: true) }
    var pendingURL: URL { rootURL.appendingPathComponent("pending", isDirectory: true) }
    var claimedURL: URL { rootURL.appendingPathComponent("claimed", isDirectory: true) }
    var resultsURL: URL { rootURL.appendingPathComponent("results", isDirectory: true) }

    func pendingCommandURL(for id: UUID) -> URL {
        pendingURL.appendingPathComponent(Self.fileName(for: id))
    }

    func claimedCommandURL(for id: UUID) -> URL {
        claimedURL.appendingPathComponent(Self.fileName(for: id))
    }

    func resultURL(for id: UUID) -> URL {
        resultsURL.appendingPathComponent(Self.fileName(for: id))
    }

    static func fileName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).json"
    }

    static func commandID(from url: URL) -> UUID? {
        guard url.pathExtension == "json" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
}

/// Sole app-side owner of app-group layout resolution, directory preparation,
/// snapshot writes, and directory descriptor creation. Callers may build the
/// immutable wire snapshot on the main actor, but no filesystem operation is
/// performed there.
actor WidgetIPCFileActor {
    typealias LayoutResolver = @Sendable () throws -> WidgetSharedLayout

    private let layoutResolver: LayoutResolver
    private var resolvedLayout: WidgetSharedLayout?

    init(layoutResolver: @escaping LayoutResolver = {
        try WidgetSharedContainer.resolveLayout()
    }) {
        self.layoutResolver = layoutResolver
    }

    func prepareAndResolveLayout() throws -> WidgetSharedLayout {
        if let resolvedLayout { return resolvedLayout }
        let layout = try layoutResolver()
        try WidgetSharedContainer.prepare(layout)
        resolvedLayout = layout
        return layout
    }

    func write(_ snapshot: WidgetSnapshot) throws -> Date {
        let layout = try prepareAndResolveLayout()
        try WidgetSnapshotWriter.write(snapshot, layout: layout)
        return snapshot.generatedAt
    }

    func openPendingDirectory() throws -> Int32 {
        let layout = try prepareAndResolveLayout()
        let descriptor = Darwin.open(layout.pendingURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}

/// Filesystem locations shared between the app and widget extension. Runtime
/// IPC requires the configured App Group; there is no silent per-process
/// Application Support fallback because that would make controls appear to
/// work while the app and extension write different directories.
enum WidgetSharedContainer {
    static let appGroupID = "group.com.michaeltrannhan.Auralis"
    static let widgetDirectoryName = "widget-ipc-v1"

    static func resolveLayout(fileManager: FileManager = .default) throws -> WidgetSharedLayout {
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw WidgetIPCError.appGroupUnavailable(appGroupID)
        }
        return WidgetSharedLayout(
            rootURL: groupURL.appendingPathComponent(widgetDirectoryName, isDirectory: true)
        )
    }

    static func testLayout(at rootURL: URL) -> WidgetSharedLayout {
        WidgetSharedLayout(rootURL: rootURL)
    }

    static func prepare(_ layout: WidgetSharedLayout, fileManager: FileManager = .default) throws {
        do {
            for url in [layout.rootURL, layout.stagingURL, layout.pendingURL, layout.claimedURL, layout.resultsURL] {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } catch {
            throw WidgetIPCError.cannotCreateDirectory(layout.rootURL, error)
        }
    }
}

enum WidgetWireCodec {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum WidgetSnapshotWriter {
    static func write(_ snapshot: WidgetSnapshot) throws {
        try write(snapshot, layout: WidgetSharedContainer.resolveLayout())
    }

    static func write(_ snapshot: WidgetSnapshot, layout: WidgetSharedLayout) throws {
        try WidgetSharedContainer.prepare(layout)
        let data: Data
        do {
            data = try WidgetWireCodec.makeEncoder().encode(snapshot)
        } catch {
            throw WidgetIPCError.cannotEncode("snapshot", error)
        }
        do {
            try data.write(to: layout.snapshotURL, options: [.atomic])
        } catch {
            throw WidgetIPCError.cannotWrite(layout.snapshotURL, error)
        }
    }

    static func clear() throws {
        let layout = try WidgetSharedContainer.resolveLayout()
        try? FileManager.default.removeItem(at: layout.snapshotURL)
    }
}

enum WidgetSnapshotReader {
    static func read() -> WidgetSnapshot {
        do {
            return read(layout: try WidgetSharedContainer.resolveLayout())
        } catch {
            return .configurationError(error.localizedDescription)
        }
    }

    static func read(layout: WidgetSharedLayout) -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: layout.snapshotURL) else {
            return .empty
        }
        return (try? WidgetWireCodec.makeDecoder().decode(WidgetSnapshot.self, from: data)) ?? .empty
    }
}
