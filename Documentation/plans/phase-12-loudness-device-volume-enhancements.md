# Phase 12 Loudness And Device Volume Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add later FineTune audio enhancements: loudness processing, alert volume, software device volume, and DDC display volume.

**Architecture:** Add device-volume services outside the app process-tap path, then expose their gain state to active tap controllers. Loudness processors run in the realtime path after EQ stages and before the final limiter. DDC runs on a utility queue and never touches the realtime callback.

**Tech Stack:** Swift 6, Accelerate/vDSP, CoreAudio HAL device properties, AppleScript for alert volume, IOKit DDC probing, XCTest.

---

## Reference Notes

FineTune separates hardware volume, software volume, DDC monitor volume, alert volume, loudness compensation, and loudness equalization. It keeps DDC writes debounced and backgrounded, and keeps loudness DSP realtime-safe.

Phase 12 does not add inspector, automation, signing, or updates. Those are Phase 13.

## File Structure

- Create `Sources/Auralis/Audio/Loudness/LoudnessSettings.swift`.
- Create `Sources/Auralis/Audio/Loudness/LoudnessCompensator.swift`.
- Create `Sources/Auralis/Audio/Loudness/LoudnessDetector.swift`.
- Create `Sources/Auralis/Audio/Loudness/GainComputer.swift`.
- Create `Sources/Auralis/Audio/Devices/CoreAudioDeviceVolumeController.swift`.
- Create `Sources/Auralis/Audio/Devices/SystemAlertVolumeController.swift`.
- Create `Sources/Auralis/Audio/Devices/SoftwareOutputVolumeStore.swift`.
- Create `Sources/Auralis/Audio/DDC/DDCService.swift`.
- Create `Sources/Auralis/Audio/DDC/DDCController.swift`.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioTapIOController.swift`: apply software device gain and loudness processors.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: device volume commands.
- Modify `Sources/Auralis/Views/Settings/AudioSettingsTab.swift`: loudness and alert volume controls.
- Test `Tests/AuralisTests/LoudnessCompensatorTests.swift`.
- Test `Tests/AuralisTests/LoudnessDetectorTests.swift`.
- Test `Tests/AuralisTests/CoreAudioDeviceVolumeControllerTests.swift`.
- Test `Tests/AuralisTests/SystemAlertVolumeControllerTests.swift`.
- Test `Tests/AuralisTests/DDCServiceTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Device Volume Controller

**Files:**
- Create: `Sources/Auralis/Audio/Devices/CoreAudioDeviceVolumeController.swift`
- Test: `Tests/AuralisTests/CoreAudioDeviceVolumeControllerTests.swift`

- [ ] **Step 1: Write device volume tests**

Create:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioDeviceVolumeControllerTests: XCTestCase {
    func testHardwareVolumeWritesClampValue() {
        let operations = FakeDeviceVolumeOperations()
        let controller = CoreAudioDeviceVolumeController(operations: operations)

        controller.setVolume(1.7, for: 42)

        XCTAssertEqual(operations.volumeWrites, [.init(deviceID: 42, volume: 1)])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioDeviceVolumeControllerTests
```

Expected: compile failure for missing controller.

- [ ] **Step 3: Implement operations**

Add operations for:

- output volume support
- output mute support
- read/write output volume scalar
- read/write output mute
- default output device
- default system output device

Use `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` output scope and `kAudioDevicePropertyMute` output scope.

- [ ] **Step 4: Implement controller**

Controller exposes:

```swift
func supportsHardwareVolume(_ deviceID: AudioObjectID) -> Bool
func setVolume(_ volume: Double, for deviceID: AudioObjectID)
func setMuted(_ muted: Bool, for deviceID: AudioObjectID)
```

Clamp volume to the closed unit range.

- [ ] **Step 5: Run tests**

Run:

```sh
swift test --filter CoreAudioDeviceVolumeControllerTests
```

Expected: PASS.

## Task 2: Alert Volume

**Files:**
- Create: `Sources/Auralis/Audio/Devices/SystemAlertVolumeController.swift`
- Test: `Tests/AuralisTests/SystemAlertVolumeControllerTests.swift`

- [ ] **Step 1: Write AppleScript command tests**

Create:

```swift
import XCTest
@testable import Auralis

final class SystemAlertVolumeControllerTests: XCTestCase {
    func testSetAlertVolumeBuildsClampedAppleScriptPercent() {
        XCTAssertEqual(SystemAlertVolumeScript.setVolumeScript(1.2), "set volume alert volume 100")
        XCTAssertEqual(SystemAlertVolumeScript.setVolumeScript(0.25), "set volume alert volume 25")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter SystemAlertVolumeControllerTests
```

Expected: compile failure for missing alert controller.

- [ ] **Step 3: Implement alert script helper**

Add:

```swift
enum SystemAlertVolumeScript {
    static func setVolumeScript(_ volume: Double) -> String
    static let getVolumeScript = "output volume of (get volume settings)"
}
```

`SystemAlertVolumeController` executes scripts off the main path and publishes cached value.

- [ ] **Step 4: Run alert tests**

Run:

```sh
swift test --filter SystemAlertVolumeControllerTests
```

Expected: PASS.

## Task 3: Software Output Volume

**Files:**
- Create: `Sources/Auralis/Audio/Devices/SoftwareOutputVolumeStore.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write gain combination test**

Add:

```swift
func testDeviceSoftwareGainMultipliesAppGain() {
    let appGain = CoreAudioRealtimeGainState(volume: 0.5, boost: .x2, isMuted: false)

    XCTAssertEqual(CoreAudioTapIOController.combinedTargetGain(appGain: appGain, deviceGain: 0.25), 0.25, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testDeviceSoftwareGainMultipliesAppGain
```

Expected: compile failure for missing helper.

- [ ] **Step 3: Implement software volume store**

Store per-output-device software gain and mute:

```swift
struct SoftwareOutputVolumeState: Codable, Equatable {
    var volume: Double
    var isMuted: Bool
    var gain: Float
}
```

Use gain `0` when muted, otherwise clamped volume.

- [ ] **Step 4: Apply in tap path**

Tap controller receives device software gain updates from manager. Combined gain is:

```swift
appGain.targetGain * deviceSoftwareGain
```

The final soft limiter still caps boosted output.

- [ ] **Step 5: Run tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testDeviceSoftwareGainMultipliesAppGain
```

Expected: PASS.

## Task 4: Loudness Compensation

**Files:**
- Create: `Sources/Auralis/Audio/Loudness/LoudnessSettings.swift`
- Create: `Sources/Auralis/Audio/Loudness/LoudnessCompensator.swift`
- Test: `Tests/AuralisTests/LoudnessCompensatorTests.swift`

- [ ] **Step 1: Write loudness coefficient tests**

Create:

```swift
import XCTest
@testable import Auralis

final class LoudnessCompensatorTests: XCTestCase {
    func testReferenceVolumeBypassesCompensation() {
        let compensator = LoudnessCompensator(sampleRate: 48000)

        compensator.updateForVolume(1.0)

        XCTAssertFalse(compensator.isEnabled)
    }

    func testLowVolumeEnablesFiniteCompensation() {
        let gains = LoudnessCompensator.sectionGains(forVolume: 0.25)

        XCTAssertEqual(gains.count, LoudnessCompensator.bandCount)
        XCTAssertTrue(gains.allSatisfy(\.isFinite))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter LoudnessCompensatorTests
```

Expected: compile failure for missing loudness processor.

- [ ] **Step 3: Implement loudness settings and processor**

Use a four-section topology:

- low shelf at 80 Hz
- low-mid peaking at 180 Hz
- upper-mid peaking at 3200 Hz
- high shelf at 10000 Hz

Bypass near reference volume. Use Phase 4 biquad processor and shelf math.

- [ ] **Step 4: Wire tap path**

DSP order:

1. graphic EQ
2. AutoEQ
3. loudness compensation
4. loudness equalizer from Task 5
5. app/device gain
6. limiter

- [ ] **Step 5: Run loudness tests**

Run:

```sh
swift test --filter LoudnessCompensatorTests
```

Expected: PASS.

## Task 5: Loudness Equalization

**Files:**
- Create: `Sources/Auralis/Audio/Loudness/LoudnessDetector.swift`
- Create: `Sources/Auralis/Audio/Loudness/GainComputer.swift`
- Test: `Tests/AuralisTests/LoudnessDetectorTests.swift`

- [ ] **Step 1: Write detector/gain tests**

Create:

```swift
import XCTest
@testable import Auralis

final class LoudnessDetectorTests: XCTestCase {
    func testGainComputerBoostsQuietSignal() {
        let settings = LoudnessEqualizerSettings()
        let computer = GainComputer(settings: settings)

        XCTAssertGreaterThan(computer.desiredGainDb(forLevelDb: -50), 0)
    }

    func testGainComputerCutsAboveThreshold() {
        let settings = LoudnessEqualizerSettings()
        let computer = GainComputer(settings: settings)

        XCTAssertLessThanOrEqual(computer.desiredGainDb(forLevelDb: -5), 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter LoudnessDetectorTests
```

Expected: compile failure for missing loudness equalizer types.

- [ ] **Step 3: Implement detector and gain computer**

Add RMS ring-buffer detector, attack/release smoothing, target loudness setting, max boost, max cut, and noise-floor protection. Preallocate buffers at init.

- [ ] **Step 4: Implement realtime gain smoother**

The realtime loudness equalizer applies a smoothed scalar gain per sample block and feeds final limiter. It performs no allocation, logging, or locks in callback.

- [ ] **Step 5: Run detector tests**

Run:

```sh
swift test --filter LoudnessDetectorTests
```

Expected: PASS.

## Task 6: DDC Display Volume

**Files:**
- Create: `Sources/Auralis/Audio/DDC/DDCService.swift`
- Create: `Sources/Auralis/Audio/DDC/DDCController.swift`
- Test: `Tests/AuralisTests/DDCServiceTests.swift`

- [ ] **Step 1: Write DDC packet tests**

Create:

```swift
import XCTest
@testable import Auralis

final class DDCServiceTests: XCTestCase {
    func testSetVCPPacketIncludesChecksum() {
        let packet = DDCCommandPacket.setVCP(code: 0x62, value: 50)

        XCTAssertEqual(packet.bytes.prefix(5), [0x84, 0x03, 0x62, 0x00, 0x32])
        XCTAssertEqual(packet.bytes.last, DDCCommandPacket.checksum(for: Array(packet.bytes.dropLast())))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter DDCServiceTests
```

Expected: compile failure for missing DDC types.

- [ ] **Step 3: Implement packet helpers**

Create pure packet builder and checksum helpers first.

- [ ] **Step 4: Implement DDC service and controller**

DDC service:

- dynamically loads IOAVService symbols
- probes VCP `0x62`
- reads current/max audio volume
- writes debounced volume updates

DDC controller:

- probes on utility queue
- matches displays to CoreAudio devices by name and UID/EDID where available
- stores DDC-backed device IDs
- debounces writes by 100 milliseconds
- persists mute and last volume state

- [ ] **Step 5: Run DDC tests**

Run:

```sh
swift test --filter DDCServiceTests
swift build
```

Expected: PASS and build succeeds.

## Task 7: Settings And Verification

**Files:**
- Modify: `Sources/Auralis/Views/Settings/AudioSettingsTab.swift`
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Add settings controls**

Audio tab controls:

- loudness compensation toggle
- loudness equalization toggle
- alert volume slider
- software volume for devices without hardware control
- DDC status badge for supported displays

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter LoudnessCompensatorTests
swift test --filter LoudnessDetectorTests
swift test --filter CoreAudioDeviceVolumeControllerTests
swift test --filter SystemAlertVolumeControllerTests
swift test --filter DDCServiceTests
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

- [ ] **Step 4: Manual device-volume test**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Toggle loudness compensation at low app volume and confirm audible change.
- Toggle loudness equalization on quiet and loud content and confirm leveling.
- Set alert volume and confirm macOS alert volume changes.
- Control output device volume for hardware-supported output.
- Control software volume for unsupported output without changing app volume.
- Control DDC display volume on supported monitor.
- Confirm DDC writes do not block audio or UI.

## Review Notes

Phase 12 has high hardware variance. Keep unsupported devices clearly labeled and never block the realtime callback on device volume or DDC work.
