import XCTest
@testable import Auralis

final class AudioHealthReducerTests: XCTestCase {
    func testPermissionDenialNeverReducesToReady() {
        var inputs = AudioHealthInputs(
            permissionAllowsTaps: false,
            permissionDenied: true,
            visibleAppCount: 3,
            statusMessage: "Ready"
        )
        inputs.isRefreshing = true
        let snapshot = AudioHealthReducer.reduce(inputs)
        XCTAssertEqual(snapshot.phase, .permissionLimited)
        if case .ready = snapshot.operationState {
            XCTFail("permission denial must not project ready")
        }
    }

    func testDiscoveryFailureStaysFailedAcrossRefreshActivity() {
        let inputs = AudioHealthInputs(
            isRefreshing: true,
            discoveryFailed: true,
            discoveryFailureMessage: "Backend error: OSStatus=-50 at /Users/me/secret",
            visibleAppCount: 2
        )
        let snapshot = AudioHealthReducer.reduce(inputs)
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertFalse(snapshot.message.contains("OSStatus"))
        XCTAssertFalse(snapshot.message.contains("/Users/"))
    }

    func testEmptyReadyWhenNoAppsAndHealthy() {
        let snapshot = AudioHealthReducer.reduce(
            AudioHealthInputs(visibleAppCount: 0, statusMessage: "No active apps")
        )
        XCTAssertEqual(snapshot.phase, .empty)
        if case let .ready(message) = snapshot.operationState {
            XCTAssertEqual(message, "No active apps")
        } else {
            XCTFail("expected ready compatibility projection for empty healthy mixer")
        }
    }
}

final class UserFacingFailureTests: XCTestCase {
    func testRedactsOSStatusSelectorsAppGroupsAndPaths() {
        let raw = "failed OSStatus=-50 selector=foo group.com.example.Auralis path=/Users/me/Library/settings.json"
        let failure = UserFacingFailure(title: "Error", message: raw, technicalDetail: raw)
        XCTAssertFalse(failure.message.contains("OSStatus"))
        XCTAssertFalse(failure.message.contains("selector=foo"))
        XCTAssertFalse(failure.message.contains("group.com"))
        XCTAssertFalse(failure.message.contains("/Users/"))
    }
}

