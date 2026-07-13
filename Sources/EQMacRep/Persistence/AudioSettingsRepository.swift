import Foundation

@MainActor
final class AudioSettingsRepository {
    let store: SettingsStore
    private var pendingSettings: PersistedSettings?
    private var saveTask: Task<Void, Never>?
    private(set) var lastSaveError: Error?

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    func load() throws -> PersistedSettings {
        try store.load()
    }

    func scheduleSave(_ settings: PersistedSettings, debounceNanoseconds: UInt64 = 200_000_000) {
        pendingSettings = settings
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            do { try self?.flush() }
            catch { self?.lastSaveError = error }
        }
    }

    func saveNow(_ settings: PersistedSettings) throws {
        pendingSettings = nil
        saveTask?.cancel()
        saveTask = nil
        try store.save(settings)
        lastSaveError = nil
    }

    func flush() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let pendingSettings else { return }
        do {
            try store.save(pendingSettings)
            self.pendingSettings = nil
            lastSaveError = nil
        } catch {
            lastSaveError = error
            throw error
        }
    }
}
