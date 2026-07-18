import AudioToolbox
import Darwin
import Foundation

/// Lock-free bridge from the real-time writer to non-real-time UI polling.
/// Render publishes at most once per callback; the consumer atomically drains
/// the maximum peak observed since its previous read.
final class CoreAudioPeakMeter {
    private var peakBits: Int32 = 0

    @inline(__always)
    func publish(_ peak: Float) {
        guard peak.isFinite, peak > 0 else { return }
        let peak = min(peak, 1)
        var expected = OSAtomicAdd32Barrier(0, &peakBits)
        while Float(bitPattern: UInt32(bitPattern: expected)) < peak {
            let desired = Int32(bitPattern: peak.bitPattern)
            if OSAtomicCompareAndSwap32Barrier(expected, desired, &peakBits) { return }
            expected = OSAtomicAdd32Barrier(0, &peakBits)
        }
    }

    func consume() -> Float {
        var bits: Int32
        repeat {
            bits = OSAtomicAdd32Barrier(0, &peakBits)
        } while !OSAtomicCompareAndSwap32Barrier(bits, 0, &peakBits)
        let value = Float(bitPattern: UInt32(bitPattern: bits))
        return value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Format-aware, queue-confined render engine. All heap storage is allocated in
/// `init`; `render` only performs pointer traversal, scalar DSP, `memset`, and a
/// single atomic peak publication.
final class CoreAudioPCMRenderer {
    static let realtimeHeapAllocationBudget = 0
    static let callbackBudgetMicroseconds = 2_000.0

    let inputFormat: CoreAudioPCMFormat
    let outputFormat: CoreAudioPCMFormat
    let maximumFrameCount: Int
    let peakMeter: CoreAudioPeakMeter

    private let inputScratch: UnsafeMutableBufferPointer<Float>
    private let gainScratch: UnsafeMutableBufferPointer<Float>
    private let eqProcessor: CoreAudioGraphicEQProcessor
    private var gainState: CoreAudioRealtimeGainState
    private var ramp: CoreAudioGainRamp

    init(
        inputFormat: CoreAudioPCMFormat,
        outputFormat: CoreAudioPCMFormat,
        maximumFrameCount: Int,
        initialGainState: CoreAudioRealtimeGainState,
        peakMeter: CoreAudioPeakMeter = CoreAudioPeakMeter()
    ) throws {
        try CoreAudioPCMFormat.validatePair(
            input: inputFormat,
            output: outputFormat,
            maximumFrameCount: maximumFrameCount
        )
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.maximumFrameCount = maximumFrameCount
        self.peakMeter = peakMeter
        gainState = initialGainState
        ramp = CoreAudioGainRamp(
            currentGain: initialGainState.targetGain,
            coefficient: CoreAudioGainRamp.coefficient(sampleRate: outputFormat.sampleRate)
        )
        inputScratch = .allocate(capacity: maximumFrameCount * inputFormat.channelCount)
        inputScratch.initialize(repeating: 0)
        gainScratch = .allocate(capacity: maximumFrameCount)
        gainScratch.initialize(repeating: initialGainState.targetGain)
        eqProcessor = CoreAudioGraphicEQProcessor(
            sampleRate: outputFormat.sampleRate,
            channelCount: outputFormat.channelCount,
            curve: initialGainState.eq
        )
    }

    deinit {
        inputScratch.deallocate()
        gainScratch.deallocate()
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {
        let eqChanged = gainState.eq != state.eq
        gainState = state
        if eqChanged { eqProcessor.updateCurve(state.eq) }
    }

    func updateSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite,
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate) else { return }
        eqProcessor.updateSampleRate(sampleRate)
        ramp.coefficient = CoreAudioGainRamp.coefficient(sampleRate: sampleRate)
    }

    @inline(__always)
    func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)

        let inputFrameCapacity = Self.frameCapacity(
            of: inputs,
            format: inputFormat
        )
        let outputFrameCapacity = Self.frameCapacity(
            of: outputs,
            format: outputFormat
        )
        let frameCount = min(
            maximumFrameCount,
            min(inputFrameCapacity, outputFrameCapacity)
        )

        // Copy before clearing output so an in-place/aliased CoreAudio buffer is
        // still handled correctly. Invalid layouts still receive full silence.
        if frameCount > 0 {
            copyInputToScratch(inputs, frameCount: frameCount)
        }
        Self.zeroAll(outputs)
        guard frameCount > 0 else { return }
        let eqSnapshot = eqProcessor.renderSnapshot()
        let targetGain = gainState.targetGain
        var localRamp = ramp
        var peak: Float = 0
        var globalOutputChannel = 0

        for frame in 0..<frameCount {
            gainScratch[frame] = localRamp.next(targetGain: targetGain)
        }

        for bufferIndex in 0..<outputs.count {
            let buffer = outputs[bufferIndex]
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount > 0,
                  let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            for frame in 0..<frameCount {
                let frameOffset = frame * bufferChannelCount
                for localChannel in 0..<bufferChannelCount {
                    let outputChannel = globalOutputChannel + localChannel
                    guard outputChannel < outputFormat.channelCount else { continue }
                    let inputChannel = outputChannel % inputFormat.channelCount
                    let input = inputScratch[frame * inputFormat.channelCount + inputChannel]
                    let equalized = eqProcessor.processSample(
                        input,
                        channel: outputChannel,
                        snapshot: eqSnapshot
                    )
                    let output = CoreAudioSoftLimiter.apply(equalized * gainScratch[frame])
                    samples[frameOffset + localChannel] = output
                    peak = max(peak, abs(output))
                }
            }
            globalOutputChannel += bufferChannelCount
        }

        ramp = localRamp
        peakMeter.publish(peak)
    }

    func consumePeakLevel() -> Float {
        peakMeter.consume()
    }

    var storageFingerprint: (
        inputScratch: UInt,
        gainScratch: UInt,
        coefficientsA: UInt,
        coefficientsB: UInt,
        delays: UInt
    ) {
        let eq = eqProcessor.storageFingerprint
        return (
            UInt(bitPattern: inputScratch.baseAddress!),
            UInt(bitPattern: gainScratch.baseAddress!),
            eq.coefficientsA,
            eq.coefficientsB,
            eq.delays
        )
    }

    @inline(__always)
    private func copyInputToScratch(
        _ inputs: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        var globalInputChannel = 0
        for bufferIndex in 0..<inputs.count {
            let buffer = inputs[bufferIndex]
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount > 0,
                  let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            for frame in 0..<frameCount {
                let frameOffset = frame * bufferChannelCount
                let scratchOffset = frame * inputFormat.channelCount + globalInputChannel
                for localChannel in 0..<bufferChannelCount {
                    inputScratch[scratchOffset + localChannel] = samples[frameOffset + localChannel]
                }
            }
            globalInputChannel += bufferChannelCount
        }
    }

    @inline(__always)
    private static func frameCapacity(
        of buffers: UnsafeMutableAudioBufferListPointer,
        format: CoreAudioPCMFormat
    ) -> Int {
        guard buffers.count == format.bufferChannelCounts.count else { return 0 }

        var capacity = Int.max
        var channelTotal = 0
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels == format.bufferChannelCounts[index],
                  buffer.mData != nil else { return 0 }
            channelTotal += channels
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            capacity = min(capacity, sampleCount / channels)
        }
        return channelTotal == format.channelCount && capacity != Int.max ? capacity : 0
    }

    @inline(__always)
    private static func zeroAll(_ outputs: UnsafeMutableAudioBufferListPointer) {
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
