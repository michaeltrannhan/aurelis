import CoreAudio
import Foundation

enum CoreAudioAggregateDeviceBuilder {
    static func singleOutputDescription(
        outputDeviceUID: String,
        tapUUID: UUID,
        appName: String
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "EQMacRep-\(appName)",
            kAudioAggregateDeviceUIDKey: "EQMacRep-\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: false
                ]
            ]
        ]
    }
}
