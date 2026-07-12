import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioAggregateCrashGuardTests: XCTestCase {
    func testTrackerAddsAndRemovesAggregateIDs() {
        let tracker = CoreAudioAggregateTracker(maxSlots: 3)

        XCTAssertTrue(tracker.track(10))
        XCTAssertTrue(tracker.track(11))
        tracker.untrack(10)

        XCTAssertEqual(tracker.trackedIDs(), [11])
    }

    func testTrackerRejectsWhenFull() {
        let tracker = CoreAudioAggregateTracker(maxSlots: 1)

        XCTAssertTrue(tracker.track(10))
        XCTAssertFalse(tracker.track(11))
        XCTAssertEqual(tracker.trackedIDs(), [10])
    }

    func testTrackerIgnoresDuplicates() {
        let tracker = CoreAudioAggregateTracker(maxSlots: 4)

        XCTAssertTrue(tracker.track(10))
        XCTAssertFalse(tracker.track(10))
        XCTAssertEqual(tracker.trackedIDs(), [10])
    }
}
