import Foundation

/// Maps each physical output UID to a contiguous channel range in a
/// non-stacked aggregate's concatenated output layout.
struct CoreAudioOutputChannelMap: Equatable, Sendable {
    struct Slice: Equatable, Sendable {
        let deviceUID: String
        let channelOffset: Int
        let channelCount: Int

        var channelRange: Range<Int> {
            channelOffset..<(channelOffset + channelCount)
        }
    }

    let slices: [Slice]

    var totalChannelCount: Int {
        slices.last.map { $0.channelOffset + $0.channelCount } ?? 0
    }

    static func build(
        outputDeviceUIDs: [String],
        aggregateOutputChannelCount: Int,
        channelCountForUID: (String) throws -> Int
    ) throws -> CoreAudioOutputChannelMap {
        precondition(!outputDeviceUIDs.isEmpty, "Channel map needs at least one output")
        var offset = 0
        var slices: [Slice] = []
        for uid in outputDeviceUIDs {
            let channelCount = try channelCountForUID(uid)
            guard channelCount > 0 else {
                throw CoreAudioTapStartFailure.fatal(
                    "An output has no addressable channels for EQ fan-out"
                )
            }
            slices.append(
                Slice(
                    deviceUID: uid,
                    channelOffset: offset,
                    channelCount: channelCount
                )
            )
            offset += channelCount
        }
        guard offset == aggregateOutputChannelCount else {
            throw CoreAudioTapStartFailure.fatal(
                "The selected outputs could not be mapped to the aggregate channel layout"
            )
        }
        return CoreAudioOutputChannelMap(slices: slices)
    }

    func sliceIndex(containingChannel channel: Int) -> Int? {
        slices.firstIndex { $0.channelRange.contains(channel) }
    }

    static func singleDevice(uid: String, channelCount: Int) -> CoreAudioOutputChannelMap {
        CoreAudioOutputChannelMap(
            slices: [
                Slice(
                    deviceUID: uid,
                    channelOffset: 0,
                    channelCount: max(channelCount, 0)
                )
            ]
        )
    }
}
