import XCTest
@testable import Auralis

final class AudioBackendFactoryTests: XCTestCase {
    func testMockModeCreatesMockBackend() {
        let backend = AudioBackendFactory.makeBackend(mode: .mock)

        XCTAssertTrue(backend is MockAudioBackend)
    }

    @MainActor
    func testPersistedMockModeStillSupportsStoreRefresh() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralisFactoryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
        let settingsStore = SettingsStore(settingsURL: url)
        var settings = PersistedSettings()
        settings.customization.backendMode = .mock
        try settingsStore.save(settings)
        let backend = AudioBackendFactory.makeBackend(mode: try settingsStore.load().customization.backendMode)
        let store = try AudioControlStore(settingsStore: settingsStore, backend: backend)

        try await store.refresh()

        XCTAssertFalse(store.displayRows.isEmpty)
    }
}
