# Phase 5 Single-Device Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each tapped app follow the default output device or route to one selected output device.

**Architecture:** Promote existing `DeviceRoute` from persisted intent to a real backend command. The store and row UI expose route selection. The CoreAudio tap manager resolves route intent to an output device UID, rebuilds a controller when the resolved UID changes, and falls back to follow-default when a selected device disappears.

**Tech Stack:** Swift 6, SwiftUI `Picker`, CoreAudio aggregate-device rebuilds from Phase 3, realtime EQ path from Phase 4, XCTest.

---

## Reference Notes

FineTune routing keeps route switching outside the realtime callback. It creates a new tap and aggregate device for the destination, starts the new IOProc, then tears down the old resources in a deterministic order. FineTune also treats device UID as the stable route identity and reacts to device connect, disconnect, and default-device changes.

Phase 5 intentionally supports only one selected output device per app. Multi-output routing, crossfade switching, Bluetooth-specific warmup, and route badges stay Phase 10.

## File Structure

- Modify `Sources/Auralis/Audio/AudioBackend.swift`: add `.setRoute(AudioAppIdentity, DeviceRoute)`.
- Modify `Sources/Auralis/Domain/AudioModels.swift`: add route labels and validation helpers.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: persist and forward route changes.
- Modify `Sources/Auralis/Views/AppRowView.swift`: add per-app route picker.
- Modify `Sources/Auralis/Views/MenuBarRootView.swift`: pass device list and route callback to rows.
- Modify `Sources/Auralis/Audio/MockAudioBackend.swift`: record route commands.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`: expose default output UID and device lookup helpers from Phase 3.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: resolve route and rebuild controllers on route changes.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: route `.setRoute` and feed available devices into manager.
- Test `Tests/AuralisTests/AudioControlStoreTests.swift`: route persistence and backend command.
- Test `Tests/AuralisTests/CoreAudioRouteResolverTests.swift`: route resolution and missing-device fallback.
- Test `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`: route change rebuild order.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Backend Route Command

**Files:**
- Modify: `Sources/Auralis/Audio/AudioBackend.swift`
- Modify: `Sources/Auralis/Audio/MockAudioBackend.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing store test**

Add:

```swift
func testRouteMutationPersistsAndNotifiesBackend() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let backend = MockAudioBackend(apps: [
        AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
    ])
    let store = try makeStore(backend: backend)
    try store.refresh()

    try store.setRoute(.selectedDevice("built-in-output"), for: music)

    let saved = try store.settingsStore.load()
    XCTAssertEqual(saved.appSettings[music]?.route, .selectedDevice("built-in-output"))
    XCTAssertEqual(backend.commands.last, .setRoute(music, .selectedDevice("built-in-output")))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testRouteMutationPersistsAndNotifiesBackend
```

Expected: compile failure for missing route command and store method.

- [ ] **Step 3: Add backend command**

Update `AudioBackendCommand`:

```swift
case setRoute(AudioAppIdentity, DeviceRoute)
```

`MockAudioBackend.apply(_:)` already stores generic backend commands, so no extra mock behavior is required after the enum case exists.

- [ ] **Step 4: Add store route method**

Add to `AudioControlStore`:

```swift
func setRoute(_ route: DeviceRoute, for identity: AudioAppIdentity) throws {
    ensureSettings(for: identity)
    settings.appSettings[identity]?.route = route
    try backend.apply(.setRoute(identity, route))
    try persistAndRebuild()
}
```

- [ ] **Step 5: Run store tests**

Run:

```sh
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 2: Route Labels And UI Picker

**Files:**
- Modify: `Sources/Auralis/Domain/AudioModels.swift`
- Modify: `Sources/Auralis/Views/AppRowView.swift`
- Modify: `Sources/Auralis/Views/MenuBarRootView.swift`
- Test: `Tests/AuralisTests/CustomizationTests.swift`

- [ ] **Step 1: Write route label tests**

Add:

```swift
func testDeviceRouteLabelsUseAvailableDevices() {
    let devices = [
        AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true),
        AudioDeviceSnapshot(id: "usb", name: "USB DAC")
    ]

    XCTAssertEqual(DeviceRoute.followDefault.label(devices: devices), "Follow Default (MacBook Speakers)")
    XCTAssertEqual(DeviceRoute.selectedDevice("usb").label(devices: devices), "USB DAC")
    XCTAssertEqual(DeviceRoute.selectedDevice("missing").label(devices: devices), "Missing Device")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testDeviceRouteLabelsUseAvailableDevices
```

Expected: compile failure for missing label helper.

- [ ] **Step 3: Add route label helper**

Add to `DeviceRoute`:

```swift
func label(devices: [AudioDeviceSnapshot]) -> String {
    switch self {
    case .followDefault:
        let defaultName = devices.first(where: \.isDefault)?.name ?? "System Output"
        return "Follow Default (\(defaultName))"
    case let .selectedDevice(deviceID):
        return devices.first(where: { $0.id == deviceID })?.name ?? "Missing Device"
    }
}
```

- [ ] **Step 4: Add row route picker**

Extend `AppRowView` inputs:

```swift
let devices: [AudioDeviceSnapshot]
let onRoute: (DeviceRoute) -> Void
```

Add a route picker below the volume row:

```swift
Picker("Output", selection: Binding(
    get: { row.settings.route },
    set: { route in onRoute(route) }
)) {
    Text(DeviceRoute.followDefault.label(devices: devices)).tag(DeviceRoute.followDefault)
    ForEach(devices) { device in
        Text(device.name).tag(DeviceRoute.selectedDevice(device.id))
    }
}
.labelsHidden()
```

Pass `store.devices` and `store.setRoute` from `MenuBarRootView`.

- [ ] **Step 5: Run UI-adjacent tests and build**

Run:

```sh
swift test --filter CustomizationTests/testDeviceRouteLabelsUseAvailableDevices
swift build
```

Expected: PASS and build succeeds.

## Task 3: Route Resolution

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioRouteResolver.swift`
- Test: `Tests/AuralisTests/CoreAudioRouteResolverTests.swift`

- [ ] **Step 1: Write failing route resolver tests**

Create `CoreAudioRouteResolverTests.swift`:

```swift
import XCTest
@testable import Auralis

final class CoreAudioRouteResolverTests: XCTestCase {
    func testFollowDefaultResolvesToDefaultOutputUID() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.followDefault), .resolved("built-in-output"))
    }

    func testSelectedDeviceResolvesWhenAvailable() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output", "usb"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.selectedDevice("usb")), .resolved("usb"))
    }

    func testMissingSelectedDeviceFallsBackToDefault() {
        let resolver = CoreAudioRouteResolver(
            availableOutputUIDs: ["built-in-output"],
            defaultOutputUID: "built-in-output"
        )

        XCTAssertEqual(resolver.resolve(.selectedDevice("missing")), .fallback("built-in-output"))
    }
}
```

- [ ] **Step 2: Run resolver test to verify it fails**

Run:

```sh
swift test --filter CoreAudioRouteResolverTests
```

Expected: compile failure for missing resolver.

- [ ] **Step 3: Implement resolver**

Create `CoreAudioRouteResolver.swift`:

```swift
import Foundation

enum CoreAudioResolvedRoute: Equatable {
    case resolved(String)
    case fallback(String)
    case unavailable

    var outputDeviceUID: String? {
        switch self {
        case let .resolved(uid), let .fallback(uid):
            return uid
        case .unavailable:
            return nil
        }
    }
}

struct CoreAudioRouteResolver {
    var availableOutputUIDs: Set<String>
    var defaultOutputUID: String?

    init(availableOutputUIDs: [String], defaultOutputUID: String?) {
        self.availableOutputUIDs = Set(availableOutputUIDs)
        self.defaultOutputUID = defaultOutputUID
    }

    func resolve(_ route: DeviceRoute) -> CoreAudioResolvedRoute {
        switch route {
        case .followDefault:
            guard let defaultOutputUID else { return .unavailable }
            return .resolved(defaultOutputUID)
        case let .selectedDevice(uid):
            if availableOutputUIDs.contains(uid) {
                return .resolved(uid)
            }
            guard let defaultOutputUID else { return .unavailable }
            return .fallback(defaultOutputUID)
        }
    }
}
```

- [ ] **Step 4: Run resolver tests**

Run:

```sh
swift test --filter CoreAudioRouteResolverTests
```

Expected: PASS.

## Task 4: Rebuild Tap Controller On Route Change

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing rebuild-order test**

Add:

```swift
func testRouteChangeRebuildsControllerWithSelectedDevice() throws {
    let factory = FakeTapIOControllerFactory()
    let manager = CoreAudioProcessTapManager(controllerFactory: factory)
    let identity = AudioAppIdentity(rawValue: "com.example.Music")

    manager.setAvailableOutputUIDs(["built-in-output", "usb"], defaultOutputUID: "built-in-output")
    manager.reconcile(apps: [AudioAppSnapshot(identity: identity, displayName: "Music")], ignoredAppIDs: [])
    manager.setRoute(identity, .selectedDevice("usb"))

    XCTAssertEqual(factory.createdOutputUIDs, ["built-in-output", "usb"])
    XCTAssertEqual(factory.stoppedControllers, ["built-in-output"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testRouteChangeRebuildsControllerWithSelectedDevice
```

Expected: compile failure for missing route manager APIs.

- [ ] **Step 3: Add manager route state**

Add:

```swift
private var routesByIdentity: [AudioAppIdentity: DeviceRoute] = [:]
private var resolvedOutputUIDByIdentity: [AudioAppIdentity: String] = [:]
private var availableOutputUIDs: [String] = []
private var defaultOutputUID: String?
```

Add methods:

```swift
func setAvailableOutputUIDs(_ outputUIDs: [String], defaultOutputUID: String?) {
    availableOutputUIDs = outputUIDs
    self.defaultOutputUID = defaultOutputUID
    rebuildControllersWithChangedResolvedRoutes()
}

func setRoute(_ identity: AudioAppIdentity, _ route: DeviceRoute) {
    routesByIdentity[identity] = route
    rebuildControllerForChangedRoute(identity)
}
```

- [ ] **Step 4: Rebuild only changed routes**

Implement route resolution:

```swift
private func resolvedOutputUID(for identity: AudioAppIdentity) -> String? {
    let resolver = CoreAudioRouteResolver(
        availableOutputUIDs: availableOutputUIDs,
        defaultOutputUID: defaultOutputUID
    )
    return resolver.resolve(routesByIdentity[identity] ?? .followDefault).outputDeviceUID
}
```

When a resolved UID changes:

1. stop and remove the old controller
2. create a new `CoreAudioTapIOController` with the same app settings and new output UID
3. start the new controller
4. store the new resolved UID

Do not rebuild controllers whose resolved UID is unchanged.

- [ ] **Step 5: Run route rebuild tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testRouteChangeRebuildsControllerWithSelectedDevice
```

Expected: PASS.

## Task 5: Backend Device Feed And Route Command

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`
- Test: `Tests/AuralisTests/CoreAudioMappingTests.swift`
- Test: `Tests/AuralisTests/CoreAudioDiscoveryBackendTests.swift`

- [ ] **Step 1: Write failing backend routing tests**

Add:

```swift
func testFetchSnapshotFeedsRouteDevicesToTapManager() throws {
    let tapManager = FakeRealtimeTapController()
    let backend = CoreAudioDiscoveryBackend(
        processDiscovery: FakeProcessDiscovery(apps: []),
        deviceDiscovery: FakeDeviceDiscovery(devices: [
            AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true),
            AudioDeviceSnapshot(id: "usb", name: "USB DAC")
        ]),
        tapManager: tapManager
    )

    _ = try backend.fetchSnapshot()

    XCTAssertEqual(tapManager.availableOutputUIDs, ["built-in-output", "usb"])
    XCTAssertEqual(tapManager.defaultOutputUID, "built-in-output")
}
```

- [ ] **Step 2: Run backend tests to verify they fail**

Run:

```sh
swift test --filter CoreAudioDiscoveryBackendTests/testFetchSnapshotFeedsRouteDevicesToTapManager
```

Expected: compile failure for missing backend injection seam or route feed.

- [ ] **Step 3: Forward device list to tap manager**

After `discoverDevices()` in `CoreAudioDiscoveryBackend.fetchSnapshot()`, call:

```swift
tapManager.setAvailableOutputUIDs(
    devices.map(\.id),
    defaultOutputUID: devices.first(where: \.isDefault)?.id
)
```

Update `apply(_:)`:

```swift
case let .setRoute(identity, route):
    tapManager.setRoute(identity, route)
```

- [ ] **Step 4: Run backend tests**

Run:

```sh
swift test --filter CoreAudioDiscoveryBackendTests
```

Expected: PASS.

## Task 6: Route Validity And Fallback UX

**Files:**
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Modify: `Sources/Auralis/Views/AppRowView.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write missing-device row test**

Add:

```swift
func testMissingSelectedRouteStillDisplaysStoredRoute() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let backend = MockAudioBackend(
        apps: [AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)],
        devices: [AudioDeviceSnapshot(id: "built-in-output", name: "MacBook Speakers", isDefault: true)]
    )
    let store = try makeStore(backend: backend)
    try store.refresh()
    try store.setRoute(.selectedDevice("usb"), for: music)
    try store.refresh()

    XCTAssertEqual(store.displayRows[0].settings.route, .selectedDevice("usb"))
}
```

- [ ] **Step 2: Preserve stored route and show fallback label**

Keep persisted route unchanged when a selected device disappears. The backend resolver falls back at audio time. The UI label shows `Missing Device` for the selected value and still includes `Follow Default (current default output)` as an available recovery option.

- [ ] **Step 3: Run route UX tests**

Run:

```sh
swift test --filter AudioControlStoreTests/testMissingSelectedRouteStillDisplaysStoredRoute
swift build
```

Expected: PASS and build succeeds.

## Task 7: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- `DeviceRoute.followDefault` resolves to current default output UID.
- `DeviceRoute.selectedDevice` resolves to that device UID while present.
- Missing selected devices fall back to default output without overwriting stored preference.
- Route changes rebuild tap controllers outside the realtime callback.
- Multi-output remains Phase 10.

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter AudioControlStoreTests
swift test --filter CoreAudioRouteResolverTests
swift test --filter CoreAudioTapLifecycleTests
swift test --filter CoreAudioDiscoveryBackendTests
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

- [ ] **Step 4: Manual routing test**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Grant Screen & System Audio Recording permission.
- Switch to CoreAudio Discovery.
- Play audio in two apps.
- Set app A to follow default and app B to a connected USB or Bluetooth output.
- Confirm app A follows system default output.
- Confirm app B plays through selected output.
- Disconnect selected output and confirm app B falls back to default output.
- Reconnect selected output and reselect it.
- Quit Auralis and confirm system audio remains normal.

## Review Notes

Phase 5 turns route intent into real audio routing for one selected output. Keep switching destructive and deterministic in this phase. Crossfade, multi-device fanout, and route badges wait for Phase 10.
