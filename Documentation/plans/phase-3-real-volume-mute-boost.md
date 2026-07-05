# Phase 3 Real Per-App Volume, Mute, And Boost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make existing per-app volume, mute, and boost controls affect real app audio on one output path.

**Architecture:** Extend Phase 2 taps into an active CoreAudio render path. Each controlled app owns one process tap, one private aggregate device that targets the current default output device, and one IOProc. The realtime callback applies volume × boost, mute, ramp smoothing, and soft limiting only; EQ remains bypassed until Phase 4.

**Tech Stack:** Swift 6, CoreAudio process taps, CoreAudio aggregate devices, `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart`, XCTest.

---

## Reference Notes

FineTune's `ProcessTapController` and `TapResources` show the core shape:

- create process tap
- create private aggregate with target output device and tap UUID
- create IOProc
- start aggregate device
- teardown order: stop IOProc, destroy IOProc, destroy aggregate, destroy tap
- use ramped gain and soft limiter on realtime thread

Phase 3 intentionally supports only follow-default routing and one output device. Multi-device and explicit per-app device routing stay Phase 5 and Phase 10.

## File Structure

- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioRealtimeGain.swift`: pure gain/mute/boost state, ramp math, limiter.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapResources.swift`: active resource container and teardown order.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAggregateDeviceBuilder.swift`: pure aggregate description builder for one output device plus one tap.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`: owns aggregate, IOProc, and realtime callback for one app tap.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: create active IO controllers instead of tap-only sessions.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: route `setVolume`, `setMuted`, and `setBoost` into active controllers.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`: expose default output UID for follow-default output.
- Test `Tests/EQMacRepTests/CoreAudioRealtimeGainTests.swift`: pure gain/ramp/limiter tests.
- Test `Tests/EQMacRepTests/CoreAudioAggregateDeviceBuilderTests.swift`: aggregate description keys.
- Test `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`: manager forwards command state.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Pure Realtime Gain Model

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioRealtimeGain.swift`
- Test: `Tests/EQMacRepTests/CoreAudioRealtimeGainTests.swift`

- [ ] **Step 1: Write failing tests**

Create `CoreAudioRealtimeGainTests.swift`:

```swift
import XCTest
@testable import EQMacRep

final class CoreAudioRealtimeGainTests: XCTestCase {
    func testEffectiveGainCombinesVolumeMuteAndBoost() {
        var state = CoreAudioRealtimeGainState(volume: 0.5, boost: .x3, isMuted: false)

        XCTAssertEqual(state.targetGain, 1.5, accuracy: 0.0001)

        state.isMuted = true

        XCTAssertEqual(state.targetGain, 0, accuracy: 0.0001)
    }

    func testRampMovesCurrentGainTowardTarget() {
        var ramp = CoreAudioGainRamp(currentGain: 1, coefficient: 0.5)

        let first = ramp.next(targetGain: 0)
        let second = ramp.next(targetGain: 0)

        XCTAssertEqual(first, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second, 0.25, accuracy: 0.0001)
    }

    func testLimiterNeverExceedsOneForFiniteSamples() {
        XCTAssertEqual(CoreAudioSoftLimiter.apply(0.5), 0.5, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(abs(CoreAudioSoftLimiter.apply(4.0)), 1.0)
        XCTAssertLessThanOrEqual(abs(CoreAudioSoftLimiter.apply(-4.0)), 1.0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioRealtimeGainTests
```

Expected: compile failure for missing gain types.

- [ ] **Step 3: Implement gain model**

Create `CoreAudioRealtimeGain.swift`:

```swift
import Foundation

struct CoreAudioRealtimeGainState: Equatable {
    var volume: Float
    var boost: BoostLevel
    var isMuted: Bool

    init(volume: Double, boost: BoostLevel, isMuted: Bool) {
        self.volume = Float(AppCustomization.clampedVolume(volume, fallback: 1))
        self.boost = boost
        self.isMuted = isMuted
    }

    var targetGain: Float {
        isMuted ? 0 : volume * Float(boost.rawValue)
    }
}

struct CoreAudioGainRamp {
    var currentGain: Float
    var coefficient: Float

    mutating func next(targetGain: Float) -> Float {
        currentGain += (targetGain - currentGain) * coefficient
        return currentGain
    }

    static func coefficient(sampleRate: Double, rampMilliseconds: Double = 30) -> Float {
        let rampSeconds = max(rampMilliseconds, 1) / 1000
        return Float(1 - exp(-1 / (sampleRate * rampSeconds)))
    }
}

enum CoreAudioSoftLimiter {
    static let threshold: Float = 0.95
    static let ceiling: Float = 1.0

    static func apply(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        let absolute = abs(sample)
        guard absolute > threshold else { return sample }
        let headroom = ceiling - threshold
        let overshoot = absolute - threshold
        let compressed = threshold + headroom * (overshoot / (overshoot + headroom))
        return sample >= 0 ? compressed : -compressed
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```sh
swift test --filter CoreAudioRealtimeGainTests
```

Expected: PASS.

## Task 2: Buffer Processor

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioRealtimeGain.swift`
- Test: `Tests/EQMacRepTests/CoreAudioRealtimeGainTests.swift`

- [ ] **Step 1: Write failing processing test**

Add:

```swift
func testProcessorAppliesGainAndLimiterToInterleavedSamples() {
    var input: [Float] = [0.25, -0.25, 0.75, -0.75]
    var output = Array(repeating: Float(0), count: input.count)
    var ramp = CoreAudioGainRamp(currentGain: 2, coefficient: 1)

    input.withUnsafeBufferPointer { inputBuffer in
        output.withUnsafeMutableBufferPointer { outputBuffer in
            CoreAudioRealtimeGainProcessor.process(
                input: inputBuffer.baseAddress!,
                output: outputBuffer.baseAddress!,
                sampleCount: input.count,
                targetGain: 2,
                ramp: &ramp
            )
        }
    }

    XCTAssertEqual(output[0], 0.5, accuracy: 0.0001)
    XCTAssertEqual(output[1], -0.5, accuracy: 0.0001)
    XCTAssertLessThanOrEqual(abs(output[2]), 1.0)
    XCTAssertLessThanOrEqual(abs(output[3]), 1.0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioRealtimeGainTests/testProcessorAppliesGainAndLimiterToInterleavedSamples
```

Expected: compile failure for missing processor.

- [ ] **Step 3: Implement processor**

Add:

```swift
enum CoreAudioRealtimeGainProcessor {
    static func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        sampleCount: Int,
        targetGain: Float,
        ramp: inout CoreAudioGainRamp
    ) {
        guard sampleCount > 0 else { return }

        for index in 0..<sampleCount {
            let gain = ramp.next(targetGain: targetGain)
            output[index] = CoreAudioSoftLimiter.apply(input[index] * gain)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```sh
swift test --filter CoreAudioRealtimeGainTests
```

Expected: PASS.

## Task 3: Aggregate Device Description Builder

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAggregateDeviceBuilder.swift`
- Test: `Tests/EQMacRepTests/CoreAudioAggregateDeviceBuilderTests.swift`

- [ ] **Step 1: Write failing builder test**

Create `CoreAudioAggregateDeviceBuilderTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioAggregateDeviceBuilderTests: XCTestCase {
    func testSingleOutputAggregateDescriptionIncludesOutputAndTap() {
        let tapUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

        let description = CoreAudioAggregateDeviceBuilder.singleOutputDescription(
            outputDeviceUID: "built-in-output",
            tapUUID: tapUUID,
            appName: "Music"
        )

        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "built-in-output")
        XCTAssertEqual(description[kAudioAggregateDeviceClockDeviceKey] as? String, "built-in-output")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioAggregateDeviceBuilderTests
```

Expected: compile failure for missing builder.

- [ ] **Step 3: Implement builder**

Create `CoreAudioAggregateDeviceBuilder.swift`:

```swift
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
```

- [ ] **Step 4: Run builder test**

Run:

```sh
swift test --filter CoreAudioAggregateDeviceBuilderTests
```

Expected: PASS.

## Task 4: Active Tap Resource Teardown

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapResources.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing teardown-order test**

Add fake operation protocol and test:

```swift
func testActiveResourcesTearDownInSafeOrder() {
    let operations = FakeActiveTapOperations()
    var resources = CoreAudioTapResources(
        tapID: 10,
        aggregateDeviceID: 20,
        ioProcID: unsafeBitCast(0x01, to: AudioDeviceIOProcID.self)
    )

    resources.destroy(using: operations)

    XCTAssertEqual(operations.calls, ["stop:20", "destroyIO:20", "destroyAggregate:20", "destroyTap:10"])
}

private final class FakeActiveTapOperations: CoreAudioActiveTapOperating {
    var calls: [String] = []

    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("stop:\(deviceID)")
        return noErr
    }

    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        calls.append("destroyIO:\(deviceID)")
        return noErr
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        calls.append("destroyAggregate:\(deviceID)")
        return noErr
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        calls.append("destroyTap:\(tapID)")
        return noErr
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testActiveResourcesTearDownInSafeOrder
```

Expected: compile failure for missing resource types.

- [ ] **Step 3: Implement resource teardown**

Create `CoreAudioTapResources.swift`:

```swift
import CoreAudio
import Foundation

protocol CoreAudioActiveTapOperating: AnyObject {
    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus
    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus
}

struct CoreAudioTapResources {
    var tapID: AudioObjectID
    var aggregateDeviceID: AudioObjectID
    var ioProcID: AudioDeviceIOProcID?

    mutating func destroy(using operations: CoreAudioActiveTapOperating) {
        let aggregate = aggregateDeviceID
        let tap = tapID
        let proc = ioProcID

        if aggregate != AudioObjectID(kAudioObjectUnknown), proc != nil {
            _ = operations.stopDevice(aggregate, ioProcID: proc)
            _ = operations.destroyIOProc(aggregate, ioProcID: proc)
        }
        ioProcID = nil

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            _ = operations.destroyAggregateDevice(aggregate)
        }
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

        if tap != AudioObjectID(kAudioObjectUnknown) {
            _ = operations.destroyProcessTap(tap)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
```

- [ ] **Step 4: Run teardown test**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testActiveResourcesTearDownInSafeOrder
```

Expected: PASS.

## Task 5: Active IO Controller

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: build only plus manual check

- [ ] **Step 1: Implement system operations**

Create `CoreAudioTapIOController.swift` with:

```swift
import CoreAudio
import Foundation

final class SystemCoreAudioActiveTapOperations: CoreAudioActiveTapOperating {
    func stopDevice(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        AudioDeviceStop(deviceID, ioProcID)
    }

    func destroyIOProc(_ deviceID: AudioObjectID, ioProcID: AudioDeviceIOProcID?) -> OSStatus {
        guard let ioProcID else { return noErr }
        return AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    func destroyProcessTap(_ tapID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(tapID)
    }
}
```

- [ ] **Step 2: Implement controller shell**

Add:

```swift
@MainActor
final class CoreAudioTapIOController {
    private let target: CoreAudioTapTarget
    private let outputDeviceUID: String
    private let operations: CoreAudioActiveTapOperating
    private let queue = DispatchQueue(label: "EQMacRep.CoreAudioTapIOController", qos: .userInitiated)
    private var resources = CoreAudioTapResources(
        tapID: AudioObjectID(kAudioObjectUnknown),
        aggregateDeviceID: AudioObjectID(kAudioObjectUnknown),
        ioProcID: nil
    )

    private nonisolated(unsafe) var gainState: CoreAudioRealtimeGainState
    private nonisolated(unsafe) var ramp: CoreAudioGainRamp

    init(
        target: CoreAudioTapTarget,
        outputDeviceUID: String,
        initialGainState: CoreAudioRealtimeGainState,
        operations: CoreAudioActiveTapOperating = SystemCoreAudioActiveTapOperations()
    ) {
        self.target = target
        self.outputDeviceUID = outputDeviceUID
        self.gainState = initialGainState
        self.ramp = CoreAudioGainRamp(currentGain: initialGainState.targetGain, coefficient: 0.0007)
        self.operations = operations
    }

    func updateGainState(_ state: CoreAudioRealtimeGainState) {
        gainState = state
    }

    func stop() {
        resources.destroy(using: operations)
    }
}
```

- [ ] **Step 3: Add start method**

Add:

```swift
func start() throws {
    let tapDescription = CATapDescription(stereoMixdownOfProcesses: target.processObjectIDs.map { NSNumber(value: $0) })
    tapDescription.uuid = UUID()
    tapDescription.isPrivate = true
    tapDescription.muteBehavior = .mutedWhenTapped

    var tapID = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
    guard status == noErr else {
        throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
    }
    resources.tapID = tapID

    let aggregateDescription = CoreAudioAggregateDeviceBuilder.singleOutputDescription(
        outputDeviceUID: outputDeviceUID,
        tapUUID: tapDescription.uuid,
        appName: target.displayName
    )

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
    guard status == noErr else {
        stop()
        throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
    }
    resources.aggregateDeviceID = aggregateID

    var ioProcID: AudioDeviceIOProcID?
    status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inputData, _, outputData, _ in
        self?.render(inputData: inputData, outputData: outputData)
    }
    guard status == noErr else {
        stop()
        throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
    }
    resources.ioProcID = ioProcID

    status = AudioDeviceStart(aggregateID, ioProcID)
    guard status == noErr else {
        stop()
        throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
    }
}
```

- [ ] **Step 4: Add realtime render callback**

Add:

```swift
nonisolated private func render(inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>) {
    let inputs = UnsafeMutableAudioBufferListPointer(mutating: inputData)
    let outputs = UnsafeMutableAudioBufferListPointer(outputData)
    guard let input = inputs.first,
          let output = outputs.first,
          let inputData = input.mData?.assumingMemoryBound(to: Float.self),
          let outputData = output.mData?.assumingMemoryBound(to: Float.self) else {
        for buffer in outputs {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        return
    }

    let sampleCount = Int(min(input.mDataByteSize, output.mDataByteSize)) / MemoryLayout<Float>.size
    var localRamp = ramp
    CoreAudioRealtimeGainProcessor.process(
        input: inputData,
        output: outputData,
        sampleCount: sampleCount,
        targetGain: gainState.targetGain,
        ramp: &localRamp
    )
    ramp = localRamp
}
```

- [ ] **Step 5: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 6: Manager And Backend Command Wiring

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing command-forwarding test**

Add:

```swift
func testManagerUpdatesGainStateForActiveSession() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let manager = FakeRealtimeTapManager()

    manager.setVolume(0.25, for: music)
    manager.setMuted(true, for: music)
    manager.setBoost(.x4, for: music)

    XCTAssertEqual(manager.volumeCommands, [(music, 0.25)])
    XCTAssertEqual(manager.muteCommands, [(music, true)])
    XCTAssertEqual(manager.boostCommands, [(music, .x4)])
}
```

Add fake protocol:

```swift
private final class FakeRealtimeTapManager: CoreAudioRealtimeTapControlling {
    var volumeCommands: [(AudioAppIdentity, Double)] = []
    var muteCommands: [(AudioAppIdentity, Bool)] = []
    var boostCommands: [(AudioAppIdentity, BoostLevel)] = []

    func setVolume(_ volume: Double, for identity: AudioAppIdentity) { volumeCommands.append((identity, volume)) }
    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) { muteCommands.append((identity, muted)) }
    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) { boostCommands.append((identity, boost)) }
}
```

- [ ] **Step 2: Add realtime tap control protocol**

In `CoreAudioProcessTapManager.swift`, add:

```swift
protocol CoreAudioRealtimeTapControlling: AnyObject {
    func setVolume(_ volume: Double, for identity: AudioAppIdentity)
    func setMuted(_ muted: Bool, for identity: AudioAppIdentity)
    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity)
}
```

- [ ] **Step 3: Make process tap manager own IO controllers**

Replace tap-only session storage with controller storage:

```swift
private var controllersByIdentity: [AudioAppIdentity: CoreAudioTapIOController] = [:]
private var gainStatesByIdentity: [AudioAppIdentity: CoreAudioRealtimeGainState] = [:]
var defaultOutputDeviceUID: String?
```

When reconciling targets, create controller:

```swift
guard let outputDeviceUID = defaultOutputDeviceUID else { return }
let gainState = gainStatesByIdentity[target.identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
let controller = CoreAudioTapIOController(target: target, outputDeviceUID: outputDeviceUID, initialGainState: gainState)
try controller.start()
controllersByIdentity[target.identity] = controller
```

When tearing down:

```swift
controllersByIdentity.removeValue(forKey: identity)?.stop()
```

- [ ] **Step 4: Implement realtime command methods**

Add:

```swift
extension CoreAudioProcessTapManager: CoreAudioRealtimeTapControlling {
    func setVolume(_ volume: Double, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.volume = Float(AppCustomization.clampedVolume(volume, fallback: Double(state.volume)))
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }

    func setMuted(_ muted: Bool, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.isMuted = muted
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }

    func setBoost(_ boost: BoostLevel, for identity: AudioAppIdentity) {
        var state = gainStatesByIdentity[identity] ?? CoreAudioRealtimeGainState(volume: 1, boost: .x1, isMuted: false)
        state.boost = boost
        gainStatesByIdentity[identity] = state
        controllersByIdentity[identity]?.updateGainState(state)
    }
}
```

- [ ] **Step 5: Wire backend apply**

In `CoreAudioDiscoveryBackend.apply(_:)`:

```swift
switch command {
case let .setVolume(identity, volume):
    (tapManager as? CoreAudioRealtimeTapControlling)?.setVolume(volume, for: identity)
case let .setMuted(identity, muted):
    (tapManager as? CoreAudioRealtimeTapControlling)?.setMuted(muted, for: identity)
case let .setBoost(identity, boost):
    (tapManager as? CoreAudioRealtimeTapControlling)?.setBoost(boost, for: identity)
case .setEQ:
    pendingCommands.append(command)
}
```

Update status message to say volume/mute/boost active and EQ inactive.

- [ ] **Step 6: Run focused tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests
swift test --filter CoreAudioRealtimeGainTests
```

Expected: PASS.

## Task 7: Follow Default Output UID

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Test: `Tests/EQMacRepTests/CoreAudioMappingTests.swift`

- [ ] **Step 1: Write failing default UID test**

Add:

```swift
func testDefaultOutputUIDComesFromDefaultDeviceRecord() {
    let record = CoreAudioDeviceDiscovery.DeviceRecord(
        objectID: 42,
        uid: "built-in-output",
        name: "MacBook Speakers",
        hasOutputStreams: true,
        isHidden: false
    )

    XCTAssertEqual(CoreAudioDeviceDiscovery.defaultOutputUID(records: [record], defaultDeviceID: 42), "built-in-output")
}
```

- [ ] **Step 2: Add pure helper**

In `CoreAudioDeviceDiscovery`:

```swift
static func defaultOutputUID(records: [DeviceRecord], defaultDeviceID: AudioObjectID?) -> String? {
    records.first { $0.objectID == defaultDeviceID }?.uid
}
```

- [ ] **Step 3: Store default UID in backend**

Add:

```swift
private var defaultOutputDeviceUID: String?
```

Set it in `fetchSnapshot()` after device discovery. Pass it into manager:

```swift
(tapManager as? CoreAudioProcessTapManager)?.defaultOutputDeviceUID = defaultOutputDeviceUID
```

- [ ] **Step 4: Run mapping tests**

Run:

```sh
swift test --filter CoreAudioMappingTests
```

Expected: PASS.

## Task 8: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- Phase 3 activates IOProc and one default-output aggregate per controlled app.
- Volume, mute, and boost are real.
- EQ remains pending until Phase 4.
- Routing remains follow-default only.

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter CoreAudioRealtimeGainTests
swift test --filter CoreAudioAggregateDeviceBuilderTests
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
- Move volume slider down and confirm real audio gets quieter.
- Toggle mute and confirm real audio silences/restores.
- Set boost to 2x or 3x and confirm real audio gets louder.
- Move EQ sliders and confirm no audible EQ change yet.
- Ignore app and confirm app returns to normal macOS output.
- Quit EQMacRep and confirm system audio remains normal.

## Review Notes

Phase 3 is the first phase that mutates real audio. Keep blast radius narrow: one default output path, no EQ, no explicit route selection, no multi-output, no input devices.
