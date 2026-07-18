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

    func testDuplicateTapTargetsCoalesceProcessObjectsWithoutTrap() throws {
        let identity = AudioAppIdentity(rawValue: "com.example.Music")
        let manager = HealthReportingTapManager(health: CoreAudioTapHealth())
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )
        backend.replaceTapTargetsForTesting([
            CoreAudioTapTarget(identity: identity, displayName: "Music", processObjectIDs: [10, 11]),
            CoreAudioTapTarget(identity: identity, displayName: "Duplicate", processObjectIDs: [11, 12])
        ])

        try backend.synchronizeTaps(activeAppIDs: [identity], ignoredAppIDs: [])

        XCTAssertEqual(manager.reconciledTargets, [
            CoreAudioTapTarget(identity: identity, displayName: "Music", processObjectIDs: [10, 11, 12])
        ])
    }

    func testBackendExposesRealTapPeaksThroughLightweightLevelCapability() {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let manager = HealthReportingTapManager(
            health: CoreAudioTapHealth(),
            peakLevels: [music: 0.625]
        )
        let backend = CoreAudioDiscoveryBackend(
            processDiscovery: CoreAudioProcessDiscovery(),
            deviceDiscovery: CoreAudioDeviceDiscovery(),
            tapManager: manager
        )

        XCTAssertEqual(backend.consumeAppLevels(), [music: 0.625])
        XCTAssertEqual(manager.levelReadCount, 1)
    }
}

private final class HealthReportingTapManager: CoreAudioTapManaging, CoreAudioTapHealthReporting, CoreAudioTapLevelReporting {
    let health: CoreAudioTapHealth
    let peakLevels: [AudioAppIdentity: Double]
    var activeSessions: [CoreAudioTapSession] = []
    private(set) var reconciledTargets: [CoreAudioTapTarget] = []
    private(set) var levelReadCount = 0

    init(
        health: CoreAudioTapHealth,
        peakLevels: [AudioAppIdentity: Double] = [:]
    ) {
        self.health = health
        self.peakLevels = peakLevels
    }

    func reconcile(targets: [CoreAudioTapTarget]) throws { reconciledTargets = targets }
    func tearDown(identity: AudioAppIdentity) throws {}
    func tearDownAll() throws {}
    func consumePeakLevels() -> [AudioAppIdentity: Double] {
        levelReadCount += 1
        return peakLevels
    }
}
