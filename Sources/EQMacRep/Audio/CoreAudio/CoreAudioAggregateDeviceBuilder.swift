import CoreAudio
import Foundation

enum CoreAudioAggregateDeviceBuilder {
    static func singleOutputDescription(
        outputDeviceUID: String,
        tapUUID: UUID,
        appName: String
    ) -> [String: Any] {
        multiOutputDescription(
            outputDeviceUIDs: [outputDeviceUID],
            tapUUID: tapUUID,
            appName: appName
        )
    }

    static func multiOutputDescription(
        outputDeviceUIDs: [String],
        tapUUID: UUID,
        appName: String
    ) -> [String: Any] {
        precondition(!outputDeviceUIDs.isEmpty, "An aggregate device needs at least one output")
        let clockDeviceUID = outputDeviceUIDs[0]

        return [
            kAudioAggregateDeviceNameKey: "EQMacRep-\(appName)",
            kAudioAggregateDeviceUIDKey: "EQMacRep-\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            // Non-stacked aggregates ask HAL to feed the same output stream to
            // every subdevice instead of concatenating their channels.
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputDeviceUIDs.enumerated().map { index, uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    kAudioSubDeviceDriftCompensationKey: index != 0
                ] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: false
                ]
            ]
        ]
    }
}
