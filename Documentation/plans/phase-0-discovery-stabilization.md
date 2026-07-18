# Phase 0 Discovery Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CoreAudio Discovery mode refresh live and produce stable app/device snapshots before process taps are added.

**Architecture:** Keep `AudioBackend.fetchSnapshot()` as the synchronous snapshot boundary. Add a backend event stream protocol for change notifications, then let `AudioControlStore` debounce those events and call `refresh()`. CoreAudio listeners stay inside `Sources/Auralis/Audio/CoreAudio/`; UI only observes store state.

**Tech Stack:** Swift 6, SwiftUI, Combine, XCTest, CoreAudio HAL property listeners.

---

## File Structure

- Modify `Sources/Auralis/Audio/AudioBackend.swift`: add update-event publishing protocol.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: add observation task, debounce, and safe refresh-on-event.
- Modify `Sources/Auralis/AuralisApp.swift`: start backend observation on popup task.
- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryEventSource.swift`: owns CoreAudio property listeners with listener procs and emits change events.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: expose event stream from event source.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessDiscovery.swift`: keep stable identity coalescing and add tests for helper-name preference.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`: sort device snapshots and keep default device first.
- Test `Tests/AuralisTests/AudioControlStoreTests.swift`: event-driven refresh behavior.
- Test `Tests/AuralisTests/CoreAudioMappingTests.swift`: device sorting and helper coalescing edge cases.
- Update `Documentation/phase-tracker.md` and `Documentation/flows.md`.

## Task 1: Backend Update Event Contract

**Files:**
- Modify: `Sources/Auralis/Audio/AudioBackend.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing store refresh test**

Add this fake backend inside `AudioControlStoreTests`:

```swift
private final class EventingBackend: AudioBackend, AudioBackendUpdatePublishing {
    var snapshots: [AudioBackendSnapshot]
    private var continuation: AsyncStream<Void>.Continuation?

    init(snapshots: [AudioBackendSnapshot]) {
        self.snapshots = snapshots
    }

    var updateEvents: AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func emitUpdate() {
        continuation?.yield(())
    }

    func fetchSnapshot() throws -> AudioBackendSnapshot {
        snapshots.removeFirst()
    }

    func apply(_ command: AudioBackendCommand) throws {}
}
```

Add test:

```swift
func testBackendUpdateEventRefreshesSnapshots() async throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let safari = AudioAppIdentity(rawValue: "com.example.Safari")
    let backend = EventingBackend(snapshots: [
        AudioBackendSnapshot(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music")
        ]),
        AudioBackendSnapshot(apps: [
            AudioAppSnapshot(identity: music, displayName: "Music"),
            AudioAppSnapshot(identity: safari, displayName: "Safari")
        ])
    ])
    let store = try makeStore(backend: backend)

    try store.refresh()
    store.startBackendObservation(debounceNanoseconds: 1_000_000)
    backend.emitUpdate()
    try await Task.sleep(nanoseconds: 30_000_000)

    XCTAssertEqual(store.displayRows.map(\.identity), [music, safari])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testBackendUpdateEventRefreshesSnapshots
```

Expected: compile failure for missing `AudioBackendUpdatePublishing` and `startBackendObservation`.

- [ ] **Step 3: Add update-event protocol**

In `AudioBackend.swift`, add:

```swift
protocol AudioBackendUpdatePublishing {
    var updateEvents: AsyncStream<Void> { get }
}
```

- [ ] **Step 4: Add store observation**

In `AudioControlStore`, add:

```swift
private var backendObservationTask: Task<Void, Never>?

func startBackendObservation(debounceNanoseconds: UInt64 = 250_000_000) {
    guard backendObservationTask == nil,
          let publisher = backend as? AudioBackendUpdatePublishing else {
        return
    }

    backendObservationTask = Task { [weak self] in
        for await _ in publisher.updateEvents {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            try? await self?.refresh()
        }
    }
}

func stopBackendObservation() {
    backendObservationTask?.cancel()
    backendObservationTask = nil
}
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```sh
swift test --filter AudioControlStoreTests/testBackendUpdateEventRefreshesSnapshots
```

Expected: PASS.

## Task 2: CoreAudio Discovery Event Source

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryEventSource.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`

- [ ] **Step 1: Add event source file**

Create:

```swift
import CoreAudio
import Foundation

final class CoreAudioDiscoveryEventSource {
    private var continuation: AsyncStream<Void>.Continuation?
    private var registeredAddresses: [AudioObjectPropertyAddress] = []
    private let context: UnsafeMutableRawPointer

    init() {
        context = Unmanaged.passUnretained(self).toOpaque()
    }

    lazy var events: AsyncStream<Void> = AsyncStream { continuation in
        self.continuation = continuation
        self.registerListeners()
        continuation.onTermination = { [weak self] _ in
            self?.unregisterListeners()
        }
    }

    deinit {
        unregisterListeners()
    }

    private func registerListeners() {
        guard registeredAddresses.isEmpty else { return }
        addSystemListener(kAudioHardwarePropertyProcessObjectList)
        addSystemListener(kAudioHardwarePropertyDevices)
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            Self.listenerProc,
            context
        )
        if status == noErr {
            registeredAddresses.append(address)
        }
    }

    private func unregisterListeners() {
        for address in registeredAddresses {
            var mutableAddress = address
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &mutableAddress,
                Self.listenerProc,
                context
            )
        }
        registeredAddresses.removeAll()
    }

    private static let listenerProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let source = Unmanaged<CoreAudioDiscoveryEventSource>
            .fromOpaque(context)
            .takeUnretainedValue()
        source.continuation?.yield(())
        return noErr
    }
}
```

- [ ] **Step 2: Build to expose listener-block issues**

Run:

```sh
swift build
```

Expected: build succeeds.

- [ ] **Step 3: Expose events from backend**

Modify `CoreAudioDiscoveryBackend`:

```swift
private let eventSource: CoreAudioDiscoveryEventSource

init(
    processDiscovery: CoreAudioProcessDiscovery = CoreAudioProcessDiscovery(),
    deviceDiscovery: CoreAudioDeviceDiscovery = CoreAudioDeviceDiscovery(),
    eventSource: CoreAudioDiscoveryEventSource = CoreAudioDiscoveryEventSource()
) {
    self.processDiscovery = processDiscovery
    self.deviceDiscovery = deviceDiscovery
    self.eventSource = eventSource
}
```

Add conformance:

```swift
extension CoreAudioDiscoveryBackend: AudioBackendUpdatePublishing {
    var updateEvents: AsyncStream<Void> {
        eventSource.events
    }
}
```

- [ ] **Step 4: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 3: Start Observation From App

**Files:**
- Modify: `Sources/Auralis/AuralisApp.swift`

- [ ] **Step 1: Add observation start**

In the existing `MenuBarExtra` task:

```swift
.task {
    store.startBackendObservation()
    try? store.refresh()
}
```

- [ ] **Step 2: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 4: Device Snapshot Stability

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`
- Test: `Tests/AuralisTests/CoreAudioMappingTests.swift`

- [ ] **Step 1: Write failing device sort test**

Add test:

```swift
func testDeviceSnapshotsSortDefaultFirstThenName() {
    let headphones = AudioDeviceSnapshot(id: "headphones", name: "Headphones", isDefault: false)
    let speakers = AudioDeviceSnapshot(id: "speakers", name: "MacBook Speakers", isDefault: true)
    let display = AudioDeviceSnapshot(id: "display", name: "Studio Display", isDefault: false)

    let sorted = CoreAudioDeviceDiscovery.sortedSnapshots([headphones, speakers, display])

    XCTAssertEqual(sorted.map(\.id), ["speakers", "headphones", "display"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioMappingTests/testDeviceSnapshotsSortDefaultFirstThenName
```

Expected: compile failure for missing `sortedSnapshots`.

- [ ] **Step 3: Add sorting helper and use it**

In `CoreAudioDeviceDiscovery`:

```swift
static func sortedSnapshots(_ snapshots: [AudioDeviceSnapshot]) -> [AudioDeviceSnapshot] {
    snapshots.sorted { lhs, rhs in
        if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
```

In `discoverDevices()`, wrap result:

```swift
return Self.sortedSnapshots(devices.compactMap { objectID in
    guard let record = makeDeviceRecord(objectID: objectID) else { return nil }
    return Self.mapDeviceRecord(record, defaultDeviceID: defaultDeviceID)
})
```

- [ ] **Step 4: Run test**

Run:

```sh
swift test --filter CoreAudioMappingTests/testDeviceSnapshotsSortDefaultFirstThenName
```

Expected: PASS.

## Task 5: Process Snapshot Stability

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessDiscovery.swift`
- Test: `Tests/AuralisTests/CoreAudioMappingTests.swift`

- [ ] **Step 1: Write failing helper-name test**

Add test:

```swift
func testCoalescingPrefersNonHelperName() {
    let identity = AudioAppIdentity(rawValue: "com.example.Browser")
    let helper = AudioAppSnapshot(
        identity: identity,
        displayName: "Browser Helper",
        bundleIdentifier: identity.rawValue
    )
    let renderer = AudioAppSnapshot(
        identity: identity,
        displayName: "Browser Renderer",
        bundleIdentifier: identity.rawValue
    )
    let app = AudioAppSnapshot(
        identity: identity,
        displayName: "Browser",
        bundleIdentifier: identity.rawValue
    )

    let snapshots = CoreAudioProcessDiscovery.coalescedSnapshots([helper, renderer, app])

    XCTAssertEqual(snapshots.single?.displayName, "Browser")
}
```

Also add local helper to the test file:

```swift
private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}
```

- [ ] **Step 2: Run test**

Run:

```sh
swift test --filter CoreAudioMappingTests/testCoalescingPrefersNonHelperName
```

Expected: PASS.

- [ ] **Step 3: Keep self-process and daemon filters covered**

Run:

```sh
swift test --filter CoreAudioMappingTests
```

Expected: all mapping tests pass.

## Task 6: Documentation And Tracker Update

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update flows**

Document that CoreAudio Discovery mode now listens for HAL process/device/default-output changes and debounces refreshes through `AudioControlStore`.

- [ ] **Step 2: Update tracker**

When implementation and verification pass, change Phase 0 status in `Documentation/phase-tracker.md` from `Approved` to `Complete`, and set active phase to Phase 1.

## Task 7: Verification

**Files:**
- No code edits.

- [ ] **Step 1: Run focused tests**

Run:

```sh
swift test --filter AudioControlStoreTests
swift test --filter CoreAudioMappingTests
```

Expected: both pass.

- [ ] **Step 2: Run full suite**

Run:

```sh
swift test
```

Expected: all tests pass.

- [ ] **Step 3: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Manual CoreAudio check**

Run:

```sh
swift run Auralis
```

Manual checks:

- Open Settings and choose CoreAudio Discovery.
- Relaunch app.
- Open popup.
- Start playback in Music, Safari, or another app.
- Confirm app appears without using mock mode.
- Connect or disconnect an output device.
- Confirm device list refreshes after CoreAudio event.
- Change default output.
- Confirm default device marker changes.
- Move sliders and EQ controls.
- Confirm status still says controls are inactive until process-tap phase.

## Review Notes

Phase 0 still must not create process taps, mute apps, reroute audio, or apply realtime EQ. It only stabilizes discovery and refresh behavior.
