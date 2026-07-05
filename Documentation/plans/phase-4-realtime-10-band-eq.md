# Phase 4 Realtime 10-Band EQ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing per-app 10-band EQ controls affect real app audio with realtime-safe DSP.

**Architecture:** Add an Accelerate-backed stereo biquad cascade to the Phase 3 tap IO path. The audio callback applies EQ first, then the Phase 3 gain, mute, boost, ramp, and limiter stage. EQ updates happen on the main actor by swapping prebuilt vDSP setups; the realtime callback performs no allocation, locking, logging, persistence, or UI work.

**Tech Stack:** Swift 6, Accelerate/vDSP biquad filters, CoreAudio process-tap IOProc from Phase 3, XCTest.

---

## Reference Notes

FineTune's EQ path uses:

- RBJ Audio EQ Cookbook peaking filters
- 10 graphic EQ frequencies: `31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000`
- graphic EQ Q value `1.4`
- `vDSP_biquad_CreateSetup` and `vDSP_biquad`
- one delay buffer per stereo channel
- disabled or flat EQ bypass
- bands at or above Nyquist replaced with unity coefficients
- old vDSP setups destroyed after a grace period, outside the realtime callback
- NaN output cleared to silence with delay buffers reset

Phase 4 intentionally excludes presets, AutoEQ, loudness compensation, device EQ, and multi-output EQ. Those stay Phase 11 and Phase 12.

## File Structure

- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadMath.swift`: RBJ peaking coefficient generation and 10-band coefficient arrays.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadProcessor.swift`: realtime-safe stereo vDSP biquad cascade.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioGraphicEQProcessor.swift`: adapts `EQCurve` to coefficients and processor enable state.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`: run EQ before gain in the IOProc callback.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: store and forward per-app EQ curves.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: route `.setEQ` into active controllers.
- Test `Tests/EQMacRepTests/CoreAudioBiquadMathTests.swift`: coefficient shape and Nyquist bypass.
- Test `Tests/EQMacRepTests/CoreAudioBiquadProcessorTests.swift`: bypass, flat passthrough, finite output.
- Test `Tests/EQMacRepTests/CoreAudioGraphicEQProcessorTests.swift`: curve-to-DSP behavior.
- Extend `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`: manager/backend EQ command wiring.
- Test `Tests/EQMacRepTests/CoreAudioDiscoveryBackendTests.swift`: backend command forwarding.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Biquad Coefficient Math

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadMath.swift`
- Test: `Tests/EQMacRepTests/CoreAudioBiquadMathTests.swift`

- [ ] **Step 1: Write failing coefficient tests**

Create `CoreAudioBiquadMathTests.swift`:

```swift
import XCTest
@testable import EQMacRep

final class CoreAudioBiquadMathTests: XCTestCase {
    func testPeakingZeroGainCreatesPassthroughRelationship() {
        let coefficients = CoreAudioBiquadMath.peakingEQCoefficients(
            frequency: 1000,
            gainDB: 0,
            q: CoreAudioBiquadMath.graphicEQQ,
            sampleRate: 48000
        )

        XCTAssertEqual(coefficients.count, 5)
        XCTAssertEqual(coefficients[0], 1, accuracy: 0.000001)
        XCTAssertEqual(coefficients[1], coefficients[3], accuracy: 0.000001)
        XCTAssertEqual(coefficients[2], coefficients[4], accuracy: 0.000001)
    }

    func testAllBandsReturnsTenSections() {
        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(
            EQCurve(gains: Array(repeating: 0, count: EQCurve.bandCount)),
            sampleRate: 48000
        )

        XCTAssertEqual(coefficients.count, EQCurve.bandCount * 5)
    }

    func testBandsAtOrAboveNyquistBypass() {
        var curve = EQCurve()
        curve.setGain(12, at: 9)

        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(curve, sampleRate: 22050)
        let highBand = Array(coefficients.suffix(5))

        XCTAssertEqual(highBand, CoreAudioBiquadMath.unityCoefficients)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioBiquadMathTests
```

Expected: compile failure for missing `CoreAudioBiquadMath`.

- [ ] **Step 3: Implement coefficient math**

Create `CoreAudioBiquadMath.swift`:

```swift
import Foundation

enum CoreAudioBiquadMath {
    static let graphicEQQ: Double = 1.4
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]
    static let unityCoefficients: [Double] = [1, 0, 0, 0, 0]

    static func peakingEQCoefficients(
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> [Double] {
        guard frequency.isFinite,
              gainDB.isFinite,
              q.isFinite,
              sampleRate.isFinite,
              frequency > 0,
              q > 0,
              sampleRate > 0,
              frequency < sampleRate / 2 else {
            return unityCoefficients
        }

        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sine = sin(omega)
        let cosine = cos(omega)
        let alpha = sine / (2 * q)

        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cosine
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cosine
        let a2 = 1 - alpha / amplitude

        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    static func coefficientsForEQCurve(_ curve: EQCurve, sampleRate: Double) -> [Double] {
        let normalized = EQCurve.normalized(curve.gains, range: curve.range)

        return frequencies.enumerated().flatMap { index, frequency in
            peakingEQCoefficients(
                frequency: frequency,
                gainDB: normalized[index],
                q: graphicEQQ,
                sampleRate: sampleRate
            )
        }
    }

    static func isFlat(_ curve: EQCurve) -> Bool {
        EQCurve.normalized(curve.gains, range: curve.range).allSatisfy { abs($0) < 0.0001 }
    }
}
```

- [ ] **Step 4: Run coefficient tests**

Run:

```sh
swift test --filter CoreAudioBiquadMathTests
```

Expected: PASS.

## Task 2: Realtime Biquad Processor

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadProcessor.swift`
- Test: `Tests/EQMacRepTests/CoreAudioBiquadProcessorTests.swift`

- [ ] **Step 1: Write failing processor tests**

Create `CoreAudioBiquadProcessorTests.swift`:

```swift
import XCTest
@testable import EQMacRep

final class CoreAudioBiquadProcessorTests: XCTestCase {
    func testDisabledProcessorCopiesInputToOutput() {
        let processor = CoreAudioBiquadProcessor(sectionCount: EQCurve.bandCount)
        let input: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        var output = Array(repeating: Float(0), count: input.count)

        processor.update(coefficients: CoreAudioBiquadMath.unityCoefficientsForSections(EQCurve.bandCount), isEnabled: false)
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count / 2
                )
            }
        }

        XCTAssertEqual(output, input)
    }

    func testFlatUnityCoefficientsPassThroughStereo() {
        let processor = CoreAudioBiquadProcessor(sectionCount: EQCurve.bandCount)
        let input: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        var output = Array(repeating: Float(0), count: input.count)

        processor.update(coefficients: CoreAudioBiquadMath.unityCoefficientsForSections(EQCurve.bandCount), isEnabled: true)
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count / 2
                )
            }
        }

        for index in input.indices {
            XCTAssertEqual(output[index], input[index], accuracy: 0.0001)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioBiquadProcessorTests
```

Expected: compile failure for missing processor and helper.

- [ ] **Step 3: Add unity helper**

Add to `CoreAudioBiquadMath.swift`:

```swift
static func unityCoefficientsForSections(_ sectionCount: Int) -> [Double] {
    guard sectionCount > 0 else { return [] }
    return (0..<sectionCount).flatMap { _ in unityCoefficients }
}
```

- [ ] **Step 4: Implement processor**

Create `CoreAudioBiquadProcessor.swift`:

```swift
import Accelerate
import Darwin.C
import Foundation

private struct CoreAudioBiquadSetupBox: @unchecked Sendable {
    let setup: vDSP_biquad_Setup
}

final class CoreAudioBiquadProcessor: @unchecked Sendable {
    private let sectionCount: Int
    private let delayBufferSize: Int
    private let delayBufferLeft: UnsafeMutablePointer<Float>
    private let delayBufferRight: UnsafeMutablePointer<Float>

    private nonisolated(unsafe) var setup: vDSP_biquad_Setup?
    private nonisolated(unsafe) var isEnabled: Bool = false

    init(sectionCount: Int) {
        self.sectionCount = max(sectionCount, 1)
        self.delayBufferSize = (2 * self.sectionCount) + 2
        self.delayBufferLeft = .allocate(capacity: delayBufferSize)
        self.delayBufferRight = .allocate(capacity: delayBufferSize)
        delayBufferLeft.initialize(repeating: 0, count: delayBufferSize)
        delayBufferRight.initialize(repeating: 0, count: delayBufferSize)
    }

    deinit {
        let setupToDestroy = setup
        setup = nil
        if let setupToDestroy {
            vDSP_biquad_DestroySetup(setupToDestroy)
        }
        delayBufferLeft.deinitialize(count: delayBufferSize)
        delayBufferRight.deinitialize(count: delayBufferSize)
        delayBufferLeft.deallocate()
        delayBufferRight.deallocate()
    }

    func update(coefficients: [Double], isEnabled: Bool) {
        let expectedCount = sectionCount * 5
        let sanitized = coefficients.count == expectedCount
            ? coefficients
            : CoreAudioBiquadMath.unityCoefficientsForSections(sectionCount)

        let newSetup = sanitized.withUnsafeBufferPointer { pointer in
            vDSP_biquad_CreateSetup(pointer.baseAddress!, vDSP_Length(sectionCount))
        }

        let oldSetup = setup
        self.isEnabled = isEnabled
        setup = newSetup
        OSMemoryBarrier()

        if let oldSetup {
            let box = CoreAudioBiquadSetupBox(setup: oldSetup)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                vDSP_biquad_DestroySetup(box.setup)
            }
        }
    }

    func resetDelayBuffers() {
        let wasEnabled = isEnabled
        isEnabled = false
        OSMemoryBarrier()
        memset(delayBufferLeft, 0, delayBufferSize * MemoryLayout<Float>.size)
        memset(delayBufferRight, 0, delayBufferSize * MemoryLayout<Float>.size)
        isEnabled = wasEnabled
        OSMemoryBarrier()
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        guard isEnabled, let setup else {
            if input != UnsafePointer(output) {
                memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
            }
            return
        }

        if input != UnsafePointer(output) {
            memcpy(output, input, frameCount * 2 * MemoryLayout<Float>.size)
        }

        vDSP_biquad(setup, delayBufferLeft, output, 2, output, 2, vDSP_Length(frameCount))
        vDSP_biquad(setup, delayBufferRight, output.advanced(by: 1), 2, output.advanced(by: 1), 2, vDSP_Length(frameCount))

        let sampleCount = frameCount * 2
        for index in 0..<sampleCount where !output[index].isFinite {
            resetDelayBuffers()
            memset(output, 0, sampleCount * MemoryLayout<Float>.size)
            return
        }
    }
}
```

- [ ] **Step 5: Run processor tests**

Run:

```sh
swift test --filter CoreAudioBiquadProcessorTests
```

Expected: PASS.

## Task 3: Graphic EQ Processor Adapter

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioGraphicEQProcessor.swift`
- Test: `Tests/EQMacRepTests/CoreAudioGraphicEQProcessorTests.swift`

- [ ] **Step 1: Write failing graphic EQ tests**

Create `CoreAudioGraphicEQProcessorTests.swift`:

```swift
import XCTest
@testable import EQMacRep

final class CoreAudioGraphicEQProcessorTests: XCTestCase {
    func testFlatCurveCopiesInput() {
        let processor = CoreAudioGraphicEQProcessor(sampleRate: 48000)
        let input = Self.stereoSine(frequency: 1000, sampleRate: 48000, frames: 128)
        var output = Array(repeating: Float(0), count: input.count)

        processor.updateCurve(EQCurve())
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count / 2
                )
            }
        }

        XCTAssertEqual(output, input)
    }

    func testNonFlatCurveChangesFiniteSamples() {
        let processor = CoreAudioGraphicEQProcessor(sampleRate: 48000)
        var curve = EQCurve()
        curve.setGain(6, at: 5)
        let input = Self.stereoSine(frequency: 1000, sampleRate: 48000, frames: 512)
        var output = Array(repeating: Float(0), count: input.count)

        processor.updateCurve(curve)
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(
                    input: inputBuffer.baseAddress!,
                    output: outputBuffer.baseAddress!,
                    frameCount: input.count / 2
                )
            }
        }

        XCTAssertNotEqual(output, input)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    private static func stereoSine(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.2)
            return [sample, sample]
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioGraphicEQProcessorTests
```

Expected: compile failure for missing graphic EQ processor.

- [ ] **Step 3: Implement adapter**

Create `CoreAudioGraphicEQProcessor.swift`:

```swift
import Foundation

final class CoreAudioGraphicEQProcessor: @unchecked Sendable {
    private let processor: CoreAudioBiquadProcessor
    private var sampleRate: Double
    private var curve: EQCurve

    init(sampleRate: Double, curve: EQCurve = EQCurve()) {
        self.sampleRate = sampleRate
        self.curve = curve
        self.processor = CoreAudioBiquadProcessor(sectionCount: EQCurve.bandCount)
        applyCurrentCurve(resetDelayBuffers: true)
    }

    func updateCurve(_ curve: EQCurve) {
        self.curve = curve
        applyCurrentCurve(resetDelayBuffers: false)
    }

    func updateSampleRate(_ sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        applyCurrentCurve(resetDelayBuffers: true)
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        processor.process(input: input, output: output, frameCount: frameCount)
    }

    private func applyCurrentCurve(resetDelayBuffers: Bool) {
        let enabled = !CoreAudioBiquadMath.isFlat(curve)
        let coefficients = CoreAudioBiquadMath.coefficientsForEQCurve(curve, sampleRate: sampleRate)
        processor.update(coefficients: coefficients, isEnabled: enabled)
        if resetDelayBuffers {
            processor.resetDelayBuffers()
        }
    }
}
```

- [ ] **Step 4: Run graphic EQ tests**

Run:

```sh
swift test --filter CoreAudioGraphicEQProcessorTests
```

Expected: PASS.

## Task 4: Insert EQ Into The Tap Render Path

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Add controller-level EQ test seam**

Extend the Phase 3 tap controller test seam with a fake processor:

```swift
protocol CoreAudioEQProcessing: AnyObject {
    func updateCurve(_ curve: EQCurve)
    func updateSampleRate(_ sampleRate: Double)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int)
}
```

Make `CoreAudioGraphicEQProcessor` conform to `CoreAudioEQProcessing`.

- [ ] **Step 2: Write failing render-order test**

Add a pure render helper on `CoreAudioTapIOController`:

```swift
static func processStereoFrames(
    input: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int,
    gainState: CoreAudioRealtimeGainState,
    gainRamp: inout CoreAudioGainRamp,
    eqProcessor: CoreAudioEQProcessing?
)
```

Test that it calls EQ before gain:

```swift
func testRenderPathAppliesEQBeforeGain() {
    let eq = FakeEQProcessor(multiplier: 2)
    var ramp = CoreAudioGainRamp(currentGain: 0.5, coefficient: 1)
    let gain = CoreAudioRealtimeGainState(volume: 0.5, boost: .x1, isMuted: false)
    var input: [Float] = [0.25, 0.25, -0.25, -0.25]
    var output = Array(repeating: Float(0), count: input.count)

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            CoreAudioTapIOController.processStereoFrames(
                input: inputBuffer.baseAddress!,
                output: outputBuffer.baseAddress!,
                frameCount: 2,
                gainState: gain,
                gainRamp: &ramp,
                eqProcessor: eq
            )
        }
    }

    XCTAssertEqual(output, [0.25, 0.25, -0.25, -0.25])
}
```

- [ ] **Step 3: Implement render helper and callback integration**

Add `nonisolated(unsafe)` EQ storage to `CoreAudioTapIOController`:

```swift
private nonisolated(unsafe) var eqProcessor: CoreAudioEQProcessing?
```

Initialize it when the controller starts:

```swift
eqProcessor = CoreAudioGraphicEQProcessor(sampleRate: sampleRate, curve: currentEQCurve)
```

Implement update:

```swift
func updateEQ(_ curve: EQCurve) {
    currentEQCurve = curve
    eqProcessor?.updateCurve(curve)
}
```

In the IOProc callback, keep Phase 3 buffer validation. For stereo Float32 frames, call:

```swift
Self.processStereoFrames(
    input: inputSamples,
    output: outputSamples,
    frameCount: frameCount,
    gainState: gainState,
    gainRamp: &gainRamp,
    eqProcessor: eqProcessor
)
```

Implement the helper:

```swift
static func processStereoFrames(
    input: UnsafePointer<Float>,
    output: UnsafeMutablePointer<Float>,
    frameCount: Int,
    gainState: CoreAudioRealtimeGainState,
    gainRamp: inout CoreAudioGainRamp,
    eqProcessor: CoreAudioEQProcessing?
) {
    let sampleCount = frameCount * 2

    if let eqProcessor {
        eqProcessor.process(input: input, output: output, frameCount: frameCount)
        CoreAudioRealtimeGainProcessor.process(
            input: UnsafePointer(output),
            output: output,
            sampleCount: sampleCount,
            targetGain: gainState.targetGain,
            ramp: &gainRamp
        )
    } else {
        CoreAudioRealtimeGainProcessor.process(
            input: input,
            output: output,
            sampleCount: sampleCount,
            targetGain: gainState.targetGain,
            ramp: &gainRamp
        )
    }
}
```

- [ ] **Step 4: Run render-path tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testRenderPathAppliesEQBeforeGain
```

Expected: PASS.

## Task 5: Manager And Backend EQ Command Wiring

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`
- Test: `Tests/EQMacRepTests/CoreAudioDiscoveryBackendTests.swift`
- Test: `Tests/EQMacRepTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing manager/backend tests**

Add a manager test:

```swift
func testSetEQUpdatesActiveControllerAndStoredCurve() {
    let manager = CoreAudioProcessTapManager(operations: FakeProcessTapOperations())
    let identity = AudioAppIdentity(rawValue: "com.example.Music")
    var curve = EQCurve()
    curve.setGain(6, at: 5)

    manager.setEQ(identity, curve)

    XCTAssertEqual(manager.eqCurve(for: identity), curve)
}
```

Add a backend test for `.setEQ`:

```swift
func testBackendForwardsEQCommand() throws {
    let tapManager = FakeRealtimeTapController()
    let backend = CoreAudioDiscoveryBackend(tapManager: tapManager)
    let identity = AudioAppIdentity(rawValue: "com.example.Music")
    var curve = EQCurve()
    curve.setGain(3, at: 2)

    try backend.apply(.setEQ(identity, curve))

    XCTAssertEqual(tapManager.eqCommands.count, 1)
    XCTAssertEqual(tapManager.eqCommands[0].identity, identity)
    XCTAssertEqual(tapManager.eqCommands[0].curve, curve)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testSetEQUpdatesActiveControllerAndStoredCurve
swift test --filter CoreAudioDiscoveryBackendTests/testBackendForwardsEQCommand
```

Expected: compile failure for missing EQ command wiring.

- [ ] **Step 3: Extend active tap command protocol**

Add EQ to the Phase 3 realtime tap protocol:

```swift
protocol CoreAudioRealtimeTapControlling: AnyObject {
    func setVolume(_ identity: AudioAppIdentity, _ volume: Double)
    func setMuted(_ identity: AudioAppIdentity, _ muted: Bool)
    func setBoost(_ identity: AudioAppIdentity, _ boost: BoostLevel)
    func setEQ(_ identity: AudioAppIdentity, _ curve: EQCurve)
}
```

- [ ] **Step 4: Store and forward EQ in the manager**

Add manager state:

```swift
private var eqCurvesByIdentity: [AudioAppIdentity: EQCurve] = [:]
```

Add methods:

```swift
func setEQ(_ identity: AudioAppIdentity, _ curve: EQCurve) {
    eqCurvesByIdentity[identity] = curve
    controllersByIdentity[identity]?.updateEQ(curve)
}

func eqCurve(for identity: AudioAppIdentity) -> EQCurve {
    eqCurvesByIdentity[identity] ?? EQCurve()
}
```

When a controller is created during `reconcile`, pass `eqCurve(for: identity)` into its initializer.

- [ ] **Step 5: Forward `.setEQ` in backend**

Update `CoreAudioDiscoveryBackend.apply(_:)`:

```swift
case let .setEQ(identity, curve):
    tapManager.setEQ(identity, curve)
```

The existing `AudioControlStore.setEQGain` call path now reaches the active tap controller.

- [ ] **Step 6: Run command wiring tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testSetEQUpdatesActiveControllerAndStoredCurve
swift test --filter CoreAudioDiscoveryBackendTests/testBackendForwardsEQCommand
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 6: Sample Rate And Format Safety

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/EQMacRepTests/CoreAudioGraphicEQProcessorTests.swift`

- [ ] **Step 1: Write sample-rate update test**

Add:

```swift
func testSampleRateUpdateKeepsOutputFinite() {
    let processor = CoreAudioGraphicEQProcessor(sampleRate: 48000)
    var curve = EQCurve()
    curve.setGain(12, at: 9)
    let input = Self.stereoSine(frequency: 1000, sampleRate: 44100, frames: 256)
    var output = Array(repeating: Float(0), count: input.count)

    processor.updateCurve(curve)
    processor.updateSampleRate(44100)

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            processor.process(
                input: inputBuffer.baseAddress!,
                output: outputBuffer.baseAddress!,
                frameCount: input.count / 2
            )
        }
    }

    XCTAssertTrue(output.allSatisfy(\.isFinite))
}
```

- [ ] **Step 2: Use the actual stream sample rate**

In `CoreAudioTapIOController.start()`, read the aggregate device stream format sample rate after the aggregate is created and before the EQ processor is initialized.

Store:

```swift
private var sampleRate: Double
```

Use `CoreAudioGainRamp.coefficient(sampleRate:)` for the Phase 3 ramp and `CoreAudioGraphicEQProcessor(sampleRate:)` for EQ.

- [ ] **Step 3: Bypass unsupported callback formats**

Keep Phase 3 stereo mixdown as the supported path. In the IOProc callback:

- stereo Float32 buffers call `processStereoFrames`
- non-stereo or non-Float32 buffers copy input to output and apply Phase 3 sample-count gain only
- missing buffers zero output

- [ ] **Step 4: Run sample-rate tests**

Run:

```sh
swift test --filter CoreAudioGraphicEQProcessorTests/testSampleRateUpdateKeepsOutputFinite
```

Expected: PASS.

## Task 7: Documentation And Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- Phase 4 makes per-app EQ sliders real.
- EQ is per active app tap, not global and not per device.
- EQ runs before volume, boost, mute, and limiter.
- Flat EQ bypasses DSP work.
- Bands above Nyquist bypass.
- Presets and AutoEQ remain Phase 11.

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter CoreAudioBiquadMathTests
swift test --filter CoreAudioBiquadProcessorTests
swift test --filter CoreAudioGraphicEQProcessorTests
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

- [ ] **Step 3: Run full suite and build**

Run:

```sh
swift test
swift build
Scripts/build-debug-app.sh
```

Expected: tests pass, build succeeds, debug app bundle exists.

- [ ] **Step 4: Manual audio test**

Run:

```sh
open .build/EQMacRep.app
```

Manual checks:

- Grant Screen & System Audio Recording permission.
- Switch to CoreAudio Discovery.
- Play Music or Safari.
- Move 1 kHz EQ band up and confirm midrange gets louder.
- Move 1 kHz EQ band down and confirm midrange gets quieter.
- Reset all EQ bands and confirm output returns to normal.
- Change volume and boost while EQ is active and confirm limiter prevents harsh clipping.
- Ignore app and confirm app returns to normal macOS output.
- Quit EQMacRep and confirm system audio remains normal.

## Review Notes

Phase 4 is the DSP phase. Keep it limited to graphic EQ on the existing Phase 3 default-output path. Do not add presets, AutoEQ, device EQ, loudness compensation, or route-specific processors in this phase.
