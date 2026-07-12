import AudioToolbox
import CoreAudio
import Foundation

/// The active-tap engine seam the manager depends on. `CoreAudioTapIOController`
/// is the production implementation; tests inject a fake to verify route-driven
/// rebuild order without touching CoreAudio.
protocol CoreAudioActiveTapControlling: AnyObject {
    var outputDeviceUID: String { get }
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

final class CoreAudioTapIOController {
    private let target: CoreAudioTapTarget
    let outputDeviceUID: String
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

    init(
        target: CoreAudioTapTarget,
        outputDeviceUID: String,
        initialGainState: CoreAudioRealtimeGainState,
        operations: CoreAudioActiveTapOperating = SystemCoreAudioActiveTapOperations()
    ) {
        self.target = target
        self.outputDeviceUID = outputDeviceUID
        self.gainState = initialGainState
        self.ramp = CoreAudioGainRamp(currentGain: initialGainState.targetGain, coefficient: 0.0007)
        self.eqProcessor = CoreAudioGraphicEQProcessor(sampleRate: 48000, curve: initialGainState.eq)
        self.operations = operations
    }

    func start() throws -> CoreAudioTapSession {
        guard #available(macOS 14.2, *) else {
            throw CoreAudioTapError.unsupportedOS
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

        let aggregateDescription = CoreAudioAggregateDeviceBuilder.singleOutputDescription(
            outputDeviceUID: outputDeviceUID,
            tapUUID: tapDescription.uuid,
            appName: target.displayName
        )

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }
        resources.aggregateDeviceID = aggregateID
        CoreAudioAggregateCrashGuard.trackDevice(aggregateID)

        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inputData, _, outputData, _ in
            self?.render(inputData: inputData, outputData: outputData)
        }
        guard status == noErr else {
            stop()
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }
        resources.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            stop()
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }

        return CoreAudioTapSession(
            identity: target.identity,
            tapObjectID: tapID,
            processObjectIDs: target.processObjectIDs
        )
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {
        gainState = state
        eqProcessor.updateCurve(state.eq)
    }

    func stop() {
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
}

extension CoreAudioTapIOController: CoreAudioActiveTapControlling {}
