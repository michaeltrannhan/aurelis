# Phase 9 Input Device Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover input devices and control input default device, input volume, and input mute where hardware supports it.

**Architecture:** Extend the backend snapshot with input devices and add input-specific commands. CoreAudio discovery reads input streams and default input device. A small input controller reads/writes input volume and mute properties. The popup gains an Output/Input segmented view while keeping app controls unchanged.

**Tech Stack:** Swift 6, CoreAudio HAL input-device properties, SwiftUI segmented controls, XCTest.

---

## Reference Notes

FineTune shows input devices in a separate device tab. It tracks default input device, input volume, and input mute state. It uses `kAudioHardwarePropertyDefaultInputDevice`, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` with input scope, and `kAudioDevicePropertyMute` with input scope.

Phase 9 does not add process taps for microphone audio. It controls macOS input devices only. Bluetooth codec policy is limited to clear status and safe avoidance.

## File Structure

- Modify `Sources/Auralis/Domain/AudioModels.swift`: add `AudioInputDeviceSnapshot`.
- Modify `Sources/Auralis/Audio/AudioBackend.swift`: add input devices to snapshot and input commands.
- Modify `Sources/Auralis/Audio/MockAudioBackend.swift`: mock input devices and record input commands.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`: discover input device records and default input UID.
- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioInputDeviceController.swift`: read/write input volume, mute, default input.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: return input devices and route input commands.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: store input devices and apply input commands.
- Create `Sources/Auralis/Views/InputDeviceRowView.swift`: input row controls.
- Modify `Sources/Auralis/Views/MenuBarRootView.swift`: add Output/Input device segmented view.
- Modify `Sources/Auralis/Views/Settings/AudioSettingsTab.swift`: lock input-device setting.
- Modify `Sources/Auralis/Domain/AppCustomization.swift`: input lock preference and preferred input device ID.
- Test `Tests/AuralisTests/CoreAudioInputDeviceMappingTests.swift`.
- Test `Tests/AuralisTests/CoreAudioInputDeviceControllerTests.swift`.
- Test `Tests/AuralisTests/AudioControlStoreTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Input Snapshot Model

**Files:**
- Modify: `Sources/Auralis/Domain/AudioModels.swift`
- Modify: `Sources/Auralis/Audio/AudioBackend.swift`
- Modify: `Sources/Auralis/Audio/MockAudioBackend.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing store test**

Add:

```swift
func testRefreshLoadsInputDevices() throws {
    let backend = MockAudioBackend(
        apps: [],
        devices: [],
        inputDevices: [
            AudioInputDeviceSnapshot(id: "built-in-mic", name: "MacBook Microphone", isDefault: true, volume: 0.8, isMuted: false)
        ]
    )
    let store = try makeStore(backend: backend)

    try store.refresh()

    XCTAssertEqual(store.inputDevices.count, 1)
    XCTAssertEqual(store.inputDevices[0].id, "built-in-mic")
    XCTAssertEqual(store.inputDevices[0].volume, 0.8)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testRefreshLoadsInputDevices
```

Expected: compile failure for missing input models.

- [ ] **Step 3: Add input snapshot**

Add:

```swift
struct AudioInputDeviceSnapshot: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var isDefault: Bool
    var volume: Double
    var isMuted: Bool
    var supportsVolume: Bool
    var supportsMute: Bool
}
```

Extend `AudioBackendSnapshot`:

```swift
var inputDevices: [AudioInputDeviceSnapshot]
```

Default `inputDevices` to `[]`.

- [ ] **Step 4: Extend mock backend**

Add `inputDevices` to `MockAudioBackend.init` and `defaultInputDevices` with a built-in mic sample.

- [ ] **Step 5: Store input snapshots**

Add to `AudioControlStore`:

```swift
@Published private(set) var inputDevices: [AudioInputDeviceSnapshot] = []
```

Set it during `refresh()`.

- [ ] **Step 6: Run store test**

Run:

```sh
swift test --filter AudioControlStoreTests/testRefreshLoadsInputDevices
```

Expected: PASS.

## Task 2: CoreAudio Input Discovery

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`
- Test: `Tests/AuralisTests/CoreAudioInputDeviceMappingTests.swift`

- [ ] **Step 1: Write failing mapping tests**

Create `CoreAudioInputDeviceMappingTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioInputDeviceMappingTests: XCTestCase {
    func testInputMappingUsesUIDNameAndDefaultFlag() {
        let record = CoreAudioDeviceDiscovery.DeviceRecord(
            objectID: 51,
            uid: "built-in-mic",
            name: "MacBook Microphone",
            hasOutputStreams: false,
            hasInputStreams: true,
            isHidden: false
        )

        let snapshot = CoreAudioDeviceDiscovery.mapInputDeviceRecord(
            record,
            defaultInputDeviceID: 51,
            volume: 0.7,
            isMuted: false,
            supportsVolume: true,
            supportsMute: true
        )

        XCTAssertEqual(snapshot?.id, "built-in-mic")
        XCTAssertEqual(snapshot?.name, "MacBook Microphone")
        XCTAssertEqual(snapshot?.isDefault, true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioInputDeviceMappingTests
```

Expected: compile failure for missing input fields and mapper.

- [ ] **Step 3: Expand device records**

Add to `DeviceRecord`:

```swift
var hasInputStreams: Bool
```

Populate it from:

```swift
kAudioDevicePropertyStreams
```

with `kAudioObjectPropertyScopeInput`.

- [ ] **Step 4: Add input mapper**

Add:

```swift
static func mapInputDeviceRecord(
    _ record: DeviceRecord,
    defaultInputDeviceID: AudioObjectID?,
    volume: Double,
    isMuted: Bool,
    supportsVolume: Bool,
    supportsMute: Bool
) -> AudioInputDeviceSnapshot?
```

Skip hidden and inputless devices. Use UID fallback `input:\(objectID)`.

- [ ] **Step 5: Discover input devices**

Add:

```swift
func discoverInputDevices() throws -> [AudioInputDeviceSnapshot]
```

Read `kAudioHardwarePropertyDefaultInputDevice`. For each input device, query volume/mute support and current values through the input controller from Task 3.

- [ ] **Step 6: Run mapping tests**

Run:

```sh
swift test --filter CoreAudioInputDeviceMappingTests
swift test --filter CoreAudioMappingTests
```

Expected: PASS.

## Task 3: Input Device Controller

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioInputDeviceController.swift`
- Test: `Tests/AuralisTests/CoreAudioInputDeviceControllerTests.swift`

- [ ] **Step 1: Write failing controller tests**

Create pure operation tests:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioInputDeviceControllerTests: XCTestCase {
    func testSetInputVolumeClampsAndWritesInputScope() {
        let operations = FakeInputDeviceOperations()
        let controller = CoreAudioInputDeviceController(operations: operations)

        controller.setVolume(1.4, for: 42)

        XCTAssertEqual(operations.volumeWrites, [.init(deviceID: 42, volume: 1)])
    }

    func testSetMutedWritesInputMute() {
        let operations = FakeInputDeviceOperations()
        let controller = CoreAudioInputDeviceController(operations: operations)

        controller.setMuted(true, for: 42)

        XCTAssertEqual(operations.muteWrites, [.init(deviceID: 42, muted: true)])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioInputDeviceControllerTests
```

Expected: compile failure for missing controller.

- [ ] **Step 3: Implement operations seam**

Add:

```swift
protocol CoreAudioInputDeviceOperating {
    func hasInputVolume(deviceID: AudioObjectID) -> Bool
    func readInputVolume(deviceID: AudioObjectID) -> Double
    func writeInputVolume(deviceID: AudioObjectID, volume: Double) -> OSStatus
    func hasInputMute(deviceID: AudioObjectID) -> Bool
    func readInputMute(deviceID: AudioObjectID) -> Bool
    func writeInputMute(deviceID: AudioObjectID, muted: Bool) -> OSStatus
    func setDefaultInputDevice(_ deviceID: AudioObjectID) -> OSStatus
}
```

System implementation uses:

- `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` with input scope
- `kAudioDevicePropertyMute` with input scope
- `kAudioHardwarePropertyDefaultInputDevice`

- [ ] **Step 4: Implement controller**

Add:

```swift
final class CoreAudioInputDeviceController {
    private let operations: CoreAudioInputDeviceOperating

    init(operations: CoreAudioInputDeviceOperating = SystemCoreAudioInputDeviceOperations()) {
        self.operations = operations
    }

    func setVolume(_ volume: Double, for deviceID: AudioObjectID) {
        let clamped = AppCustomization.clampedVolume(volume, fallback: 1)
        _ = operations.writeInputVolume(deviceID: deviceID, volume: clamped)
    }

    func setMuted(_ muted: Bool, for deviceID: AudioObjectID) {
        _ = operations.writeInputMute(deviceID: deviceID, muted: muted)
    }

    func setDefaultInputDevice(_ deviceID: AudioObjectID) {
        _ = operations.setDefaultInputDevice(deviceID)
    }
}
```

- [ ] **Step 5: Run controller tests**

Run:

```sh
swift test --filter CoreAudioInputDeviceControllerTests
```

Expected: PASS.

## Task 4: Backend Commands

**Files:**
- Modify: `Sources/Auralis/Audio/AudioBackend.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`
- Test: `Tests/AuralisTests/CoreAudioDiscoveryBackendTests.swift`

- [ ] **Step 1: Write failing command test**

Add:

```swift
func testInputMutationsNotifyBackend() throws {
    let backend = MockAudioBackend(inputDevices: [
        AudioInputDeviceSnapshot(id: "built-in-mic", name: "Mic", isDefault: true, volume: 0.5, isMuted: false, supportsVolume: true, supportsMute: true)
    ])
    let store = try makeStore(backend: backend)
    try store.refresh()

    try store.setInputVolume(0.25, for: "built-in-mic")
    try store.setInputMuted(true, for: "built-in-mic")
    try store.setDefaultInputDevice("built-in-mic")

    XCTAssertEqual(backend.commands, [
        .setInputVolume("built-in-mic", 0.25),
        .setInputMuted("built-in-mic", true),
        .setDefaultInputDevice("built-in-mic")
    ])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testInputMutationsNotifyBackend
```

Expected: compile failure for missing input commands.

- [ ] **Step 3: Add backend commands**

Add to `AudioBackendCommand`:

```swift
case setInputVolume(String, Double)
case setInputMuted(String, Bool)
case setDefaultInputDevice(String)
```

- [ ] **Step 4: Add store methods**

Add:

```swift
func setInputVolume(_ volume: Double, for deviceID: String) throws
func setInputMuted(_ muted: Bool, for deviceID: String) throws
func setDefaultInputDevice(_ deviceID: String) throws
```

Update local `inputDevices` after successful backend apply.

- [ ] **Step 5: Route commands in CoreAudio backend**

`CoreAudioDiscoveryBackend` keeps a lookup from device UID to `AudioObjectID` during discovery. For input commands, resolve UID to object ID and call `CoreAudioInputDeviceController`.

- [ ] **Step 6: Run command tests**

Run:

```sh
swift test --filter AudioControlStoreTests/testInputMutationsNotifyBackend
swift test --filter CoreAudioDiscoveryBackendTests
```

Expected: PASS.

## Task 5: Popup Input Device UI

**Files:**
- Create: `Sources/Auralis/Views/InputDeviceRowView.swift`
- Modify: `Sources/Auralis/Views/MenuBarRootView.swift`
- Test: `Tests/AuralisTests/CustomizationTests.swift`

- [ ] **Step 1: Write view-state helper test**

Add:

```swift
func testInputDeviceDisplayShowsMutedWhenVolumeRoundsToZero() {
    XCTAssertTrue(InputDeviceDisplayState(volume: 0.003, isMuted: false).showsMuted)
    XCTAssertTrue(InputDeviceDisplayState(volume: 0.5, isMuted: true).showsMuted)
    XCTAssertFalse(InputDeviceDisplayState(volume: 0.5, isMuted: false).showsMuted)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testInputDeviceDisplayShowsMutedWhenVolumeRoundsToZero
```

Expected: compile failure for missing display state.

- [ ] **Step 3: Implement input display state**

Add:

```swift
struct InputDeviceDisplayState: Equatable {
    var volume: Double
    var isMuted: Bool

    var displayedPercentage: Int {
        Int(round(AppCustomization.clampedVolume(volume, fallback: 0) * 100))
    }

    var showsMuted: Bool {
        isMuted || displayedPercentage == 0
    }
}
```

- [ ] **Step 4: Implement input row**

`InputDeviceRowView` shows:

- mic icon
- device name
- default badge
- mute button
- slider disabled when `supportsVolume == false`
- percent text
- click row to set default input device

- [ ] **Step 5: Add segmented device area**

In `MenuBarRootView`, add segmented control:

- Apps
- Output Devices
- Input Devices

For Phase 9, Output Devices can show current output list read-only; Input Devices gets active controls.

- [ ] **Step 6: Run build**

Run:

```sh
swift test --filter CustomizationTests/testInputDeviceDisplayShowsMutedWhenVolumeRoundsToZero
swift build
```

Expected: PASS and build succeeds.

## Task 6: Input Lock Preference

**Files:**
- Modify: `Sources/Auralis/Domain/AppCustomization.swift`
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Modify: `Sources/Auralis/Views/Settings/AudioSettingsTab.swift`
- Test: `Tests/AuralisTests/CustomizationTests.swift`

- [ ] **Step 1: Write input lock defaults test**

Add:

```swift
func testInputDeviceLockDefaultsOffWithoutPreferredDevice() {
    let customization = AppCustomization()

    XCTAssertFalse(customization.lockInputDevice)
    XCTAssertNil(customization.preferredInputDeviceID)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testInputDeviceLockDefaultsOffWithoutPreferredDevice
```

Expected: compile failure for missing input lock settings.

- [ ] **Step 3: Add customization fields**

Add:

```swift
var lockInputDevice: Bool
var preferredInputDeviceID: String?
```

Decode missing values as `false` and `nil`.

- [ ] **Step 4: Apply lock behavior**

When `lockInputDevice` is true and a preferred input device is present, `AudioControlStore.refresh()` checks whether that device is connected. When connected and not default, it applies `.setDefaultInputDevice(preferredID)`.

When user clicks an input row, store `preferredInputDeviceID` and set default input.

- [ ] **Step 5: Run input lock tests**

Run:

```sh
swift test --filter CustomizationTests/testInputDeviceLockDefaultsOffWithoutPreferredDevice
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 7: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- input devices are separate from output route devices
- input volume and mute are hardware/device controls, not process taps
- unsupported input volume/mute controls are disabled
- input lock behavior
- Bluetooth codec downgrade risk is avoided by not forcing Bluetooth profile changes

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter CoreAudioInputDeviceMappingTests
swift test --filter CoreAudioInputDeviceControllerTests
swift test --filter AudioControlStoreTests
swift test --filter CustomizationTests
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

- [ ] **Step 4: Manual input-device test**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Open popup and switch to Input Devices.
- Confirm built-in mic appears.
- Connect USB mic and confirm it appears.
- Click a mic row and confirm default input changes in macOS.
- Move input volume slider and confirm System Settings reflects it when supported.
- Toggle input mute and confirm mute state updates when supported.
- Enable input lock, switch default input elsewhere, refresh, and confirm app restores preferred input.
- Disconnect preferred input and confirm app does not loop writes.

## Review Notes

Phase 9 controls system input devices only. Do not add microphone processing, recording, noise suppression, or Bluetooth profile switching in this phase.
