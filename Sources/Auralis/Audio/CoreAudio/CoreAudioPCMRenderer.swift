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
///
/// Signal order: Process EQ → app gain ramp → per-slice Output EQ → limiter.
final class CoreAudioPCMRenderer {
    static let realtimeHeapAllocationBudget = 0
    /// At 48 kHz with 128-frame callbacks, 250 µs keeps one fully active tap
    /// below roughly ten percent of one core even in the unoptimized test build.
    static let callbackBudgetMicroseconds = 250.0

    let inputFormat: CoreAudioPCMFormat
    let outputFormat: CoreAudioPCMFormat
    let maximumFrameCount: Int
    let channelMap: CoreAudioOutputChannelMap
    let peakMeter: CoreAudioPeakMeter

    private let inputScratch: UnsafeMutableBufferPointer<Float>
    private let processScratch: UnsafeMutableBufferPointer<Float>
    private let gainScratch: UnsafeMutableBufferPointer<Float>
    private let outputSliceIndexByChannel: UnsafeMutableBufferPointer<Int32>
    private let outputSnapshotScratch: UnsafeMutableBufferPointer<CoreAudioBiquadRenderSnapshot>
    private let processEQProcessor: CoreAudioGraphicEQProcessor
    private let outputEQProcessors: [CoreAudioGraphicEQProcessor]
    private var gainState: CoreAudioRealtimeGainState
    private var ramp: CoreAudioGainRamp

    init(
        inputFormat: CoreAudioPCMFormat,
        outputFormat: CoreAudioPCMFormat,
        maximumFrameCount: Int,
        initialGainState: CoreAudioRealtimeGainState,
        channelMap: CoreAudioOutputChannelMap? = nil,
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

        let resolvedMap = channelMap ?? .singleDevice(
            uid: "",
            channelCount: outputFormat.channelCount
        )
        guard !resolvedMap.slices.isEmpty,
              resolvedMap.totalChannelCount == outputFormat.channelCount else {
            throw CoreAudioPCMFormatError.invalidTotalChannelCount(
                resolvedMap.totalChannelCount
            )
        }
        self.channelMap = resolvedMap
        gainState = initialGainState
        ramp = CoreAudioGainRamp(
            currentGain: initialGainState.targetGain,
            coefficient: CoreAudioGainRamp.coefficient(sampleRate: outputFormat.sampleRate)
        )
        inputScratch = .allocate(capacity: maximumFrameCount * inputFormat.channelCount)
        inputScratch.initialize(repeating: 0)
        processScratch = .allocate(capacity: maximumFrameCount * inputFormat.channelCount)
        processScratch.initialize(repeating: 0)
        gainScratch = .allocate(capacity: maximumFrameCount)
        gainScratch.initialize(repeating: initialGainState.targetGain)
        processEQProcessor = CoreAudioGraphicEQProcessor(
            sampleRate: outputFormat.sampleRate,
            channelCount: inputFormat.channelCount,
            curve: initialGainState.processEQ
        )

        let processors = resolvedMap.slices.enumerated().map { index, slice in
            CoreAudioGraphicEQProcessor(
                sampleRate: outputFormat.sampleRate,
                channelCount: slice.channelCount,
                curve: initialGainState.outputEQ(at: index)
            )
        }
        outputEQProcessors = processors

        outputSnapshotScratch = .allocate(capacity: processors.count)
        outputSnapshotScratch.initialize(repeating: processors[0].renderSnapshot())
        for index in processors.indices {
            outputSnapshotScratch[index] = processors[index].renderSnapshot()
        }

        outputSliceIndexByChannel = .allocate(capacity: outputFormat.channelCount)
        outputSliceIndexByChannel.initialize(repeating: 0)
        for (sliceIndex, slice) in resolvedMap.slices.enumerated() {
            for channel in slice.channelRange {
                outputSliceIndexByChannel[channel] = Int32(sliceIndex)
            }
        }
    }

    deinit {
        inputScratch.deallocate()
        processScratch.deallocate()
        gainScratch.deallocate()
        outputSliceIndexByChannel.deallocate()
        outputSnapshotScratch.deinitialize()
        outputSnapshotScratch.deallocate()
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {
        let previous = gainState
        if previous.processEQ != state.processEQ {
            processEQProcessor.updateCurve(state.processEQ)
        }
        for index in outputEQProcessors.indices
        where previous.outputEQ(at: index) != state.outputEQ(at: index) {
            outputEQProcessors[index].updateCurve(state.outputEQ(at: index))
        }
        gainState = state
    }

    func updateSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite,
              (CoreAudioPCMFormat.minimumSampleRate...CoreAudioPCMFormat.maximumSampleRate)
                .contains(sampleRate) else { return }
        processEQProcessor.updateSampleRate(sampleRate)
        for processor in outputEQProcessors {
            processor.updateSampleRate(sampleRate)
        }
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
        let processSnapshot = processEQProcessor.renderSnapshot()
        var outputSnapshotIndex = 0
        while outputSnapshotIndex < outputEQProcessors.count {
            outputSnapshotScratch[outputSnapshotIndex] =
                outputEQProcessors[outputSnapshotIndex].renderSnapshot()
            outputSnapshotIndex += 1
        }
        let targetGain = gainState.targetGain
        var localRamp = ramp
        var peak: Float = 0
        var globalOutputChannel = 0

        var frame = 0
        while frame < frameCount {
            gainScratch[frame] = localRamp.next(targetGain: targetGain)
            frame += 1
        }

        // Process EQ is shared. Compute it once before the signal fans out to
        // destination channel slices.
        frame = 0
        while frame < frameCount {
            var channel = 0
            while channel < inputFormat.channelCount {
                let index = frame * inputFormat.channelCount + channel
                processScratch[index] = processSnapshot.processSample(
                    inputScratch[index],
                    channel: channel
                )
                channel += 1
            }
            frame += 1
        }

        var bufferIndex = 0
        while bufferIndex < outputs.count {
            let buffer = outputs[bufferIndex]
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount > 0,
                  let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            frame = 0
            while frame < frameCount {
                let frameOffset = frame * bufferChannelCount
                var localChannel = 0
                while localChannel < bufferChannelCount {
                    let outputChannel = globalOutputChannel + localChannel
                    if outputChannel < outputFormat.channelCount {
                        let inputChannel = outputChannel % inputFormat.channelCount
                        let processed = processScratch[
                            frame * inputFormat.channelCount + inputChannel
                        ]
                        let gained = processed * gainScratch[frame]
                        let sliceIndex = Int(outputSliceIndexByChannel[outputChannel])
                        let slice = channelMap.slices[sliceIndex]
                        let equalized = outputSnapshotScratch[sliceIndex].processSample(
                            gained,
                            channel: outputChannel - slice.channelOffset
                        )
                        let output = CoreAudioSoftLimiter.apply(equalized)
                        samples[frameOffset + localChannel] = output
                        let magnitude = output < 0 ? -output : output
                        if magnitude > peak { peak = magnitude }
                    }
                    localChannel += 1
                }
                frame += 1
            }
            globalOutputChannel += bufferChannelCount
            bufferIndex += 1
        }

        ramp = localRamp
        peakMeter.publish(peak)
    }

    func consumePeakLevel() -> Float {
        peakMeter.consume()
    }

    var storageFingerprint: (
        inputScratch: UInt,
        processScratch: UInt,
        gainScratch: UInt,
        coefficientsA: UInt,
        coefficientsB: UInt,
        activeSectionsA: UInt,
        activeSectionsB: UInt,
        delays: UInt,
        outputSliceIndexByChannel: UInt,
        outputSnapshotScratch: UInt,
        outputProcessorCount: Int
    ) {
        let process = processEQProcessor.storageFingerprint
        return (
            UInt(bitPattern: inputScratch.baseAddress!),
            UInt(bitPattern: processScratch.baseAddress!),
            UInt(bitPattern: gainScratch.baseAddress!),
            process.coefficientsA,
            process.coefficientsB,
            process.activeSectionsA,
            process.activeSectionsB,
            process.delays,
            UInt(bitPattern: outputSliceIndexByChannel.baseAddress!),
            UInt(bitPattern: outputSnapshotScratch.baseAddress!),
            outputEQProcessors.count
        )
    }

    @inline(__always)
    private func copyInputToScratch(
        _ inputs: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        var globalInputChannel = 0
        var bufferIndex = 0
        while bufferIndex < inputs.count {
            let buffer = inputs[bufferIndex]
            let bufferChannelCount = Int(buffer.mNumberChannels)
            guard bufferChannelCount > 0,
                  let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            var frame = 0
            while frame < frameCount {
                let frameOffset = frame * bufferChannelCount
                let scratchOffset = frame * inputFormat.channelCount + globalInputChannel
                var localChannel = 0
                while localChannel < bufferChannelCount {
                    inputScratch[scratchOffset + localChannel] = samples[frameOffset + localChannel]
                    localChannel += 1
                }
                frame += 1
            }
            globalInputChannel += bufferChannelCount
            bufferIndex += 1
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
        var index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels == format.bufferChannelCounts[index],
                  buffer.mData != nil else { return 0 }
            channelTotal += channels
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            let bufferCapacity = sampleCount / channels
            if bufferCapacity < capacity { capacity = bufferCapacity }
            index += 1
        }
        return channelTotal == format.channelCount && capacity != Int.max ? capacity : 0
    }

    @inline(__always)
    private static func zeroAll(_ outputs: UnsafeMutableAudioBufferListPointer) {
        var index = 0
        while index < outputs.count {
            let buffer = outputs[index]
            if let data = buffer.mData, buffer.mDataByteSize > 0 {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            index += 1
        }
    }
}
