import Foundation
import OSLog

enum DiagnosticSeverity: String, Comparable, Sendable {
    case debug
    case notice
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .notice: 1
        case .warning: 2
        case .error: 3
        }
    }

    static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct DiagnosticLogConfiguration: Sendable {
    let fileURL: URL?
    let minimumSeverity: DiagnosticSeverity
    let maximumBytes: Int

    init(
        fileURL: URL?,
        minimumSeverity: DiagnosticSeverity,
        maximumBytes: Int
    ) {
        self.fileURL = fileURL
        self.minimumSeverity = minimumSeverity
        self.maximumBytes = max(maximumBytes, 1)
    }
}

/// Bounded, single-writer text sink used in addition to the macOS unified log.
/// One rotated backup is retained so diagnostics cannot grow without limit.
final class DiagnosticFileSink: @unchecked Sendable {
    private let configuration: DiagnosticLogConfiguration
    private let queue = DispatchQueue(label: "com.michaeltrannhan.Auralis.diagnostic-file")
    private let formatter: ISO8601DateFormatter

    init(configuration: DiagnosticLogConfiguration) {
        self.configuration = configuration
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func append(
        severity: DiagnosticSeverity,
        category: String,
        message: String,
        timestamp: Date = Date()
    ) {
        guard severity >= configuration.minimumSeverity,
              configuration.fileURL != nil else { return }
        queue.async { [self] in
            write(severity: severity, category: category, message: message, timestamp: timestamp)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func write(
        severity: DiagnosticSeverity,
        category: String,
        message: String,
        timestamp: Date
    ) {
        guard let fileURL = configuration.fileURL else { return }
        let normalizedMessage = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "\(formatter.string(from: timestamp)) [\(severity.rawValue)] [\(category)] \(normalizedMessage)\n"
        let data = Data(line.utf8)

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existingBytes = ((try? fileManager.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.intValue ?? 0
            if existingBytes > 0, existingBytes + data.count > configuration.maximumBytes {
                let backupURL = fileURL.appendingPathExtension("1")
                try? fileManager.removeItem(at: backupURL)
                try fileManager.moveItem(at: fileURL, to: backupURL)
            }
            if !fileManager.fileExists(atPath: fileURL.path) {
                guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Logger(subsystem: InternalDiagnostics.subsystem, category: "diagnostics")
                .error("persistent log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Detailed Debug diagnostics plus bounded, support-friendly Release logs.
/// Debug records every instrumented operation in a repository-local file;
/// Release records only notices, warnings, and errors in ~/Library/Logs/Auralis.
enum InternalDiagnostics {
    static let subsystem = "com.michaeltrannhan.Auralis"

    #if DEBUG
    static let compiledMode = "detailed"
    private static let minimumFileSeverity = DiagnosticSeverity.debug
    private static let maximumFileBytes = 8 * 1_024 * 1_024
    #else
    static let compiledMode = "minimal"
    private static let minimumFileSeverity = DiagnosticSeverity.notice
    private static let maximumFileBytes = 1 * 1_024 * 1_024
    #endif

    private static let sink = DiagnosticFileSink(configuration: .init(
        fileURL: persistentLogURL,
        minimumSeverity: minimumFileSeverity,
        maximumBytes: maximumFileBytes
    ))

    static var persistentLogURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil else {
            return nil
        }

        #if DEBUG
        guard let path = Bundle.main.object(forInfoDictionaryKey: "AuralisDebugLogPath") as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
        #else
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Auralis", isDirectory: true)
            .appendingPathComponent("Auralis.log")
        #endif
    }

    static func beginSession() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let declaredMode = Bundle.main.object(forInfoDictionaryKey: "AuralisDiagnosticsMode") as? String ?? "missing"
        notice(
            "lifecycle",
            "session.begin version=\(version) build=\(build) mode=\(compiledMode) "
                + "pid=\(ProcessInfo.processInfo.processIdentifier) "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        if declaredMode != compiledMode {
            error(
                "diagnostics",
                "configuration mismatch compiled=\(compiledMode) declared=\(declaredMode)"
            )
        }
        record("lifecycle", "session.bundle path=\(Bundle.main.bundlePath)")
    }

    /// Detailed operation event. Compiled out of Release builds.
    static func record(_ category: String, _ message: String) {
        #if DEBUG
        emit(.debug, category: category, message: message)
        #endif
    }

    static func notice(_ category: String, _ message: String) {
        emit(.notice, category: category, message: message)
    }

    static func warning(_ category: String, _ message: String) {
        emit(.warning, category: category, message: message)
    }

    static func error(_ category: String, _ message: String) {
        emit(.error, category: category, message: message)
    }

    static func flush() {
        sink.flush()
    }

    private static func emit(
        _ severity: DiagnosticSeverity,
        category: String,
        message: String
    ) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch severity {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
        sink.append(severity: severity, category: category, message: message)
    }
}
