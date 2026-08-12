import XCTest
@testable import Auralis

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
