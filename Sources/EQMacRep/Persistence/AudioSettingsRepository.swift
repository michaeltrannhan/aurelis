import Foundation

struct SettingsPersistenceDiagnostics: Equatable, Sendable {
    let hasDirtyState: Bool
    let attemptedWriteCount: Int
    let successfulWriteCount: Int
    let retryAttemptCount: Int
    let lastErrorDescription: String?
}

/// Sole owner of settings-file I/O and dirty-state retries. Callers submit
/// immutable snapshots; identical snapshots never reach the filesystem.
actor SettingsPersistenceActor {
    private struct PendingSave: Sendable {
        let revision: UInt64
        let settings: PersistedSettings
    }

    let store: SettingsStore
    private let retryDelaysNanoseconds: [UInt64]
    private var lastPersisted: PersistedSettings?
    private var pendingSave: PendingSave?
    private var nextRevision: UInt64 = 0
    private var saveTask: Task<Void, Never>?
    private var writeBlockError: SettingsStoreError?
    private var lastSaveError: Error?
    private var retryAttemptCount = 0
    private var attemptedWriteCount = 0
    private var successfulWriteCount = 0

    init(
        store: SettingsStore,
        retryDelaysNanoseconds: [UInt64] = [250_000_000, 1_000_000_000, 4_000_000_000]
    ) {
        self.store = store
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
    }

    func loadWithRecovery() throws -> SettingsLoadResult {
        let result = try store.loadWithRecovery()
        lastPersisted = result.settings
        pendingSave = nil
        lastSaveError = nil
        return result
    }

    func blockWrites(because error: SettingsStoreError) {
        writeBlockError = error
        saveTask?.cancel()
        saveTask = nil
    }

    /// Durably commits a changed snapshot. Returns `false` when the canonical
    /// settings are already on disk.
    @discardableResult
    func commit(_ settings: PersistedSettings) throws -> Bool {
        if settings == lastPersisted, pendingSave == nil { return false }
        let pending = replacePending(with: settings)
        retryAttemptCount = 0
        saveTask?.cancel()
        saveTask = nil
        do {
            try requireWritesAllowed()
            try save(pending)
            return true
        } catch {
            // A failed durable write makes the on-disk state uncertain. Even
            // when the compensated snapshot equals the last value we loaded,
            // force its retry instead of assuming the old file survived.
            lastPersisted = nil
            lastSaveError = error
            scheduleNextRetry(for: pending)
            throw error
        }
    }

    /// Marks the newest state dirty without making the caller wait for disk.
    /// Used for edit previews and for the compensated baseline after a failed
    /// durable commit.
    func schedule(
        _ settings: PersistedSettings,
        debounceNanoseconds: UInt64 = 200_000_000
    ) {
        if settings == lastPersisted {
            pendingSave = nil
            saveTask?.cancel()
            saveTask = nil
            retryAttemptCount = 0
            return
        }
        let pending = replacePending(with: settings)
        retryAttemptCount = 0
        saveTask?.cancel()
        guard writeBlockError == nil else { return }
        scheduleAttempt(for: pending, afterNanoseconds: debounceNanoseconds)
    }

    func flush() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let pendingSave else { return }
        do {
            try requireWritesAllowed()
            try save(pendingSave)
        } catch {
            lastPersisted = nil
            lastSaveError = error
            scheduleNextRetry(for: pendingSave)
            throw error
        }
    }

    func cancelScheduledRetry() {
        saveTask?.cancel()
        saveTask = nil
    }

    func diagnostics() -> SettingsPersistenceDiagnostics {
        SettingsPersistenceDiagnostics(
            hasDirtyState: pendingSave != nil,
            attemptedWriteCount: attemptedWriteCount,
            successfulWriteCount: successfulWriteCount,
            retryAttemptCount: retryAttemptCount,
            lastErrorDescription: lastSaveError?.localizedDescription
        )
    }

    /// Waits for the currently scheduled debounce/retry chain to finish.
    /// Tests and orderly shutdown paths can observe completion directly
    /// instead of guessing with a wall-clock sleep.
    func waitForScheduledWork() async {
        while let task = saveTask {
            await task.value
        }
    }

    private func replacePending(with settings: PersistedSettings) -> PendingSave {
        nextRevision &+= 1
        let pending = PendingSave(revision: nextRevision, settings: settings)
        pendingSave = pending
        return pending
    }

    private func requireWritesAllowed() throws {
        if let writeBlockError { throw writeBlockError }
    }

    private func save(_ pending: PendingSave) throws {
        attemptedWriteCount += 1
        try store.save(pending.settings)
        successfulWriteCount += 1
        finishSuccessfulSave(revision: pending.revision, settings: pending.settings)
    }

    private func scheduleAttempt(for pending: PendingSave, afterNanoseconds delay: UInt64) {
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.performScheduledSave(expectedRevision: pending.revision)
        }
    }

    private func performScheduledSave(expectedRevision: UInt64) {
        guard writeBlockError == nil,
              let pending = pendingSave,
              pending.revision == expectedRevision else { return }
        do {
            try save(pending)
        } catch {
            lastPersisted = nil
            lastSaveError = error
            scheduleNextRetry(for: pending)
        }
    }

    private func scheduleNextRetry(for pending: PendingSave) {
        guard writeBlockError == nil,
              pendingSave?.revision == pending.revision,
              retryAttemptCount < retryDelaysNanoseconds.count else {
            saveTask = nil
            return
        }
        let delay = retryDelaysNanoseconds[retryAttemptCount]
        retryAttemptCount += 1
        scheduleAttempt(for: pending, afterNanoseconds: delay)
    }

    private func finishSuccessfulSave(revision: UInt64, settings: PersistedSettings) {
        lastPersisted = settings
        guard pendingSave?.revision == revision else { return }
        pendingSave = nil
        saveTask = nil
        retryAttemptCount = 0
        lastSaveError = nil
    }
}
