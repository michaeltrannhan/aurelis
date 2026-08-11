import XCTest
@testable import Auralis

final class HostLeaseCoordinatorTests: XCTestCase {
    func testFreshLaunchBecomesOwner() {
        let decision = HostLeaseCoordinator.decide(existing: nil, currentPID: 42)
        if case let .becomeOwner(lease) = decision {
            XCTAssertEqual(lease.pid, 42)
        } else {
            XCTFail("expected becomeOwner")
        }
    }

    func testSecondLaunchActivatesExistingOwner() {
        let existing = AppGroupHostLease(pid: 7, heartbeatAt: Date())
        let decision = HostLeaseCoordinator.decide(existing: existing, currentPID: 99)
        XCTAssertEqual(decision, .activateExistingOwner)
    }

    func testStaleLeaseIsTakenOver() {
        let existing = AppGroupHostLease(
            pid: 7,
            heartbeatAt: Date().addingTimeInterval(-30)
        )
        let decision = HostLeaseCoordinator.decide(existing: existing, now: Date(), currentPID: 99)
        if case let .takeOverStale(lease) = decision {
            XCTAssertEqual(lease.pid, 99)
        } else {
            XCTFail("expected takeOverStale")
        }
    }
}

final class AudioSeamsTests: XCTestCase {
    func testOutputValuePrefersLastKnownWhenStale() {
        let value = OutputValue.stale(0.42)
        XCTAssertEqual(value.displayValue, 0.42)
        XCTAssertEqual(value.availability, .stale)
        XCTAssertNotEqual(OutputValue.unavailable(lastKnown: 1.0 as Double).availability, .available)
    }

    func testSystemOutputRouteKeepsAggregateMembersAndClock() {
        let route = SystemOutputRoute(
            uid: "agg-1",
            name: "Multi-Output Device",
            kind: .multiOutput,
            isDefault: true,
            physicalMemberUIDs: ["usb", "hdmi"],
            clockSourceUID: "usb"
        )
        XCTAssertEqual(route.physicalMemberUIDs.count, 2)
        XCTAssertEqual(route.clockSourceUID, "usb")
        XCTAssertFalse(route.physicalMemberUIDs.contains(where: { $0 == route.uid }))
    }

    func testTapReconcileReportAllReadyRequiresStatuses() {
        var report = TapReconcileReport()
        XCTAssertFalse(report.allReady)
        report.statuses = [
            AudioAppIdentity(rawValue: "a"): .ready,
            AudioAppIdentity(rawValue: "b"): .retrying(attempt: 1),
        ]
        XCTAssertFalse(report.allReady)
        report.statuses[AudioAppIdentity(rawValue: "b")] = .ready
        XCTAssertTrue(report.allReady)
    }
}

@MainActor
final class StorePhaseTests: XCTestCase {
    func testShutdownRejectsNewCommands() async throws {
        let store = AudioControlStore(
            settingsStore: SettingsStore(settingsURL: temporaryFileURL(filename: "settings.json")),
            backend: MockAudioBackend()
        )
        await store.waitUntilReady()
        _ = await store.shutdown()
        XCTAssertEqual(store.storePhase, .stopped)
        let receipt = store.submit(
            ControlCommand(target: .activeApps, mutation: .setMuted(true), source: .ui)
        )
        XCTAssertFalse(receipt.accepted)
    }
}
