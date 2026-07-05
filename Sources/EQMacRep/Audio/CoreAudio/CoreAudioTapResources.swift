import CoreAudio
import Foundation

protocol CoreAudioActiveTapOperating: AnyObject {
    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
}

struct CoreAudioTapResources {
    var tapID: AudioObjectID
    var aggregateDeviceID: AudioObjectID
    var ioProcID: AudioDeviceIOProcID?

    mutating func destroy(using operations: CoreAudioActiveTapOperating) {
        let aggregate = aggregateDeviceID
        let tap = tapID
        let proc = ioProcID

        if aggregate != AudioObjectID(kAudioObjectUnknown), proc != nil {
            _ = operations.stopDevice(aggregate, ioProcID: proc)
            _ = operations.destroyIOProc(aggregate, ioProcID: proc)
        }
        ioProcID = nil

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            _ = operations.destroyAggregateDevice(aggregate)
        }
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

        if tap != AudioObjectID(kAudioObjectUnknown) {
            _ = operations.destroyProcessTap(tap)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
