import XCTest
import AuralisWidgetShared
@testable import Auralis

final class WidgetSchemaV6Tests: XCTestCase {
    func testConcurrentSequenceAllocationIsUniqueAndOrdered() {
        WidgetCommandSequence.resetForTests(startingAt: 1)
        let values = LockedTestValue<[UInt64]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let value = WidgetCommandSequence.next()
            values.withValue { $0.append(value) }
        }
        XCTAssertEqual(Set(values.value).count, 32)
        XCTAssertEqual(values.value.sorted(), Array(1...32).map(UInt64.init))
    }

    func testRelativeActionsRequireSchemaV6() throws {
        let relative = WidgetCommand(
            schemaVersion: 5,
            sequence: 1,
            targetType: .app,
            targetIdentity: "com.example.Music",
            action: .adjustVolume(0.05)
        )
        XCTAssertThrowsError(try relative.validate()) { error in
            XCTAssertEqual(error as? WidgetCommandValidationError, .unsupportedSchema)
        }

        let v6 = WidgetCommand(
            schemaVersion: 6,
            sequence: 2,
            targetType: .app,
            targetIdentity: "com.example.Music",
            action: .adjustVolume(0.05)
        )
        try v6.validate()
    }

    func testLegacyAbsoluteV5StillValidates() throws {
        let legacy = WidgetCommand(
            schemaVersion: 5,
            sequence: 0,
            targetType: .app,
            targetIdentity: "com.example.Music",
            action: .setVolume(0.4)
        )
        try legacy.validate()
    }
}
