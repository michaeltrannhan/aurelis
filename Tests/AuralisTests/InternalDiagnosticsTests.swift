import Foundation
import XCTest
@testable import Auralis

final class InternalDiagnosticsTests: XCTestCase {
    func testMinimalSinkFiltersDebugAndNormalizesLines() throws {
        let directory = try temporaryDirectory(prefix: "AuralisDiagnostics")
        let logURL = directory.appendingPathComponent("Auralis.log")
        let sink = DiagnosticFileSink(configuration: .init(
            fileURL: logURL,
            minimumSeverity: .notice,
            maximumBytes: 4_096
        ))

        sink.append(severity: .debug, category: "audio", message: "hidden detail")
        sink.append(
            severity: .notice,
            category: "lifecycle",
            message: "release\nsummary",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        sink.flush()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("hidden detail"))
        XCTAssertTrue(contents.contains("[notice] [lifecycle] release summary"))
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
    }

    func testOversizedUnicodeEventsStayWithinCurrentAndBackupByteLimits() throws {
        let directory = try temporaryDirectory(prefix: "AuralisOversizedDiagnostics")
        let logURL = directory.appendingPathComponent("Auralis.log")
        let maximumBytes = 119
        let sink = DiagnosticFileSink(configuration: .init(
            fileURL: logURL,
            minimumSeverity: .debug,
            maximumBytes: maximumBytes
        ))
        for _ in 0..<2 {
            sink.append(severity: .notice, category: "test", message: String(repeating: "音", count: 100))
        }
        sink.flush()

        for url in [logURL, logURL.appendingPathExtension("1")] {
            let data = try Data(contentsOf: url)
            XCTAssertLessThanOrEqual(data.count, maximumBytes)
            let contents = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(contents.hasSuffix("\n"))
        }
    }

    func testSinkRotatesToOneBoundedBackup() throws {
        let directory = try temporaryDirectory(prefix: "AuralisDiagnosticsRotation")
        let logURL = directory.appendingPathComponent("Auralis.log")
        let sink = DiagnosticFileSink(configuration: .init(
            fileURL: logURL,
            minimumSeverity: .debug,
            maximumBytes: 160
        ))

        sink.append(severity: .notice, category: "test", message: String(repeating: "a", count: 80))
        sink.flush()
        sink.append(severity: .error, category: "test", message: String(repeating: "b", count: 80))
        sink.flush()

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let backup = try String(contentsOf: logURL.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertTrue(current.contains(String(repeating: "b", count: 80)))
        XCTAssertFalse(current.contains(String(repeating: "a", count: 80)))
        XCTAssertTrue(backup.contains(String(repeating: "a", count: 80)))
    }
}
