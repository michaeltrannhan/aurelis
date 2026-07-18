import Foundation
import XCTest

extension XCTestCase {
    /// Returns a unique file URL and registers cleanup for its entire parent
    /// directory, including quarantine files and atomic-write leftovers.
    func temporaryFileURL(
        prefix: String = "AuralisTests",
        filename: String
    ) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent(filename)
    }

    /// Creates a unique directory whose cleanup is owned by the test case.
    func temporaryDirectory(prefix: String = "AuralisTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

/// Reproducible generator used by property and fuzz tests. A failing seed can
/// be copied directly into a regression test.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Deterministically runs DispatchWorkItems scheduled by retry state machines.
/// Cancellation remains production-real because cancelled items are still
/// delivered and rejected by their state/revision guards.
final class ManualTapRetryScheduler {
    private var workItems: [DispatchWorkItem] = []

    var pendingCount: Int { workItems.count }

    func schedule(
        _ queue: DispatchQueue,
        _ delay: TimeInterval,
        _ workItem: DispatchWorkItem
    ) {
        workItems.append(workItem)
    }

    func runUntilIdle(maximumWorkItems: Int = 32) {
        var executed = 0
        while !workItems.isEmpty, executed < maximumWorkItems {
            let item = workItems.removeFirst()
            item.perform()
            executed += 1
        }
        precondition(workItems.isEmpty, "Scheduler exceeded its bounded test budget")
    }
}
