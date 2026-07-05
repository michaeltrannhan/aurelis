import CoreAudio
import Foundation

struct CoreAudioTapTarget: Equatable {
    var identity: AudioAppIdentity
    var displayName: String
    var processObjectIDs: [AudioObjectID]
}

struct CoreAudioTapSession: Equatable {
    var identity: AudioAppIdentity
    var tapObjectID: AudioObjectID
    var processObjectIDs: [AudioObjectID]
}
