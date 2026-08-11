import CoreAudio
import Foundation

enum CoreAudioAggregateDeviceBuilder {
    static func aggregateUID(tapUUID: UUID) -> String {
        "\(CoreAudioOrphanedAggregateCleanup.aggregateUIDPrefix)\(tapUUID.uuidString)"
    }

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
        // Non-stacked aggregates concatenate physical channels. The renderer
        // explicitly fans the shared process signal into every device slice,
        // which makes a distinct Output EQ possible for each destination.

        return [
            kAudioAggregateDeviceNameKey: "Auralis-\(appName)",
            kAudioAggregateDeviceUIDKey: aggregateUID(tapUUID: tapUUID),
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceClockDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
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
                    // The physical output is the aggregate clock. A process
                    // tap can advertise a different source rate, so HAL must
                    // clock-align the subtap before its frames reach IOProc.
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
    }
}
