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
    func stop()
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

/// DSP state is confined to `queue` after `start()` publishes the controller;
/// lifecycle/resource mutation remains serialized by the main-actor manager.
final class CoreAudioTapIOController: @unchecked Sendable {
    private struct OutputDeviceInfo {
        var uid: String
        var nominalSampleRate: Double
    }

    private let target: CoreAudioTapTarget
    let outputDeviceUIDs: [String]
    private let operations: CoreAudioActiveTapOperating
    private let queue = DispatchQueue(label: "EQMacRep.CoreAudioTapIOController", qos: .userInitiated)
    private var resources = CoreAudioTapResources(
        tapID: AudioObjectID(kAudioObjectUnknown),
        aggregateDeviceID: AudioObjectID(kAudioObjectUnknown),
        ioProcID: nil
    )

    private var gainState: CoreAudioRealtimeGainState
    private var ramp: CoreAudioGainRamp
    private let eqProcessor: CoreAudioGraphicEQProcessor
    private var nominalRateListener: AudioObjectPropertyListenerBlock?
    private var nominalRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)

    init(
        target: CoreAudioTapTarget,
        outputDeviceUIDs: [String],
        initialGainState: CoreAudioRealtimeGainState,
        operations: CoreAudioActiveTapOperating = SystemCoreAudioActiveTapOperations()
    ) {
        precondition(!outputDeviceUIDs.isEmpty, "A tap controller needs at least one output")
        self.target = target
        self.outputDeviceUIDs = outputDeviceUIDs
        self.gainState = initialGainState
        self.ramp = CoreAudioGainRamp(currentGain: initialGainState.targetGain, coefficient: 0.0007)
        self.eqProcessor = CoreAudioGraphicEQProcessor(sampleRate: 48000, curve: initialGainState.eq)
        self.operations = operations
    }

    func start() throws -> CoreAudioTapSession {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
        }
        let outputDevices = try outputDeviceUIDs.map(Self.outputDeviceInfo)
        let physicalSampleRates = outputDevices.map(\.nominalSampleRate)
        guard let physicalSampleRate = Self.compatibleNominalSampleRate(physicalSampleRates) else {
            throw CoreAudioTapStartFailure.incompatibleSampleRates(physicalSampleRates)
        }

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

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CoreAudioTapError.setupFailed(
                identity: target.identity,
                operation: "Aggregate device creation",
                status: status
            )
        }
        resources.aggregateDeviceID = aggregateID
        CoreAudioAggregateCrashGuard.trackDevice(aggregateID)

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
            stop()
            throw CoreAudioTapStartFailure.inactiveOutputDevices(inactiveUIDs)
        }

        // Property inspection and coefficient replacement happen before the IO
        // proc exists, keeping all CoreAudio work out of the realtime callback.
        let sampleRate = Self.nominalSampleRate(for: aggregateID) ?? physicalSampleRate
        eqProcessor.updateSampleRate(sampleRate)
        ramp.coefficient = CoreAudioGainRamp.coefficient(sampleRate: sampleRate)
        installNominalRateListener(for: aggregateID)

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [self] _, inputData, _, outputData, _ in
            render(inputData: inputData, outputData: outputData)
        }
        guard status == noErr else {
            stop()
            throw CoreAudioTapError.setupFailed(
                identity: target.identity,
                operation: "IOProc creation",
                status: status
            )
        }
        resources.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
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
        queue.async { [self] in
            gainState = state
            eqProcessor.updateCurve(state.eq)
        }
    }

    func stop() {
        removeNominalRateListener()
        resources.destroy(using: operations)
    }

    private func render(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        guard let input = inputs.first,
              let output = outputs.first,
              let inputData = input.mData?.assumingMemoryBound(to: Float.self),
              let outputData = output.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return
        }

        let sampleCount = Int(min(input.mDataByteSize, output.mDataByteSize)) / MemoryLayout<Float>.size
        let frameCount = sampleCount / 2
        let eqInputData: UnsafePointer<Float>

        if frameCount > 0 {
            eqProcessor.process(input: inputData, output: outputData, frameCount: frameCount)
            eqInputData = UnsafePointer(outputData)
        } else {
            eqInputData = UnsafePointer(inputData)
        }

        var localRamp = ramp
        CoreAudioRealtimeGainProcessor.process(
            input: eqInputData,
            output: outputData,
            sampleCount: sampleCount,
            targetGain: gainState.targetGain,
            ramp: &localRamp
        )
        ramp = localRamp
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

    private func installNominalRateListener(for deviceID: AudioObjectID) {
        var address = Self.nominalRateAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  let sampleRate = Self.nominalSampleRate(for: deviceID) else { return }
            // The listener is delivered on the same serial queue as render.
            eqProcessor.updateSampleRate(sampleRate)
            ramp.coefficient = CoreAudioGainRamp.coefficient(sampleRate: sampleRate)
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)
        guard status == noErr else { return }
        nominalRateListener = listener
        nominalRateListenerDeviceID = deviceID
    }

    private func removeNominalRateListener() {
        guard let nominalRateListener,
              nominalRateListenerDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        var address = Self.nominalRateAddress
        AudioObjectRemovePropertyListenerBlock(
            nominalRateListenerDeviceID,
            &address,
            queue,
            nominalRateListener
        )
        self.nominalRateListener = nil
        nominalRateListenerDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private static var nominalRateAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func compatibleNominalSampleRate(_ sampleRates: [Double]) -> Double? {
        guard let first = sampleRates.first,
              first.isFinite,
              first > 0,
              sampleRates.allSatisfy({ $0.isFinite && $0 > 0 && abs($0 - first) < 0.5 }) else {
            return nil
        }
        return first
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
        guard status == noErr,
              objectID != AudioObjectID(kAudioObjectUnknown),
              let nominalSampleRate = nominalSampleRate(for: objectID) else {
            throw CoreAudioTapStartFailure.deviceUnavailable
        }
        return OutputDeviceInfo(uid: uid, nominalSampleRate: nominalSampleRate)
    }
}

extension CoreAudioTapIOController: CoreAudioActiveTapControlling {}
