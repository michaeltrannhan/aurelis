import CoreAudio
import Foundation
import XCTest
@testable import Auralis

/// Live Core Audio HAL tests. They enumerate real output devices and audio
/// processes, then read (and optionally round-trip) hardware volume.
///
/// **Off by default** so CI stays green without audio hardware.
///
/// Enable discovery/read tests:
/// ```
/// AURALIS_HW_TESTS=1 swift test --filter CoreAudioHardwareTests
/// ```
///
/// Enable a restore-safe volume round-trip in addition to the reads:
/// ```
/// AURALIS_HW_TESTS=1 AURALIS_HW_MUTATION=1 swift test --filter CoreAudioHardwareTests
/// ```
///
/// These tests do not create process taps, aggregates, or change the default
/// output unless mutation is explicitly enabled.
final class CoreAudioHardwareTests: XCTestCase {
    func testDeviceDiscoveryReturnsNamedOutputsAndAConsistentDefault() throws {
        try skipUnlessHardwareTestsEnabled()

        let state = try CoreAudioDeviceDiscovery().discoverOutputDeviceState()

        XCTAssertFalse(state.devices.isEmpty, "Expected at least one Core Audio output device")
        XCTAssertEqual(Set(state.devices.map(\.id)).count, state.devices.count)
        for device in state.devices {
            XCTAssertFalse(device.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        let discoveredIDs = Set(state.devices.map(\.id))
        XCTAssertTrue(
            Set(state.defaultOutputDeviceUIDs).isSubset(of: discoveredIDs),
            "Default output UIDs \(state.defaultOutputDeviceUIDs) must be among discovered devices \(discoveredIDs)"
        )
        if let defaultUID = state.defaultOutputDeviceUIDs.first {
            XCTAssertTrue(discoveredIDs.contains(defaultUID))
            if let rate = state.nominalSampleRatesByUID[defaultUID] {
                XCTAssertGreaterThan(rate, 0)
                XCTAssertTrue(rate.isFinite)
            }
        }
    }

    func testProcessDiscoveryYieldsPersistableIdentitiesWithoutTheTestProcess() throws {
        try skipUnlessHardwareTestsEnabled()

        let targets = try CoreAudioProcessDiscovery().discoverTapTargets()
        let seen = Set(targets.map(\.identity))
        XCTAssertEqual(seen.count, targets.count)
        for target in targets {
            XCTAssertTrue(target.identity.isPersistable)
            XCTAssertFalse(target.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(target.processObjectIDs.isEmpty)
            XCTAssertEqual(target.processObjectIDs, target.processObjectIDs.sorted())
            XCTAssertNotEqual(target.identity.rawValue, "com.michaeltrannhan.Auralis")
        }
    }

    func testDefaultOutputVolumeReadIsFiniteAndOptionallyRoundTrips() throws {
        try skipUnlessHardwareTestsEnabled()

        let state = try CoreAudioDeviceDiscovery().discoverOutputDeviceState()
        let uid = try XCTUnwrap(
            state.defaultOutputDeviceUIDs.first ?? state.devices.first?.id,
            "No output device available to read"
        )
        let controller = CoreAudioOutputVolumeController()
        let original = try controller.readOutputVolume(forUID: uid)

        XCTAssertTrue(original.volume.isFinite)
        XCTAssertGreaterThanOrEqual(original.volume, 0)
        XCTAssertLessThanOrEqual(original.volume, 1)
        if original.capabilities.canReadVolume {
            XCTAssertTrue((0...1).contains(original.volume))
        }

        guard ProcessInfo.processInfo.environment["AURALIS_HW_MUTATION"] == "1" else { return }
        guard original.capabilities.canSetVolume else {
            throw XCTSkip("Default output \(uid) does not expose a settable volume")
        }

        let delta: Double = original.volume >= 0.5 ? -0.05 : 0.05
        let target = min(max(original.volume + delta, 0.05), 0.95)
        defer { try? controller.setOutputVolume(original.volume, forUID: uid) }

        try controller.setOutputVolume(target, forUID: uid)
        let readback = try controller.readOutputVolume(forUID: uid)
        XCTAssertEqual(readback.volume, target, accuracy: 0.08)
    }

    private func skipUnlessHardwareTestsEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AURALIS_HW_TESTS"] == "1",
            "Set AURALIS_HW_TESTS=1 to run live Core Audio HAL tests"
        )
    }
}
