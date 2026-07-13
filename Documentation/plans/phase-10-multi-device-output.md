# Phase 10 Multi-Device Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one tapped app play through multiple selected output devices.

**Status (2026-07-13):** Implemented in code. The route model, resolver, aggregate builder, controller lifecycle, staged picker, persistence replay, default-aggregate expansion, sample-rate/active-device validation, dynamic rate observation, route-failure rollback/backoff, and automated coverage are complete. Real two-device playback and heterogeneous-device latency/disconnect testing remain manual verification gates.

**Architecture:** Extend the Phase 5 route model from one output UID to a normalized list of output UIDs. The tap manager resolves routes to one or more devices, builds a private aggregate containing all selected output subdevices plus the process tap, and rebuilds controllers outside the realtime callback when the resolved device set changes.

**Tech Stack:** Swift 6, CoreAudio aggregate devices, Phase 3 tap IO controller, Phase 5 route resolver, XCTest.

---

## Reference Notes

FineTune builds aggregate descriptions from one or more output device UIDs and keeps the first selected device as the clock/main device. It treats device UID order as meaningful for deterministic aggregate identity and callback behavior.

Phase 10 intentionally uses destructive rebuild switching. Crossfade polish remains out of scope unless Phase 6 soak tests prove destructive switching is not usable.

## File Structure

- Modify `Sources/EQMacRep/Domain/AudioModels.swift`: add multi-output route case.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioRouteResolver.swift`: resolve route to ordered output UID list.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAggregateDeviceBuilder.swift`: build one tap with many output subdevices.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: rebuild on route-set changes.
- Modify `Sources/EQMacRep/Views/AppRowView.swift`: multi-output picker entry point.
- Create `Sources/EQMacRep/Views/MultiOutputRoutePicker.swift`: selected-device checklist.
- Test `Tests/EQMacRepTests/CoreAudioRouteResolverTests.swift`.
- Test `Tests/EQMacRepTests/CoreAudioAggregateDeviceBuilderTests.swift`.
- Test `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`.
- Test `Tests/EQMacRepTests/AudioControlStoreTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Route Model

**Files:**
- Modify: `Sources/EQMacRep/Domain/AudioModels.swift`
- Test: `Tests/EQMacRepTests/CustomizationTests.swift`

- [x] **Step 1: Write route normalization test**

Add:

```swift
func testMultiOutputRouteNormalizesDuplicatesAndEmptySelection() {
    XCTAssertEqual(DeviceRoute.multiOutput(["usb", "usb", "built-in"]).normalized, .multiOutput(["usb", "built-in"]))
    XCTAssertEqual(DeviceRoute.multiOutput([]).normalized, .followDefault)
}
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testMultiOutputRouteNormalizesDuplicatesAndEmptySelection
```

Expected: compile failure for missing route case.

- [x] **Step 3: Add route case**

Add:

```swift
case multiOutput([String])
```

Add computed helper:

```swift
var normalized: DeviceRoute {
    switch self {
    case let .multiOutput(deviceIDs):
        var seen = Set<String>()
        let ordered = deviceIDs.filter { seen.insert($0).inserted }
        return ordered.isEmpty ? .followDefault : .multiOutput(ordered)
    case .followDefault, .selectedDevice:
        return self
    }
}
```

- [x] **Step 4: Run model tests**

Run:

```sh
swift test --filter CustomizationTests/testMultiOutputRouteNormalizesDuplicatesAndEmptySelection
```

Expected: PASS.

## Task 2: Resolve Multi-Output Routes

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioRouteResolver.swift`
- Test: `Tests/EQMacRepTests/CoreAudioRouteResolverTests.swift`

- [x] **Step 1: Write resolver tests**

Add:

```swift
func testMultiOutputResolvesOnlyAvailableDevicesInOrder() {
    let resolver = CoreAudioRouteResolver(
        availableOutputUIDs: ["built-in", "usb", "hdmi"],
        defaultOutputUID: "built-in"
    )

    XCTAssertEqual(resolver.resolve(.multiOutput(["usb", "missing", "hdmi"])), .resolvedMany(["usb", "hdmi"]))
}

func testMultiOutputFallsBackWhenAllSelectedDevicesAreMissing() {
    let resolver = CoreAudioRouteResolver(
        availableOutputUIDs: ["built-in"],
        defaultOutputUID: "built-in"
    )

    XCTAssertEqual(resolver.resolve(.multiOutput(["missing"])), .fallbackMany(["built-in"]))
}
```

- [x] **Step 2: Run resolver tests to verify they fail**

Run:

```sh
swift test --filter CoreAudioRouteResolverTests
```

Expected: compile failure for missing multi-output resolution.

- [x] **Step 3: Extend resolved route**

Add:

```swift
case resolvedMany([String])
case fallbackMany([String])
```

Add:

```swift
var outputDeviceUIDs: [String] {
    switch self {
    case let .resolved(uid), let .fallback(uid):
        return [uid]
    case let .resolvedMany(uids), let .fallbackMany(uids):
        return uids
    case .unavailable:
        return []
    }
}
```

- [x] **Step 4: Implement multi-output branch**

For `.multiOutput`, keep available selected UIDs in stored order. Return `.fallbackMany([default])` when no selected UID is available and default exists.

- [x] **Step 5: Run resolver tests**

Run:

```sh
swift test --filter CoreAudioRouteResolverTests
```

Expected: PASS.

## Task 3: Aggregate Builder For Many Outputs

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAggregateDeviceBuilder.swift`
- Test: `Tests/EQMacRepTests/CoreAudioAggregateDeviceBuilderTests.swift`

- [x] **Step 1: Write builder test**

Add:

```swift
func testMultiOutputAggregateIncludesAllSubdevices() {
    let tapUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!

    let description = CoreAudioAggregateDeviceBuilder.multiOutputDescription(
        outputDeviceUIDs: ["usb", "hdmi"],
        tapUUID: tapUUID,
        appName: "Music"
    )

    XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "usb")
    let subdevices = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
    XCTAssertEqual(subdevices?.count, 2)
    XCTAssertEqual(subdevices?[0][kAudioSubDeviceUIDKey] as? String, "usb")
    XCTAssertEqual(subdevices?[1][kAudioSubDeviceUIDKey] as? String, "hdmi")
}
```

- [x] **Step 2: Run builder test to verify it fails**

Run:

```sh
swift test --filter CoreAudioAggregateDeviceBuilderTests/testMultiOutputAggregateIncludesAllSubdevices
```

Expected: compile failure for missing builder method.

- [x] **Step 3: Implement builder**

Add:

```swift
static func multiOutputDescription(
    outputDeviceUIDs: [String],
    tapUUID: UUID,
    appName: String
) -> [String: Any]
```

Use first UID as `kAudioAggregateDeviceMainSubDeviceKey` and `kAudioAggregateDeviceClockDeviceKey`. Add every UID to `kAudioAggregateDeviceSubDeviceListKey`. Use drift compensation `false` for the clock device and `true` for additional devices.

- [x] **Step 4: Run builder tests**

Run:

```sh
swift test --filter CoreAudioAggregateDeviceBuilderTests
```

Expected: PASS.

## Task 4: Controller Rebuilds By Device Set

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [x] **Step 1: Write lifecycle test**

Add:

```swift
func testMultiOutputRouteRebuildsWhenResolvedDeviceSetChanges() {
    let factory = FakeTapIOControllerFactory()
    let manager = CoreAudioProcessTapManager(controllerFactory: factory)
    let identity = AudioAppIdentity(rawValue: "com.example.Music")

    manager.setAvailableOutputUIDs(["built-in", "usb", "hdmi"], defaultOutputUID: "built-in")
    manager.reconcile(apps: [AudioAppSnapshot(identity: identity, displayName: "Music")], ignoredAppIDs: [])
    manager.setRoute(identity, .multiOutput(["usb", "hdmi"]))

    XCTAssertEqual(factory.createdOutputUIDSets, [["built-in"], ["usb", "hdmi"]])
    XCTAssertEqual(factory.stopCount, 1)
}
```

- [x] **Step 2: Run lifecycle test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testMultiOutputRouteRebuildsWhenResolvedDeviceSetChanges
```

Expected: compile failure for controller factory UID-list support.

- [x] **Step 3: Update controller init**

Change controller route input from single `outputDeviceUID` to:

```swift
let outputDeviceUIDs: [String]
```

Keep single-device callers passing `[uid]`.

- [x] **Step 4: Update manager cache**

Replace:

```swift
resolvedOutputUIDByIdentity
```

with:

```swift
resolvedOutputUIDsByIdentity: [AudioAppIdentity: [String]]
```

Compare arrays for deterministic rebuild decisions.

- [x] **Step 5: Run lifecycle tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

## Task 5: Multi-Output Picker UI

**Files:**
- Create: `Sources/EQMacRep/Views/MultiOutputRoutePicker.swift`
- Modify: `Sources/EQMacRep/Views/AppRowView.swift`
- Test: `Tests/EQMacRepTests/CustomizationTests.swift`

- [x] **Step 1: Write picker state test**

Add:

```swift
func testMultiOutputPickerStateTogglesDevices() {
    var state = MultiOutputRoutePickerState(selectedDeviceIDs: ["usb"])

    state.toggle("hdmi")
    state.toggle("usb")

    XCTAssertEqual(state.route, .multiOutput(["hdmi"]))
}
```

- [x] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testMultiOutputPickerStateTogglesDevices
```

Expected: compile failure for missing picker state.

- [x] **Step 3: Implement state and picker**

Add:

```swift
struct MultiOutputRoutePickerState: Equatable {
    var selectedDeviceIDs: [String]
    mutating func toggle(_ deviceID: String)
    var route: DeviceRoute
}
```

The UI shows:

- Follow Default
- Single Device
- Multi-Output
- checklist of available devices when Multi-Output is active

- [x] **Step 4: Run UI tests and build**

Run:

```sh
swift test --filter CustomizationTests/testMultiOutputPickerStateTogglesDevices
swift build
```

Expected: PASS and build succeeds.

## Task 6: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [x] **Step 1: Update docs**

Document:

- multi-output route storage
- ordered output UID resolution
- aggregate builder clock-device rule
- drift-compensation rule
- fallback when selected outputs disappear

- [x] **Step 2: Run focused tests**

Run:

```sh
swift test --filter CoreAudioRouteResolverTests
swift test --filter CoreAudioAggregateDeviceBuilderTests
swift test --filter CoreAudioTapLifecycleTests
swift test --filter AudioControlStoreTests
swift test --filter CustomizationTests
```

Expected: PASS.

- [x] **Step 3: Run full suite and build**

Run:

```sh
swift test
swift build
Scripts/build-debug-app.sh
```

Expected: tests pass, build succeeds, debug app bundle exists.

- [ ] **Step 4: Manual multi-output test**

Run:

```sh
open .build/EQMacRep.app
```

Manual checks:

- Route one playing app to two output devices.
- Confirm both devices play the app.
- If the picker reports incompatible rates, align both devices to the same nominal sample rate in Audio MIDI Setup and retry.
- Confirm another app can stay on follow-default.
- Disconnect one selected output and confirm remaining output or default fallback works.
- Remove multi-output route and confirm old aggregate is destroyed.
- Quit EQMacRep and confirm no EQMacRep aggregates remain.

## Review Notes

Phase 10 is route fanout only. Do not add loudness, DDC, device inspector, or release tooling here.
