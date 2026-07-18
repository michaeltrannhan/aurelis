import Foundation
import XCTest
@testable import Auralis

final class MediaTapRecoveryPolicyTests: XCTestCase {
    func testDisableBurstUsesBoundedBackoffThenStops() {
        var policy = MediaTapRecoveryPolicy()

        XCTAssertEqual(policy.decision(at: 100), .reenable(afterNanoseconds: 0))
        XCTAssertEqual(policy.decision(at: 101), .reenable(afterNanoseconds: 250_000_000))
        XCTAssertEqual(policy.decision(at: 102), .reenable(afterNanoseconds: 1_000_000_000))
        guard case let .stop(message) = policy.decision(at: 103) else {
            return XCTFail("Expected bounded recovery to stop after the retry budget")
        }
        XCTAssertTrue(message.contains("repeatedly disabled"))
    }

    func testQuietWindowResetsRecoveryBudget() {
        var policy = MediaTapRecoveryPolicy(window: 10)
        _ = policy.decision(at: 10)
        _ = policy.decision(at: 11)
        _ = policy.decision(at: 12)

        XCTAssertEqual(policy.decision(at: 23), .reenable(afterNanoseconds: 0))
    }

    func testClockRollbackResetsStaleDisableHistory() {
        var policy = MediaTapRecoveryPolicy()
        _ = policy.decision(at: 50)
        _ = policy.decision(at: 51)

        XCTAssertEqual(policy.decision(at: 5), .reenable(afterNanoseconds: 0))
    }

    func testExplicitResetRestoresFirstRetry() {
        var policy = MediaTapRecoveryPolicy()
        _ = policy.decision(at: 0)
        _ = policy.decision(at: 1)
        policy.reset()

        XCTAssertEqual(policy.decision(at: 2), .reenable(afterNanoseconds: 0))
    }
}

@MainActor
final class ApplicationRelaunchTests: XCTestCase {
    func testConfirmedReplacementLaunchTerminatesCurrentApplication() async throws {
        let relauncher = RecordingApplicationRelauncher()
        var terminationCount = 0
        let client = SystemAudioCapturePermissionClient(
            relauncher: relauncher,
            terminateCurrentApplication: { terminationCount += 1 },
            bundleURL: URL(fileURLWithPath: "/Applications/Auralis.app")
        )

        try await client.relaunchApp()

        XCTAssertEqual(relauncher.launchedURLs, [URL(fileURLWithPath: "/Applications/Auralis.app")])
        XCTAssertEqual(terminationCount, 1)
    }

    func testFailedReplacementLaunchDoesNotTerminateCurrentApplication() async {
        let relauncher = RecordingApplicationRelauncher(error: RelaunchTestError.rejected)
        var terminationCount = 0
        let client = SystemAudioCapturePermissionClient(
            relauncher: relauncher,
            terminateCurrentApplication: { terminationCount += 1 },
            bundleURL: URL(fileURLWithPath: "/Applications/Auralis.app")
        )

        do {
            try await client.relaunchApp()
            XCTFail("Expected replacement launch to fail")
        } catch {
            XCTAssertEqual(error as? RelaunchTestError, .rejected)
        }

        XCTAssertEqual(relauncher.launchedURLs.count, 1)
        XCTAssertEqual(terminationCount, 0)
    }

    func testNonApplicationBundleDoesNotAttemptLaunchOrTerminate() async {
        let relauncher = RecordingApplicationRelauncher()
        var terminationCount = 0
        let client = SystemAudioCapturePermissionClient(
            relauncher: relauncher,
            terminateCurrentApplication: { terminationCount += 1 },
            bundleURL: URL(fileURLWithPath: "/tmp/Auralis")
        )

        do {
            try await client.relaunchApp()
            XCTFail("Expected a non-app launch path to be rejected")
        } catch {
            guard case ApplicationRelaunchError.notRunningFromApplicationBundle = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(relauncher.launchedURLs.isEmpty)
        XCTAssertEqual(terminationCount, 0)
    }
}

@MainActor
private final class RecordingApplicationRelauncher: ApplicationRelaunching {
    let error: Error?
    private(set) var launchedURLs: [URL] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func launchNewInstance(at bundleURL: URL) async throws {
        launchedURLs.append(bundleURL)
        if let error { throw error }
    }
}

private enum RelaunchTestError: Error, Equatable {
    case rejected
}
