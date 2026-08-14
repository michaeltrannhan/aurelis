import XCTest
@testable import Auralis

final class AudioBackendFactoryTests: XCTestCase {
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
        let store = AudioControlStore(settingsStore: settingsStore, backend: backend)

        try await store.refresh()

        XCTAssertTrue(backend is MockAudioBackend)
        XCTAssertFalse(store.displayRows.isEmpty)
    }
}
