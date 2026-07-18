import CoreAudio
import Foundation

protocol CoreAudioActiveTapOperating: AnyObject {
    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
}

enum CoreAudioTapResourceOperation: String, Equatable, Sendable {
    case removeNominalRateListener
    case stopDevice
    case destroyIOProc
    case destroyAggregate
    case destroyProcessTap
}

struct CoreAudioTapResourceFailure: Equatable, Sendable {
    let operation: CoreAudioTapResourceOperation
    let objectID: AudioObjectID
    let status: OSStatus
}

struct CoreAudioTapResourceTeardownError: Error, Equatable, LocalizedError, Sendable {
    let failures: [CoreAudioTapResourceFailure]

    var errorDescription: String? {
        failures.map {
            "\($0.operation.rawValue) \($0.objectID) failed with OSStatus \($0.status)"
        }.joined(separator: "; ")
    }
}

struct CoreAudioTapResources {
    var tapID: AudioObjectID
    var aggregateDeviceID: AudioObjectID
    var ioProcID: AudioDeviceIOProcID?
    var aggregateDeviceUID: String? = nil

    var ownsResources: Bool {
        tapID != AudioObjectID(kAudioObjectUnknown)
            || aggregateDeviceID != AudioObjectID(kAudioObjectUnknown)
            || ioProcID != nil
            || aggregateDeviceUID != nil
    }

    /// Attempts every independent cleanup step and clears a handle only after
    /// its destroy operation succeeds. An IO proc must be gone before its
    /// aggregate can be safely destroyed; the process tap is independent and is
    /// always attempted even when aggregate cleanup fails.
    mutating func destroy(
        using operations: CoreAudioActiveTapOperating,
        ownershipJournal: (any CoreAudioAggregateOwnershipJournaling)? = nil
    ) throws {
        var failures: [CoreAudioTapResourceFailure] = []
        var journalRemovalError: Error?

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            let stopStatus = operations.stopDevice(aggregateDeviceID, ioProcID: ioProcID)
            if stopStatus != noErr {
                failures.append(CoreAudioTapResourceFailure(
                    operation: .stopDevice,
                    objectID: aggregateDeviceID,
                    status: stopStatus
                ))
            }

            let destroyStatus = operations.destroyIOProc(aggregateDeviceID, ioProcID: ioProcID)
            if destroyStatus == noErr {
                self.ioProcID = nil
            } else {
                failures.append(CoreAudioTapResourceFailure(
                    operation: .destroyIOProc,
                    objectID: aggregateDeviceID,
                    status: destroyStatus
                ))
            }
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown), ioProcID == nil {
            let aggregate = aggregateDeviceID
            let aggregateUID = aggregateDeviceUID
            let status = operations.destroyAggregateDevice(aggregate)
            if status == noErr {
                aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
                // Keep the stable UID until its durable ownership record is
                // removed below. If that write fails, a later stop retries only
                // the journal cleanup—not destruction of an already-gone device.
                aggregateDeviceUID = aggregateUID
            } else {
                failures.append(CoreAudioTapResourceFailure(
                    operation: .destroyAggregate,
                    objectID: aggregate,
                    status: status
                ))
            }
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            let tap = tapID
            let status = operations.destroyProcessTap(tap)
            if status == noErr {
                tapID = AudioObjectID(kAudioObjectUnknown)
            } else {
                failures.append(CoreAudioTapResourceFailure(
                    operation: .destroyProcessTap,
                    objectID: tap,
                    status: status
                ))
            }
        }

        if aggregateDeviceID == AudioObjectID(kAudioObjectUnknown),
           let aggregateUID = aggregateDeviceUID {
            if let ownershipJournal {
                do {
                    try ownershipJournal.removeAggregate(uid: aggregateUID)
                    self.aggregateDeviceUID = nil
                } catch {
                    journalRemovalError = error
                }
            } else {
                self.aggregateDeviceUID = nil
            }
        }

        if !failures.isEmpty {
            throw CoreAudioTapResourceTeardownError(failures: failures)
        }
        if let journalRemovalError {
            throw journalRemovalError
        }
    }
}
