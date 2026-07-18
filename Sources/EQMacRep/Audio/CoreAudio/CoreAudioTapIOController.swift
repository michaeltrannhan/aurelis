import AudioToolbox
import CoreAudio
import Foundation

/// The active-tap engine seam the manager depends on. `CoreAudioTapIOController`
/// is the production implementation; tests inject a fake to verify route-driven
/// rebuild order without touching CoreAudio.
protocol CoreAudioActiveTapControlling: AnyObject {
    var outputDeviceUIDs: [String] { get }
    func start() throws -> CoreAudioTapSession
    func updateGainState(_ state: CoreAudioRealtimeGainState)
    func consumePeakLevel() -> Float
    func stop() throws
}

extension CoreAudioActiveTapControlling {
    func consumePeakLevel() -> Float { 0 }
}

final class SystemCoreAudioActiveTapOperations: CoreAudioActiveTapOperating {
    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStop(deviceID, ioProcID)
    }

    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        guard let ioProcID else { return noErr }
        return AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        guard #available(macOS 14.2, *) else {
            return kAudioHardwareUnsupportedOperationError
        }
        return AudioHardwareDestroyProcessTap(tapID)
    }
}

/// HAL can return from aggregate creation before its streams and buffer
/// configuration are published. Keep the same owned aggregate alive while it
/// settles instead of immediately destroying/recreating it into the same race.
enum CoreAudioAggregateReadiness {
    static let productionAttemptLimit = 21
    static let productionWaitInterval: TimeInterval = 0.01

    static func resolve<Value>(
        attemptLimit: Int,
        wait: () -> Void,
        operation: () throws -> Value
    ) throws -> Value {
        precondition(attemptLimit > 0)
        for attempt in 0..<attemptLimit {
            do {
                return try operation()
            } catch {
                guard attempt + 1 < attemptLimit else { throw error }
                wait()
            }
        }
        preconditionFailure("A positive aggregate-readiness attempt limit must execute")
    }
}

/// DSP state is confined to `queue` after `start()` publishes the controller;
/// lifecycle/resource mutation remains serialized by the manager's lifecycle
/// executor.
final class CoreAudioTapIOController {
    private struct OutputDeviceInfo {
        var uid: String
        var nominalSampleRate: Double
    }

    private let target: CoreAudioTapTarget
    let outputDeviceUIDs: [String]
    private let operations: CoreAudioActiveTapOperating
    private let ownershipJournal: any CoreAudioAggregateOwnershipJournaling
    private let queue = DispatchQueue(label: "EQMacRep.CoreAudioTapIOController", qos: .userInitiated)
    private var resources = CoreAudioTapResources(
        tapID: AudioObjectID(kAudioObjectUnknown),
        aggregateDeviceID: AudioObjectID(kAudioObjectUnknown),
        ioProcID: nil
    )

    private let initialGainState: CoreAudioRealtimeGainState
    private var renderer: CoreAudioPCMRenderer?
    private var nominalRateListener: AudioObjectPropertyListenerBlock?
    private var nominalRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)

    init(
        target: CoreAudioTapTarget,
        outputDeviceUIDs: [String],
        initialGainState: CoreAudioRealtimeGainState,
        operations: CoreAudioActiveTapOperating = SystemCoreAudioActiveTapOperations(),
        ownershipJournal: any CoreAudioAggregateOwnershipJournaling = CoreAudioAggregateOwnershipJournal.shared
    ) {
        precondition(!outputDeviceUIDs.isEmpty, "A tap controller needs at least one output")
        self.target = target
        self.outputDeviceUIDs = outputDeviceUIDs
        self.initialGainState = initialGainState
        self.operations = operations
        self.ownershipJournal = ownershipJournal
    }

    func start() throws -> CoreAudioTapSession {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
        }
        // Resolve every physical output before creating owned resources. HAL
        // reconciles differing physical rates inside the aggregate; the
        // aggregate's validated stream descriptions below define render I/O.
        _ = try outputDeviceUIDs.map(Self.outputDeviceInfo)

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs)
        tapDescription.name = "EQMacRep \(target.displayName)"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }
        resources.tapID = tapID

        let aggregateDescription = CoreAudioAggregateDeviceBuilder.multiOutputDescription(
            outputDeviceUIDs: outputDeviceUIDs,
            tapUUID: tapDescription.uuid,
            appName: target.displayName
        )
        let aggregateUID = CoreAudioAggregateDeviceBuilder.aggregateUID(tapUUID: tapDescription.uuid)

        // Persist intent before creation closes the crash window between HAL
        // creating the aggregate and the ownership write. The UID is the stable
        // ownership proof; the numeric object ID is updated after creation.
        do {
            try ownershipJournal.recordAggregate(
                uid: aggregateUID,
                deviceID: AudioObjectID(kAudioObjectUnknown)
            )
            resources.aggregateDeviceUID = aggregateUID
        } catch {
            try? stop()
            throw error
        }

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            try? stop()
            throw CoreAudioTapError.setupFailed(
                identity: target.identity,
                operation: "Aggregate device creation",
                status: status
            )
        }
        resources.aggregateDeviceID = aggregateID
        do {
            try ownershipJournal.recordAggregate(uid: aggregateUID, deviceID: aggregateID)
        } catch {
            try? stop()
            throw error
        }

        let activeSubdeviceIDs: [AudioObjectID] = (try? CoreAudioPropertyReader.array(
            objectID: aggregateID,
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )) ?? []
        let activeUIDs = activeSubdeviceIDs.compactMap { try? CoreAudioPropertyReader.string(
            objectID: $0,
            selector: kAudioDevicePropertyDeviceUID
        ) }
        let inactiveUIDs = Self.inactiveRequestedUIDs(
            requested: outputDeviceUIDs,
            active: activeUIDs
        )
        guard inactiveUIDs.isEmpty else {
            try? stop()
            throw CoreAudioTapStartFailure.inactiveOutputDevices(inactiveUIDs)
        }

        // Capture and validate both stream sides before an IO proc can ever
        // invoke render. Aggregate creation is asynchronous inside HAL, so
        // retry the property snapshot briefly while the new streams settle.
        let renderer: CoreAudioPCMRenderer
        do {
            renderer = try CoreAudioAggregateReadiness.resolve(
                attemptLimit: CoreAudioAggregateReadiness.productionAttemptLimit,
                wait: {
                    Thread.sleep(
                        forTimeInterval: CoreAudioAggregateReadiness.productionWaitInterval
                    )
                }
            ) {
                let inputDescriptions = try Self.streamDescriptions(
                    for: aggregateID,
                    scope: kAudioDevicePropertyScopeInput
                )
                let outputDescriptions = try Self.streamDescriptions(
                    for: aggregateID,
                    scope: kAudioDevicePropertyScopeOutput
                )
                let inputBufferChannels = try Self.streamConfiguration(
                    for: aggregateID,
                    scope: kAudioDevicePropertyScopeInput
                )
                let outputBufferChannels = try Self.streamConfiguration(
                    for: aggregateID,
                    scope: kAudioDevicePropertyScopeOutput
                )
                let maximumFrameCount = try Self.maximumFrameCount(for: aggregateID)
                return try CoreAudioPCMRenderer(
                    inputFormat: CoreAudioPCMFormat(
                        streamDescriptions: inputDescriptions,
                        configuredBufferChannelCounts: inputBufferChannels
                    ),
                    outputFormat: CoreAudioPCMFormat(
                        streamDescriptions: outputDescriptions,
                        configuredBufferChannelCounts: outputBufferChannels
                    ),
                    maximumFrameCount: maximumFrameCount,
                    initialGainState: initialGainState
                )
            }
        } catch let error as CoreAudioPCMFormatError {
            try? stop()
            throw CoreAudioTapStartFailure.fatal(error.localizedDescription)
        } catch {
            try? stop()
            throw error
        }
        self.renderer = renderer
        installNominalRateListener(for: aggregateID, renderer: renderer)

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inputData, _, outputData, _ in
            renderer.render(inputData: inputData, outputData: outputData)
        }
        guard status == noErr else {
            try? stop()
            throw CoreAudioTapError.setupFailed(
                identity: target.identity,
                operation: "IOProc creation",
                status: status
            )
        }
        resources.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            try? stop()
            throw CoreAudioTapError.setupFailed(
                identity: target.identity,
                operation: "Aggregate device start",
                status: status
            )
        }

        return CoreAudioTapSession(
            identity: target.identity,
            tapObjectID: tapID,
            processObjectIDs: target.processObjectIDs
        )
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {
        // AudioDevice IO blocks run synchronously on `queue`; enqueue control
        // updates there as well so the mutable gain/EQ state has one executor.
        guard let renderer else { return }
        queue.async(execute: DispatchWorkItem {
            renderer.updateGainState(state)
        })
    }

    func stop() throws {
        let listenerFailure = removeNominalRateListener()
        var failures: [CoreAudioTapResourceFailure] = []
        var deferredError: Error?
        do {
            try resources.destroy(using: operations, ownershipJournal: ownershipJournal)
        } catch let error as CoreAudioTapResourceTeardownError {
            failures.append(contentsOf: error.failures)
        } catch {
            deferredError = error
        }

        if resources.aggregateDeviceID == AudioObjectID(kAudioObjectUnknown) {
            // Destroying the owning aggregate also invalidates its listeners.
            nominalRateListener = nil
            nominalRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
        } else if let listenerFailure {
            failures.insert(listenerFailure, at: 0)
        }

        if !failures.isEmpty {
            throw CoreAudioTapResourceTeardownError(failures: failures)
        }
        if let deferredError {
            throw deferredError
        }
        renderer = nil
    }

    func consumePeakLevel() -> Float {
        renderer?.consumePeakLevel() ?? 0
    }

    private static func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private static func streamDescriptions(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioStreamBasicDescription] {
        let streamIDs: [AudioObjectID]
        do {
            streamIDs = try CoreAudioPropertyReader.array(
                objectID: deviceID,
                selector: kAudioDevicePropertyStreams,
                scope: scope
            )
        } catch let CoreAudioDiscoveryError.propertyReadFailed(_, _, status) {
            throw CoreAudioTapStartFailure.osStatus(
                status,
                operation: scope == kAudioDevicePropertyScopeInput
                    ? "Input stream-list read"
                    : "Output stream-list read"
            )
        } catch {
            throw error
        }
        guard !streamIDs.isEmpty else {
            throw CoreAudioTapStartFailure.fatal(
                scope == kAudioDevicePropertyScopeInput
                    ? "Aggregate device has no input streams"
                    : "Aggregate device has no output streams"
            )
        }

        return try streamIDs.map { streamID in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyVirtualFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(
                streamID,
                &address,
                0,
                nil,
                &size,
                &description
            )
            guard status == noErr else {
                throw CoreAudioTapStartFailure.osStatus(
                    status,
                    operation: scope == kAudioDevicePropertyScopeInput
                        ? "Input virtual stream-format read"
                        : "Output virtual stream-format read"
                )
            }
            return description
        }
    }

    private static func streamConfiguration(
        for deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else {
            throw CoreAudioTapStartFailure.osStatus(status, operation: "Stream-configuration size read")
        }
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            throw CoreAudioTapStartFailure.fatal("CoreAudio returned an invalid stream configuration")
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        )
        guard status == noErr else {
            throw CoreAudioTapStartFailure.osStatus(status, operation: "Stream-configuration read")
        }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        let bufferCount = Int(list.pointee.mNumberBuffers)
        let requiredSize = MemoryLayout<AudioBufferList>.size
            + max(bufferCount - 1, 0) * MemoryLayout<AudioBuffer>.stride
        guard bufferCount > 0, requiredSize <= Int(size) else {
            throw CoreAudioTapStartFailure.fatal("CoreAudio returned a truncated stream configuration")
        }
        return UnsafeMutableAudioBufferListPointer(list).map { Int($0.mNumberChannels) }
    }

    private static func maximumFrameCount(for deviceID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frameCount: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &frameCount
        )
        guard status == noErr else {
            throw CoreAudioTapStartFailure.osStatus(
                status,
                operation: "Buffer frame-size read"
            )
        }
        return Int(frameCount)
    }

    private func installNominalRateListener(
        for deviceID: AudioObjectID,
        renderer: CoreAudioPCMRenderer
    ) {
        var address = Self.nominalRateAddress
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            guard let sampleRate = Self.nominalSampleRate(for: deviceID) else { return }
            // The listener is delivered on the same serial queue as render.
            renderer.updateSampleRate(sampleRate)
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)
        guard status == noErr else { return }
        nominalRateListener = listener
        nominalRateListenerDeviceID = deviceID
    }

    private func removeNominalRateListener() -> CoreAudioTapResourceFailure? {
        guard let nominalRateListener,
              nominalRateListenerDeviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = Self.nominalRateAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            nominalRateListenerDeviceID,
            &address,
            queue,
            nominalRateListener
        )
        guard status == noErr else {
            return CoreAudioTapResourceFailure(
                operation: .removeNominalRateListener,
                objectID: nominalRateListenerDeviceID,
                status: status
            )
        }
        self.nominalRateListener = nil
        nominalRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
        return nil
    }

    private static var nominalRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func inactiveRequestedUIDs(requested: [String], active: [String]) -> [String] {
        let activeSet = Set(active.compactMap(Self.normalizedUID))
        var seen = Set<String>()
        return requested.compactMap { rawUID in
            guard let uid = normalizedUID(rawUID), seen.insert(uid).inserted else { return nil }
            return activeSet.contains(uid) ? nil : uid
        }
    }

    private static func normalizedUID(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func outputDeviceInfo(for uid: String) throws -> OutputDeviceInfo {
        let objectID = try deviceObjectID(forUID: uid)
        guard let nominalSampleRate = nominalSampleRate(for: objectID) else {
            throw CoreAudioTapStartFailure.deviceUnavailable
        }
        return OutputDeviceInfo(uid: uid, nominalSampleRate: nominalSampleRate)
    }

    private static func deviceObjectID(forUID uid: String) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = uid as CFString
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                qualifierPointer,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioTapStartFailure.deviceUnavailable
        }
        return objectID
    }
}

extension CoreAudioTapIOController: CoreAudioActiveTapControlling {}
