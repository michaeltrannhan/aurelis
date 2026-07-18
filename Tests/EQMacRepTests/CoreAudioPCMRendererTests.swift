import AudioToolbox
import XCTest
@testable import EQMacRep

final class CoreAudioPCMRendererTests: XCTestCase {
    func testFormatValidationAcceptsNativeFloat32Layouts() throws {
        let interleaved = try CoreAudioPCMFormat(streamDescription: Self.streamDescription(
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let planar = try CoreAudioPCMFormat(streamDescription: Self.streamDescription(
            sampleRate: 96_000,
            channels: 6,
            interleaved: false
        ))

        XCTAssertEqual(interleaved.sampleRate, 48_000)
        XCTAssertEqual(interleaved.channelCount, 2)
        XCTAssertTrue(interleaved.usesSingleInterleavedBuffer)
        XCTAssertEqual(planar.sampleRate, 96_000)
        XCTAssertEqual(planar.channelCount, 6)
        XCTAssertFalse(planar.usesSingleInterleavedBuffer)

        let aggregate = try CoreAudioPCMFormat(
            streamDescriptions: [
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true),
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
            ],
            configuredBufferChannelCounts: [2, 2]
        )
        XCTAssertEqual(aggregate.channelCount, 4)
        XCTAssertEqual(aggregate.bufferChannelCounts, [2, 2])
        XCTAssertFalse(aggregate.usesSingleInterleavedBuffer)
    }

    func testFormatValidationRejectsUnsupportedLayoutsBeforeRender() {
        var integerPCM = Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
        integerPCM.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        XCTAssertThrowsError(try CoreAudioPCMFormat(streamDescription: integerPCM)) {
            guard case CoreAudioPCMFormatError.notNativePackedFloat32 = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        var float64 = Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
        float64.mBitsPerChannel = 64
        float64.mBytesPerFrame = 16
        float64.mBytesPerPacket = 16
        XCTAssertThrowsError(try CoreAudioPCMFormat(streamDescription: float64))

        var invalidRate = Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
        invalidRate.mSampleRate = .nan
        XCTAssertThrowsError(try CoreAudioPCMFormat(streamDescription: invalidRate))

        XCTAssertThrowsError(try CoreAudioPCMFormat(
            streamDescriptions: [
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true),
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
            ],
            configuredBufferChannelCounts: [4]
        )) {
            guard case CoreAudioPCMFormatError.streamConfigurationMismatch = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testClockAlignedAggregateAcceptsDifferentDeclaredTapAndOutputRates() throws {
        let renderer = try Self.makeRenderer(
            sampleRate: 48_000,
            outputSampleRate: 44_100,
            maximumFrames: 4
        )
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 4)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: 4, repeating: 9)
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        input.write(samples, toBuffer: 0)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        XCTAssertEqual(output.samples(inBuffer: 0), samples)
    }

    func testInterleavedStereoEQKeepsSilentChannelIsolated() throws {
        var curve = EQCurve()
        curve.setGain(6, at: 5)
        let renderer = try Self.makeRenderer(
            inputChannels: 2,
            inputInterleaved: true,
            outputChannels: 2,
            outputInterleaved: true,
            maximumFrames: 16,
            curve: curve
        )
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 8)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: 8, repeating: 9)
        input.write([
            1, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0
        ], toBuffer: 0)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        let samples = output.samples(inBuffer: 0)
        XCTAssertNotEqual(samples[0], 1)
        XCTAssertTrue(stride(from: 1, to: samples.count, by: 2).allSatisfy { samples[$0] == 0 })
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
    }

    func testAliasedInPlaceBuffersAreCopiedBeforeOutputIsCleared() throws {
        let renderer = try Self.makeRenderer(maximumFrames: 4)
        let buffers = OwnedAudioBufferList(channelGroups: [2], frameCount: 4)
        let expected: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        buffers.write(expected, toBuffer: 0)

        renderer.render(
            inputData: UnsafePointer(buffers.pointer),
            outputData: buffers.pointer
        )

        XCTAssertEqual(buffers.samples(inBuffer: 0), expected)
    }

    func testNonInterleavedMultipleBuffersMapChannelsAndZeroRemainders() throws {
        let renderer = try Self.makeRenderer(
            inputChannels: 2,
            inputInterleaved: false,
            outputChannels: 4,
            outputInterleaved: false,
            maximumFrames: 8
        )
        let input = OwnedAudioBufferList(channelGroups: [1, 1], frameCount: 2)
        let output = OwnedAudioBufferList(channelGroups: [1, 1, 1, 1], frameCount: 4, repeating: 9)
        input.write([0.25, 0.5], toBuffer: 0)
        input.write([-0.25, -0.5], toBuffer: 1)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        XCTAssertEqual(output.samples(inBuffer: 0), [0.25, 0.5, 0, 0])
        XCTAssertEqual(output.samples(inBuffer: 1), [-0.25, -0.5, 0, 0])
        XCTAssertEqual(output.samples(inBuffer: 2), [0.25, 0.5, 0, 0])
        XCTAssertEqual(output.samples(inBuffer: 3), [-0.25, -0.5, 0, 0])
        XCTAssertEqual(renderer.consumePeakLevel(), 0.5, accuracy: 0.0001)
        XCTAssertEqual(renderer.consumePeakLevel(), 0)
    }

    func testAggregateWithMultipleInterleavedBuffersUsesActualChannelCounts() throws {
        let inputFormat = try CoreAudioPCMFormat(streamDescription: Self.streamDescription(
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let outputFormat = try CoreAudioPCMFormat(
            streamDescriptions: [
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true),
                Self.streamDescription(sampleRate: 48_000, channels: 2, interleaved: true)
            ],
            configuredBufferChannelCounts: [2, 2]
        )
        let renderer = try CoreAudioPCMRenderer(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            maximumFrameCount: 4,
            initialGainState: CoreAudioRealtimeGainState(
                volume: 1,
                boost: .x1,
                isMuted: false
            )
        )
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 2)
        let output = OwnedAudioBufferList(channelGroups: [2, 2], frameCount: 4, repeating: 9)
        input.write([0.1, -0.1, 0.2, -0.2], toBuffer: 0)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        XCTAssertEqual(output.samples(inBuffer: 0), [0.1, -0.1, 0.2, -0.2, 0, 0, 0, 0])
        XCTAssertEqual(output.samples(inBuffer: 1), [0.1, -0.1, 0.2, -0.2, 0, 0, 0, 0])
    }

    func testInvalidRuntimeBufferTopologyProducesOnlySilence() throws {
        let renderer = try Self.makeRenderer(
            inputChannels: 2,
            inputInterleaved: false,
            outputChannels: 2,
            outputInterleaved: false,
            maximumFrames: 4
        )
        // The formats require two planar buffers, but each ABL supplies one
        // two-channel buffer. Setup accepted the formats; callback validation
        // refuses the inconsistent runtime topology and zeros every output byte.
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 4, repeating: 0.5)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: 4, repeating: 9)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        XCTAssertTrue(output.samples(inBuffer: 0).allSatisfy { $0 == 0 })
    }

    func testKnownImpulseMatchesCenterBandFirstCoefficient() throws {
        var curve = EQCurve()
        curve.setGain(6, at: 5)
        let renderer = try Self.makeRenderer(maximumFrames: 8, curve: curve)
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 8)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: 8)
        input.write([0.1, 0] + Array(repeating: 0, count: 14), toBuffer: 0)

        renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

        let centerBand = CoreAudioBiquadMath.peakingEQCoefficients(
            frequency: 1_000,
            gainDB: 6,
            q: CoreAudioBiquadMath.graphicEQQ,
            sampleRate: 48_000
        )
        XCTAssertEqual(output.samples(inBuffer: 0)[0], Float(centerBand[0]) * 0.1, accuracy: 0.000_01)
    }

    func testCenterBandFrequencyResponseAtSupportedSampleRates() throws {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let frameCount = 8_192
            var curve = EQCurve()
            curve.setGain(6, at: 5)
            let renderer = try Self.makeRenderer(
                sampleRate: sampleRate,
                maximumFrames: frameCount,
                curve: curve
            )
            let input = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
            let output = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
            var samples = Array(repeating: Float(0), count: frameCount * 2)
            for frame in 0..<frameCount {
                let sample = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate) * 0.1)
                samples[frame * 2] = sample
                samples[frame * 2 + 1] = sample
            }
            input.write(samples, toBuffer: 0)

            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)

            let rendered = output.samples(inBuffer: 0)
            let inputRMS = Self.rms(samples, droppingFrames: 2_048, channels: 2)
            let outputRMS = Self.rms(rendered, droppingFrames: 2_048, channels: 2)
            XCTAssertGreaterThan(outputRMS / inputRMS, 1.8, "sample rate \(sampleRate)")
            XCTAssertLessThan(outputRMS / inputRMS, 2.15, "sample rate \(sampleRate)")
        }
    }

    func testSustainedExtremeProcessingStaysFiniteAndFlushesDenormals() throws {
        var curve = EQCurve()
        for index in 0..<EQCurve.bandCount {
            curve.setGain(index.isMultiple(of: 2) ? 12 : -12, at: index)
        }
        let frameCount = 256
        let renderer = try Self.makeRenderer(maximumFrames: frameCount, curve: curve)
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
        var signal = Array(repeating: Float(0), count: frameCount * 2)
        for index in signal.indices {
            signal[index] = index.isMultiple(of: 2) ? 0.9 : -0.9
        }
        input.write(signal, toBuffer: 0)

        for _ in 0..<400 {
            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)
            XCTAssertTrue(output.samples(inBuffer: 0).allSatisfy(\.isFinite))
        }

        input.write(Array(repeating: 0, count: signal.count), toBuffer: 0)
        for _ in 0..<400 {
            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)
        }
        XCTAssertTrue(output.samples(inBuffer: 0).allSatisfy {
            $0 == 0 || abs($0) >= Float.leastNormalMagnitude
        })
    }

    func testRenderStorageIsStableAndCallbackMeetsExplicitBudget() throws {
        let frameCount = 128
        var curve = EQCurve()
        curve.setGain(6, at: 5)
        let renderer = try Self.makeRenderer(maximumFrames: frameCount, curve: curve)
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount, repeating: 0.1)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
        let before = renderer.storageFingerprint

        for _ in 0..<100 {
            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)
        }
        let iterations = 2_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let microsecondsPerCallback = Double(elapsed) / Double(iterations) / 1_000
        let after = renderer.storageFingerprint

        XCTAssertEqual(CoreAudioPCMRenderer.realtimeHeapAllocationBudget, 0)
        XCTAssertEqual(before.inputScratch, after.inputScratch)
        XCTAssertEqual(before.gainScratch, after.gainScratch)
        XCTAssertEqual(before.coefficientsA, after.coefficientsA)
        XCTAssertEqual(before.coefficientsB, after.coefficientsB)
        XCTAssertEqual(before.delays, after.delays)
        if ProcessInfo.processInfo.environment["EQMACREP_INSTRUMENTED_TESTS"] != "1" {
            XCTAssertLessThan(
                microsecondsPerCallback,
                CoreAudioPCMRenderer.callbackBudgetMicroseconds,
                "Render averaged \(microsecondsPerCallback) µs per \(frameCount)-frame callback"
            )
        }
    }

    func testSustainedAudioCallbackStressBudget() throws {
        let frameCount = 128
        let iterations = max(
            Int(ProcessInfo.processInfo.environment["EQMACREP_STRESS_ITERATIONS"] ?? "") ?? 5_000,
            1
        )
        var curve = EQCurve()
        for band in 0..<EQCurve.bandCount {
            curve.setGain(band.isMultiple(of: 2) ? 12 : -12, at: band)
        }
        let renderer = try Self.makeRenderer(maximumFrames: frameCount, curve: curve)
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount, repeating: 0.2)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: frameCount)
        let before = renderer.storageFingerprint
        let start = DispatchTime.now().uptimeNanoseconds

        for iteration in 0..<iterations {
            if iteration.isMultiple(of: 257) {
                renderer.updateGainState(CoreAudioRealtimeGainState(
                    volume: Double((iteration % 100) + 1) / 100,
                    boost: BoostLevel.allCases[iteration % BoostLevel.allCases.count],
                    isMuted: false,
                    eq: curve
                ))
            }
            renderer.render(inputData: UnsafePointer(input.pointer), outputData: output.pointer)
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let microsecondsPerCallback = Double(elapsed) / Double(iterations) / 1_000
        let after = renderer.storageFingerprint
        XCTAssertEqual(after.inputScratch, before.inputScratch)
        XCTAssertEqual(after.gainScratch, before.gainScratch)
        XCTAssertEqual(after.coefficientsA, before.coefficientsA)
        XCTAssertEqual(after.coefficientsB, before.coefficientsB)
        XCTAssertEqual(after.delays, before.delays)
        XCTAssertTrue(output.samples(inBuffer: 0).allSatisfy(\.isFinite))
        if ProcessInfo.processInfo.environment["EQMACREP_INSTRUMENTED_TESTS"] != "1" {
            XCTAssertLessThan(
                microsecondsPerCallback,
                CoreAudioPCMRenderer.callbackBudgetMicroseconds,
                "Stress averaged \(microsecondsPerCallback) µs over \(iterations) callbacks"
            )
        }
    }

    func testNonRealtimeControlAndRenderOwnershipStressUsesOneExecutor() throws {
        let renderer = try Self.makeRenderer(maximumFrames: 64)
        let input = OwnedAudioBufferList(channelGroups: [2], frameCount: 64, repeating: 0.1)
        let output = OwnedAudioBufferList(channelGroups: [2], frameCount: 64)
        let owner = DispatchQueue(label: "EQMacRepTests.DSPOwner")
        let producers = DispatchQueue(
            label: "EQMacRepTests.DSPProducers",
            attributes: .concurrent
        )
        let group = DispatchGroup()

        for iteration in 0..<1_000 {
            group.enter()
            producers.async(execute: DispatchWorkItem {
                owner.sync(execute: DispatchWorkItem {
                    if iteration.isMultiple(of: 3) {
                        var curve = EQCurve()
                        curve.setGain(iteration.isMultiple(of: 2) ? 6 : -6, at: iteration % EQCurve.bandCount)
                        renderer.updateGainState(CoreAudioRealtimeGainState(
                            volume: 0.75,
                            boost: .x1,
                            isMuted: false,
                            eq: curve
                        ))
                    } else {
                        renderer.render(
                            inputData: UnsafePointer(input.pointer),
                            outputData: output.pointer
                        )
                    }
                })
                group.leave()
            })
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        owner.sync {}
        XCTAssertTrue(output.samples(inBuffer: 0).allSatisfy(\.isFinite))
    }

    private static func makeRenderer(
        sampleRate: Double = 48_000,
        outputSampleRate: Double? = nil,
        inputChannels: Int = 2,
        inputInterleaved: Bool = true,
        outputChannels: Int = 2,
        outputInterleaved: Bool = true,
        maximumFrames: Int,
        curve: EQCurve = EQCurve()
    ) throws -> CoreAudioPCMRenderer {
        let input = try CoreAudioPCMFormat(streamDescription: streamDescription(
            sampleRate: sampleRate,
            channels: inputChannels,
            interleaved: inputInterleaved
        ))
        let output = try CoreAudioPCMFormat(streamDescription: streamDescription(
            sampleRate: outputSampleRate ?? sampleRate,
            channels: outputChannels,
            interleaved: outputInterleaved
        ))
        return try CoreAudioPCMRenderer(
            inputFormat: input,
            outputFormat: output,
            maximumFrameCount: maximumFrames,
            initialGainState: CoreAudioRealtimeGainState(
                volume: 1,
                boost: .x1,
                isMuted: false,
                eq: curve
            )
        )
    }

    private static func streamDescription(
        sampleRate: Double,
        channels: Int,
        interleaved: Bool
    ) -> AudioStreamBasicDescription {
        var flags = AudioFormatFlags(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        if !interleaved { flags |= AudioFormatFlags(kAudioFormatFlagIsNonInterleaved) }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.stride * (interleaved ? channels : 1))
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func rms(
        _ samples: [Float],
        droppingFrames: Int,
        channels: Int
    ) -> Double {
        let start = droppingFrames * channels
        let tail = samples[start...]
        return sqrt(tail.reduce(0) { $0 + Double($1 * $1) } / Double(tail.count))
    }
}

private final class OwnedAudioBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let rawList: UnsafeMutableRawPointer
    private let frameCount: Int
    private let channelGroups: [Int]
    private var sampleStorage: [UnsafeMutablePointer<Float>] = []

    init(channelGroups: [Int], frameCount: Int, repeating value: Float = 0) {
        precondition(!channelGroups.isEmpty)
        precondition(channelGroups.allSatisfy { $0 > 0 })
        self.frameCount = frameCount
        self.channelGroups = channelGroups
        let byteCount = MemoryLayout<AudioBufferList>.size
            + (channelGroups.count - 1) * MemoryLayout<AudioBuffer>.stride
        rawList = .allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawList.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        pointer = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = UInt32(channelGroups.count)
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)

        for (index, channels) in channelGroups.enumerated() {
            let sampleCount = frameCount * channels
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            samples.initialize(repeating: value, count: sampleCount)
            sampleStorage.append(samples)
            buffers[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(sampleCount * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(samples)
            )
        }
    }

    deinit {
        for (index, samples) in sampleStorage.enumerated() {
            samples.deinitialize(count: frameCount * channelGroups[index])
            samples.deallocate()
        }
        rawList.deallocate()
    }

    func write(_ values: [Float], toBuffer index: Int) {
        let expectedCount = frameCount * channelGroups[index]
        precondition(values.count == expectedCount)
        for sampleIndex in values.indices {
            sampleStorage[index][sampleIndex] = values[sampleIndex]
        }
    }

    func samples(inBuffer index: Int) -> [Float] {
        let count = frameCount * channelGroups[index]
        return Array(UnsafeBufferPointer(start: sampleStorage[index], count: count))
    }
}
