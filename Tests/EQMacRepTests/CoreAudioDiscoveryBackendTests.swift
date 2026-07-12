import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioDiscoveryBackendTests: XCTestCase {
    func testStatusMessageIncludesTapFailures() {
        let daw = AudioAppIdentity(rawValue: "com.example.DAW")
        let manager = HealthReportingTapManager(health: CoreAudioTapHealth(
            activeAppCount: 1,
            failedAppMessages: [daw: "App cannot be tapped"],
            backendMessage: "CoreAudio active"
        ))
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )

        let message = backend.statusMessage(appCount: 2, deviceCount: 1)

        XCTAssertTrue(message.contains("1 active tap"))
        XCTAssertTrue(message.contains("1 issue"))
    }

    func testStatusMessageWithoutIssuesOmitsIssueCount() {
        let manager = HealthReportingTapManager(health: CoreAudioTapHealth(activeAppCount: 2))
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )

        let message = backend.statusMessage(appCount: 3, deviceCount: 2)

        XCTAssertTrue(message.contains("2 active taps"))
        XCTAssertFalse(message.contains("issue"))
    }
}

private final class HealthReportingTapManager: CoreAudioTapManaging, CoreAudioTapHealthReporting {
    let health: CoreAudioTapHealth
    var activeSessions: [CoreAudioTapSession] = []

    init(health: CoreAudioTapHealth) {
        self.health = health
    }

    func reconcile(targets: [CoreAudioTapTarget]) throws {}
    func tearDown(identity: AudioAppIdentity) throws {}
    func tearDownAll() throws {}
}
