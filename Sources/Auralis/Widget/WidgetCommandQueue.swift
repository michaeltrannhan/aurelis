import Darwin
import AuralisWidgetShared
import Foundation

struct WidgetCommandClaim: Equatable, Sendable {
    let commandID: UUID
    let fileURL: URL
}

/// Per-command directory transport shared by the widget extension and host.
/// Writers publish one UUID file with an exclusive atomic rename. The host
/// claims work with another exclusive rename, publishes a durable result, and
/// only then removes the claimed file.
enum WidgetCommandQueue {
    @discardableResult
    static func enqueue(_ command: WidgetCommand) throws -> Bool {
        try enqueue(command, layout: WidgetSharedContainer.resolveLayout())
    }

    @discardableResult
    static func enqueue(_ command: WidgetCommand, layout: WidgetSharedLayout) throws -> Bool {
        try command.validate()
        try WidgetSharedContainer.prepare(layout)

        let destinations = [
            layout.pendingCommandURL(for: command.id),
            layout.claimedCommandURL(for: command.id),
            layout.resultURL(for: command.id)
        ]
        guard !destinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return false
        }

        // A v6 command receives its sequence while holding an advisory POSIX
        // lock shared by the extension and host. The file is the monotonic
        // source of truth across separate widget processes.
        let publishedCommand: WidgetCommand
        if command.schemaVersion == WidgetCommand.currentSchemaVersion, command.sequence == 0 {
            publishedCommand = command.assigning(sequence: try nextSequence(layout: layout))
        } else {
            publishedCommand = command
        }

        let data: Data
        do {
            data = try WidgetWireCodec.makeEncoder().encode(publishedCommand)
        } catch {
            throw WidgetIPCError.cannotEncode("command", error)
        }

        let stagingURL = layout.stagingURL
            .appendingPathComponent("\(command.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp")
        do {
            try data.write(to: stagingURL)
        } catch {
            throw WidgetIPCError.cannotWrite(stagingURL, error)
        }

        do {
            let published = try atomicRenameExclusive(
                from: stagingURL,
                to: layout.pendingCommandURL(for: command.id)
            )
            if !published { try? FileManager.default.removeItem(at: stagingURL) }
            return published
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Returns both crash-recovered claims and newly claimed pending files.
    /// Every returned URL remains in `claimed` until `complete` is called.
    static func claimAvailable(layout: WidgetSharedLayout) throws -> [WidgetCommandClaim] {
        try WidgetSharedContainer.prepare(layout)
        let fileManager = FileManager.default
        var claimsByID: [UUID: WidgetCommandClaim] = [:]

        for url in try jsonFiles(in: layout.claimedURL) {
            guard let id = WidgetSharedLayout.commandID(from: url) else {
                quarantineInvalidFile(url, layout: layout)
                continue
            }
            if fileManager.fileExists(atPath: layout.resultURL(for: id).path) {
                try? fileManager.removeItem(at: url)
            } else {
                claimsByID[id] = WidgetCommandClaim(commandID: id, fileURL: url)
            }
        }

        for pendingURL in try jsonFiles(in: layout.pendingURL) {
            guard let id = WidgetSharedLayout.commandID(from: pendingURL) else {
                quarantineInvalidFile(pendingURL, layout: layout)
                continue
            }
            let resultURL = layout.resultURL(for: id)
            if fileManager.fileExists(atPath: resultURL.path) {
                try? fileManager.removeItem(at: pendingURL)
                continue
            }
            if claimsByID[id] != nil || fileManager.fileExists(atPath: layout.claimedCommandURL(for: id).path) {
                // A duplicate publication with the same command identity cannot
                // add work. Retain the already-claimed copy.
                try? fileManager.removeItem(at: pendingURL)
                continue
            }

            let claimedURL = layout.claimedCommandURL(for: id)
            if try atomicRenameExclusive(from: pendingURL, to: claimedURL) {
                claimsByID[id] = WidgetCommandClaim(commandID: id, fileURL: claimedURL)
            }
        }

        return claimsByID.values.sorted { lhs, rhs in
            lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent
        }
    }

    static func readCommand(_ claim: WidgetCommandClaim) throws -> WidgetCommand {
        let data: Data
        do {
            data = try Data(contentsOf: claim.fileURL)
        } catch {
            throw WidgetIPCError.cannotRead(claim.fileURL, error)
        }
        let command = try WidgetWireCodec.makeDecoder().decode(WidgetCommand.self, from: data)
        guard command.id == claim.commandID else {
            throw WidgetIPCError.invalidCommandFile(claim.fileURL.lastPathComponent)
        }
        return command
    }

    /// Publishes an acknowledgment without replacing an existing one. The
    /// first result for a command ID is authoritative across duplicate drains.
    static func publish(
        _ result: WidgetCommandResult,
        for claim: WidgetCommandClaim,
        layout: WidgetSharedLayout
    ) throws {
        guard result.commandID == claim.commandID else {
            throw WidgetIPCError.invalidCommandFile(claim.fileURL.lastPathComponent)
        }
        try WidgetSharedContainer.prepare(layout)
        let resultURL = layout.resultURL(for: result.commandID)
        if FileManager.default.fileExists(atPath: resultURL.path) { return }

        let data: Data
        do {
            data = try WidgetWireCodec.makeEncoder().encode(result)
        } catch {
            throw WidgetIPCError.cannotEncode("command result", error)
        }
        let stagingURL = layout.stagingURL
            .appendingPathComponent("result-\(result.commandID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp")
        do {
            try data.write(to: stagingURL)
            if try !atomicRenameExclusive(from: stagingURL, to: resultURL) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw WidgetIPCError.cannotWrite(resultURL, error)
        }
    }

    static func complete(_ claim: WidgetCommandClaim) throws {
        do {
            try FileManager.default.removeItem(at: claim.fileURL)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            throw WidgetIPCError.cannotWrite(claim.fileURL, error)
        }
    }

    static func result(for commandID: UUID) -> WidgetCommandResult? {
        guard let layout = try? WidgetSharedContainer.resolveLayout() else { return nil }
        return result(for: commandID, layout: layout)
    }

    static func result(for commandID: UUID, layout: WidgetSharedLayout) -> WidgetCommandResult? {
        guard let data = try? Data(contentsOf: layout.resultURL(for: commandID)) else { return nil }
        return try? WidgetWireCodec.makeDecoder().decode(WidgetCommandResult.self, from: data)
    }

    static func pendingCommandIDs() -> Set<UUID> {
        guard let layout = try? WidgetSharedContainer.resolveLayout() else { return [] }
        return pendingCommandIDs(layout: layout)
    }

    static func pendingCommandIDs(layout: WidgetSharedLayout) -> Set<UUID> {
        let resultIDs = Set((try? jsonFiles(in: layout.resultsURL))?.compactMap(WidgetSharedLayout.commandID(from:)) ?? [])
        let workURLs = ((try? jsonFiles(in: layout.pendingURL)) ?? [])
            + ((try? jsonFiles(in: layout.claimedURL)) ?? [])
        return Set(workURLs.compactMap(WidgetSharedLayout.commandID(from:))).subtracting(resultIDs)
    }

    static func removeResults(olderThan cutoff: Date, layout: WidgetSharedLayout) {
        guard let files = try? jsonFiles(in: layout.resultsURL) else { return }
        let decoder = WidgetWireCodec.makeDecoder()
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let result = try? decoder.decode(WidgetCommandResult.self, from: data),
                  result.completedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func resolvedCommand(for claim: WidgetCommandClaim, layout: WidgetSharedLayout) -> WidgetCommand? {
        guard let data = try? Data(contentsOf: layout.resolutionURL(for: claim.commandID)) else { return nil }
        guard let resolution = try? WidgetWireCodec.makeDecoder().decode(WidgetCommandResolution.self, from: data),
              resolution.commandID == claim.commandID else { return nil }
        return resolution.command
    }

    static func persistResolution(
        _ command: WidgetCommand,
        for claim: WidgetCommandClaim,
        layout: WidgetSharedLayout
    ) throws {
        guard command.id == claim.commandID, !command.requiresAbsoluteResolution else {
            throw WidgetIPCError.invalidCommandFile(claim.fileURL.lastPathComponent)
        }
        let destination = layout.resolutionURL(for: claim.commandID)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let resolution = WidgetCommandResolution(commandID: claim.commandID, command: command)
        let data: Data
        do {
            data = try WidgetWireCodec.makeEncoder().encode(resolution)
        } catch {
            throw WidgetIPCError.cannotEncode("command resolution", error)
        }
        let stagingURL = layout.stagingURL.appendingPathComponent(
            "resolution-\(claim.commandID.uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp"
        )
        do {
            try data.write(to: stagingURL)
            if try !atomicRenameExclusive(from: stagingURL, to: destination) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw WidgetIPCError.cannotWrite(destination, error)
        }
    }

    private static func jsonFiles(in directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return []
        } catch {
            throw WidgetIPCError.cannotRead(directory, error)
        }
    }

    private static func quarantineInvalidFile(_ url: URL, layout: WidgetSharedLayout) {
        let quarantineURL = layout.stagingURL.appendingPathComponent(
            "rejected-\(UUID().uuidString.lowercased())-\(url.lastPathComponent)"
        )
        try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    private static func nextSequence(layout: WidgetSharedLayout) throws -> UInt64 {
        let descriptor = Darwin.open(layout.sequenceURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        let existingData = try Data(contentsOf: layout.sequenceURL)
        let existing = UInt64(String(decoding: existingData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard existing < UInt64.max else { throw WidgetIPCError.cannotWrite(layout.sequenceURL, POSIXError(.EOVERFLOW)) }
        let next = existing + 1
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array("\(next)\n".utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == bytes.count, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return next
    }

    /// Darwin's exclusive rename gives publication and claiming one atomic
    /// winner without exposing partially-written files or replacing work.
    private static func atomicRenameExclusive(from source: URL, to destination: URL) throws -> Bool {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        if status == 0 { return true }
        if errno == EEXIST { return false }
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        throw POSIXError(code)
    }
}

private struct WidgetCommandResolution: Codable, Equatable, Sendable {
    let commandID: UUID
    let command: WidgetCommand
}
