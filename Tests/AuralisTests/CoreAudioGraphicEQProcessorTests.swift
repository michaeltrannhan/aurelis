import XCTest
@testable import Auralis

final class CoreAudioGraphicEQProcessorTests: XCTestCase {
    func testFlatCurveCopiesInput() {
        let processor = CoreAudioGraphicEQProcessor(sampleRate: 48000)
        let input = Self.stereoSine(frequency: 1000, sampleRate: 48000, frames: 128)
        var output = Array(repeating: Float(0), count: input.count)

        processor.updateCurve(EQCurve())
        process(processor: processor, input: input, output: &output)

        XCTAssertEqual(output, input)
    }

    func testNonFlatCurveChangesFiniteSamples() {
        let processor = CoreAudioGraphicEQProcessor(sampleRate: 48000)
        var curve = EQCurve()
        curve.setGain(6, at: 5)
        let input = Self.stereoSine(frequency: 1000, sampleRate: 48000, frames: 512)
        var output = Array(repeating: Float(0), count: input.count)

        processor.updateCurve(curve)
        process(processor: processor, input: input, output: &output)

        XCTAssertNotEqual(output, input)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    private func process(processor: CoreAudioGraphicEQProcessor, input: [Float], output: inout [Float]) {
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count / 2
                )
            }
        }
    }

    private static func stereoSine(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.2)
            return [sample, sample]
        }
    }
}
