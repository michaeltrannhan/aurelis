import AudioToolbox
import Foundation

enum CoreAudioPCMFormatError: Error, Equatable, LocalizedError, Sendable {
    case noStreams
    case notLinearPCM(AudioFormatID)
    case notNativePackedFloat32(AudioFormatFlags, bitsPerChannel: UInt32)
    case invalidSampleRate(Double)
    case invalidChannelCount(UInt32)
    case invalidTotalChannelCount(Int)
    case invalidPacketLayout(bytesPerFrame: UInt32, bytesPerPacket: UInt32, framesPerPacket: UInt32)
    case inconsistentStreamSampleRates([Double])
    case streamConfigurationMismatch(expected: [Int], actual: [Int])
    case invalidMaximumFrameCount(Int)

    var errorDescription: String? {
        switch self {
        case .noStreams:
            "The CoreAudio device has no enabled streams"
        case let .notLinearPCM(formatID):
            "Unsupported audio format ID \(formatID); Auralis requires linear PCM"
        case let .notNativePackedFloat32(flags, bits):
            "Unsupported PCM flags \(flags) / \(bits)-bit samples; Auralis requires native packed Float32"
        case let .invalidSampleRate(sampleRate):
            "Unsupported sample rate \(sampleRate) Hz"
        case let .invalidChannelCount(channelCount):
            "Unsupported stream channel count \(channelCount)"
        case let .invalidTotalChannelCount(channelCount):
            "Unsupported total channel count \(channelCount)"
        case let .invalidPacketLayout(bytesPerFrame, bytesPerPacket, framesPerPacket):
            "Unsupported PCM packet layout: \(bytesPerFrame) bytes/frame, \(bytesPerPacket) bytes/packet, \(framesPerPacket) frames/packet"
        case let .inconsistentStreamSampleRates(sampleRates):
            "CoreAudio streams disagree on sample rate: \(sampleRates)"
        case let .streamConfigurationMismatch(expected, actual):
            "Stream formats describe buffer channels \(expected), but CoreAudio configured \(actual)"
        case let .invalidMaximumFrameCount(frameCount):
            "Unsupported maximum audio frame count \(frameCount)"
        }
    }
}

/// Validated IOProc-side PCM layout. `bufferChannelCounts` mirrors the exact
/// `AudioBufferList` returned by `kAudioDevicePropertyStreamConfiguration`.
/// It therefore supports one interleaved stream, planar streams, and aggregate
/// devices that expose several interleaved buffers.
struct CoreAudioPCMFormat: Equatable, Sendable {
    static let maximumChannelCount = 64
    static let maximumFrameCount = 32_768
    static let minimumSampleRate = 8_000.0
    static let maximumSampleRate = 384_000.0

    let sampleRate: Double
    let channelCount: Int
    let bufferChannelCounts: [Int]

    var usesSingleInterleavedBuffer: Bool {
        bufferChannelCounts == [channelCount]
    }

    init(streamDescription: AudioStreamBasicDescription) throws {
        let stream = try Self.validate(streamDescription)
        sampleRate = stream.sampleRate
        channelCount = stream.channelCount
        bufferChannelCounts = stream.bufferChannelCounts
    }

    init(
        streamDescriptions: [AudioStreamBasicDescription],
        configuredBufferChannelCounts: [Int]
    ) throws {
        guard !streamDescriptions.isEmpty else {
            throw CoreAudioPCMFormatError.noStreams
        }
        let streams = try streamDescriptions.map(Self.validate)
        let sampleRates = streams.map(\.sampleRate)
        guard sampleRates.dropFirst().allSatisfy({ abs($0 - sampleRates[0]) < 0.001 }) else {
            throw CoreAudioPCMFormatError.inconsistentStreamSampleRates(sampleRates)
        }
        let expectedBuffers = streams.flatMap(\.bufferChannelCounts)
        let actualBuffers = configuredBufferChannelCounts
        guard expectedBuffers == actualBuffers else {
            throw CoreAudioPCMFormatError.streamConfigurationMismatch(
                expected: expectedBuffers,
                actual: actualBuffers
            )
        }
        let totalChannels = expectedBuffers.reduce(0, +)
        guard totalChannels > 0, totalChannels <= Self.maximumChannelCount else {
            throw CoreAudioPCMFormatError.invalidTotalChannelCount(totalChannels)
        }
        sampleRate = sampleRates[0]
        channelCount = totalChannels
        bufferChannelCounts = expectedBuffers
    }

    static func validatePair(
        input: CoreAudioPCMFormat,
        output: CoreAudioPCMFormat,
        maximumFrameCount: Int
    ) throws {
        // A process tap and the aggregate's physical clock can advertise
        // different nominal rates. The aggregate's enabled subtap drift
        // compensation aligns those streams for IOProc, so rejecting the
        // declared-rate difference prevents otherwise valid 44.1/48 kHz
        // routes from ever starting.
        _ = input
        _ = output
        guard maximumFrameCount > 0, maximumFrameCount <= Self.maximumFrameCount else {
            throw CoreAudioPCMFormatError.invalidMaximumFrameCount(maximumFrameCount)
        }
    }

    private struct ValidatedStream {
        let sampleRate: Double
        let channelCount: Int
        let bufferChannelCounts: [Int]
    }

    private static func validate(
        _ streamDescription: AudioStreamBasicDescription
    ) throws -> ValidatedStream {
        guard streamDescription.mFormatID == kAudioFormatLinearPCM else {
            throw CoreAudioPCMFormatError.notLinearPCM(streamDescription.mFormatID)
        }

        let flags = streamDescription.mFormatFlags
        let requiredFlags = AudioFormatFlags(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        let forbiddenFlags = AudioFormatFlags(
            kAudioFormatFlagIsBigEndian
                | kAudioFormatFlagIsAlignedHigh
                | kAudioFormatFlagIsSignedInteger
        )
        guard flags & requiredFlags == requiredFlags,
              flags & forbiddenFlags == 0,
              streamDescription.mBitsPerChannel == 32 else {
            throw CoreAudioPCMFormatError.notNativePackedFloat32(
                flags,
                bitsPerChannel: streamDescription.mBitsPerChannel
            )
        }

        let sampleRate = streamDescription.mSampleRate
        guard sampleRate.isFinite,
              (minimumSampleRate...maximumSampleRate).contains(sampleRate) else {
            throw CoreAudioPCMFormatError.invalidSampleRate(sampleRate)
        }

        let channels = streamDescription.mChannelsPerFrame
        guard channels > 0, channels <= maximumChannelCount else {
            throw CoreAudioPCMFormatError.invalidChannelCount(channels)
        }

        let isInterleaved = flags & AudioFormatFlags(kAudioFormatFlagIsNonInterleaved) == 0
        let expectedBytesPerFrame = UInt32(MemoryLayout<Float>.size) * (isInterleaved ? channels : 1)
        let framesPerPacket = streamDescription.mFramesPerPacket
        let expectedBytesPerPacket = expectedBytesPerFrame * framesPerPacket
        guard framesPerPacket == 1,
              streamDescription.mBytesPerFrame == expectedBytesPerFrame,
              streamDescription.mBytesPerPacket == expectedBytesPerPacket else {
            throw CoreAudioPCMFormatError.invalidPacketLayout(
                bytesPerFrame: streamDescription.mBytesPerFrame,
                bytesPerPacket: streamDescription.mBytesPerPacket,
                framesPerPacket: framesPerPacket
            )
        }

        return ValidatedStream(
            sampleRate: sampleRate,
            channelCount: Int(channels),
            bufferChannelCounts: isInterleaved
                ? [Int(channels)]
                : Array(repeating: 1, count: Int(channels))
        )
    }
}
