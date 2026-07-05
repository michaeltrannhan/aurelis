# Phase 2 Process Tap Lifecycle Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create, track, and tear down CoreAudio process taps safely without reading or modifying audio.

**Architecture:** Keep tap lifecycle behind a backend-private manager. `AudioControlStore` tells capable backends which app identities are active and ignored; `CoreAudioDiscoveryBackend` maps identities to CoreAudio process object IDs and asks `CoreAudioProcessTapManager` to reconcile taps. Taps use `CATapUnmuted` and `privateTap`, with no IOProc, aggregate device, gain, mute, boost, routing, or EQ yet.

**Tech Stack:** Swift 6, CoreAudio `AudioHardwareCreateProcessTap`, `AudioHardwareDestroyProcessTap`, `CATapDescription`, XCTest.

---

## Reference Notes

Local SDK symbols used by this phase:

- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)`
- `AudioHardwareDestroyProcessTap(AudioObjectID)`
- `CATapDescription.initStereoMixdownOfProcesses(_:)`
- `CATapDescription.muteBehavior = CATapUnmuted`
- `CATapDescription.privateTap = true`

This phase must not create aggregate devices or start an IOProc. That belongs to Phase 3.

## File Structure

- Modify `Sources/EQMacRep/Audio/AudioBackend.swift`: add tap synchronization protocol.
- Modify `Sources/EQMacRep/State/AudioControlStore.swift`: call tap synchronization after refresh, ignore, unignore, reset, and shutdown.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessDiscovery.swift`: expose tap targets containing identity and process object IDs.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapTypes.swift`: tap target/session result types.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: manager protocol and CoreAudio implementation.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: own tap manager and identity target cache.
- Test `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`: pure manager reconciliation using fake tap operations.
- Test `Tests/EQMacRepTests/AudioControlStoreTests.swift`: store forwards active/ignored state to tap-capable backend.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Tap Target Types

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapTypes.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing target equality test**

Create `CoreAudioTapLifecycleTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import EQMacRep

final class CoreAudioTapLifecycleTests: XCTestCase {
    func testTapTargetUsesAppIdentityAndProcessObjects() {
        let identity = AudioAppIdentity(rawValue: "com.example.Music")
        let target = CoreAudioTapTarget(
            identity: identity,
            displayName: "Music",
            processObjectIDs: [10, 11]
        )

        XCTAssertEqual(target.identity, identity)
        XCTAssertEqual(target.processObjectIDs, [10, 11])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testTapTargetUsesAppIdentityAndProcessObjects
```

Expected: compile failure for missing `CoreAudioTapTarget`.

- [ ] **Step 3: Add tap target type**

Create `CoreAudioTapTypes.swift`:

```swift
import CoreAudio
import Foundation

struct CoreAudioTapTarget: Equatable {
    var identity: AudioAppIdentity
    var displayName: String
    var processObjectIDs: [AudioObjectID]
}

struct CoreAudioTapSession: Equatable {
    var identity: AudioAppIdentity
    var tapObjectID: AudioObjectID
    var processObjectIDs: [AudioObjectID]
}
```

- [ ] **Step 4: Run test**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testTapTargetUsesAppIdentityAndProcessObjects
```

Expected: PASS.

## Task 2: Process Discovery Tap Targets

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessDiscovery.swift`
- Test: `Tests/EQMacRepTests/CoreAudioMappingTests.swift`

- [ ] **Step 1: Write failing coalesced target test**

Add to `CoreAudioMappingTests`:

```swift
func testProcessRecordsCoalesceIntoTapTargets() {
    let first = CoreAudioProcessDiscovery.ProcessRecord(
        processObjectID: 10,
        processID: 100,
        bundleIdentifier: "com.example.Browser",
        displayName: "Browser Helper",
        executableName: "Browser Helper",
        isRunning: true
    )
    let second = CoreAudioProcessDiscovery.ProcessRecord(
        processObjectID: 11,
        processID: 101,
        bundleIdentifier: "com.example.Browser",
        displayName: "Browser",
        executableName: "Browser",
        isRunning: true
    )

    let targets = CoreAudioProcessDiscovery.mapTapTargets(
        records: [first, second],
        currentProcessID: 999
    )

    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].identity.rawValue, "com.example.Browser")
    XCTAssertEqual(targets[0].displayName, "Browser")
    XCTAssertEqual(targets[0].processObjectIDs, [10, 11])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioMappingTests/testProcessRecordsCoalesceIntoTapTargets
```

Expected: compile failure for missing `mapTapTargets`.

- [ ] **Step 3: Implement target mapping**

Add static method to `CoreAudioProcessDiscovery`:

```swift
static func mapTapTargets(records: [ProcessRecord], currentProcessID: pid_t) -> [CoreAudioTapTarget] {
    var targetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]

    for record in records {
        guard let snapshot = mapProcessRecord(record, currentProcessID: currentProcessID) else {
            continue
        }

        if var existing = targetsByIdentity[snapshot.identity] {
            existing.processObjectIDs.append(record.processObjectID)
            if shouldPreferDisplayName(snapshot.displayName, over: existing.displayName) {
                existing.displayName = snapshot.displayName
            }
            targetsByIdentity[snapshot.identity] = existing
        } else {
            targetsByIdentity[snapshot.identity] = CoreAudioTapTarget(
                identity: snapshot.identity,
                displayName: snapshot.displayName,
                processObjectIDs: [record.processObjectID]
            )
        }
    }

    return targetsByIdentity.values.sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
}
```

- [ ] **Step 4: Add instance discovery method**

Add:

```swift
func discoverTapTargets() throws -> [CoreAudioTapTarget] {
    let processObjects: [AudioObjectID] = try CoreAudioPropertyReader.array(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyProcessObjectList
    )
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let records = processObjects.compactMap { makeProcessRecord(processObjectID: $0) }
    return Self.mapTapTargets(records: records, currentProcessID: currentPID)
}
```

- [ ] **Step 5: Run mapping tests**

Run:

```sh
swift test --filter CoreAudioMappingTests
```

Expected: PASS.

## Task 3: Tap Manager With Fake Operations

**Files:**
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing reconcile test**

Add:

```swift
func testTapManagerCreatesAndDestroysToMatchTargets() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let safari = AudioAppIdentity(rawValue: "com.example.Safari")
    let operations = FakeTapOperations()
    let manager = CoreAudioProcessTapManager(operations: operations)

    try manager.reconcile(targets: [
        CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10]),
        CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
    ])
    try manager.reconcile(targets: [
        CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
    ])

    XCTAssertEqual(operations.created.map(\.identity), [music, safari])
    XCTAssertEqual(operations.destroyed, [1000])
    XCTAssertEqual(manager.activeSessions.map(\.identity), [safari])
}
```

Add fake:

```swift
private final class FakeTapOperations: CoreAudioTapOperating {
    var nextTapID: AudioObjectID = 1000
    private(set) var created: [CoreAudioTapTarget] = []
    private(set) var destroyed: [AudioObjectID] = []

    func createTap(for target: CoreAudioTapTarget) throws -> AudioObjectID {
        created.append(target)
        defer { nextTapID += 1 }
        return nextTapID
    }

    func destroyTap(_ tapObjectID: AudioObjectID) throws {
        destroyed.append(tapObjectID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testTapManagerCreatesAndDestroysToMatchTargets
```

Expected: compile failure for missing manager and operations protocol.

- [ ] **Step 3: Implement manager protocol and reconciliation**

Create `CoreAudioProcessTapManager.swift`:

```swift
import CoreAudio
import Foundation

protocol CoreAudioTapManaging: AnyObject {
    var activeSessions: [CoreAudioTapSession] { get }
    func reconcile(targets: [CoreAudioTapTarget]) throws
    func tearDown(identity: AudioAppIdentity) throws
    func tearDownAll() throws
}

protocol CoreAudioTapOperating: AnyObject {
    func createTap(for target: CoreAudioTapTarget) throws -> AudioObjectID
    func destroyTap(_ tapObjectID: AudioObjectID) throws
}

final class CoreAudioProcessTapManager: CoreAudioTapManaging {
    private let operations: CoreAudioTapOperating
    private var sessionsByIdentity: [AudioAppIdentity: CoreAudioTapSession] = [:]

    init(operations: CoreAudioTapOperating = SystemCoreAudioTapOperations()) {
        self.operations = operations
    }

    var activeSessions: [CoreAudioTapSession] {
        sessionsByIdentity.values.sorted {
            $0.identity.rawValue < $1.identity.rawValue
        }
    }

    func reconcile(targets: [CoreAudioTapTarget]) throws {
        let targetIDs = Set(targets.map(\.identity))
        for identity in sessionsByIdentity.keys where !targetIDs.contains(identity) {
            try tearDown(identity: identity)
        }

        for target in targets where sessionsByIdentity[target.identity]?.processObjectIDs != target.processObjectIDs {
            if sessionsByIdentity[target.identity] != nil {
                try tearDown(identity: target.identity)
            }
            let tapID = try operations.createTap(for: target)
            sessionsByIdentity[target.identity] = CoreAudioTapSession(
                identity: target.identity,
                tapObjectID: tapID,
                processObjectIDs: target.processObjectIDs
            )
        }
    }

    func tearDown(identity: AudioAppIdentity) throws {
        guard let session = sessionsByIdentity.removeValue(forKey: identity) else { return }
        try operations.destroyTap(session.tapObjectID)
    }

    func tearDownAll() throws {
        for identity in Array(sessionsByIdentity.keys) {
            try tearDown(identity: identity)
        }
    }
}
```

- [ ] **Step 4: Run manager test**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testTapManagerCreatesAndDestroysToMatchTargets
```

Expected: PASS.

## Task 4: System Tap Operations

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Test: build only

- [ ] **Step 1: Add CoreAudio error**

Add:

```swift
enum CoreAudioTapError: LocalizedError {
    case createFailed(identity: AudioAppIdentity, status: OSStatus)
    case destroyFailed(tapObjectID: AudioObjectID, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .createFailed(identity, status):
            return "Failed to create process tap for \(identity.rawValue): \(status)"
        case let .destroyFailed(tapObjectID, status):
            return "Failed to destroy process tap \(tapObjectID): \(status)"
        }
    }
}
```

- [ ] **Step 2: Add system operations**

Add:

```swift
final class SystemCoreAudioTapOperations: CoreAudioTapOperating {
    func createTap(for target: CoreAudioTapTarget) throws -> AudioObjectID {
        let processNumbers = target.processObjectIDs.map { NSNumber(value: $0) }
        let description = CATapDescription(stereoMixdownOfProcesses: processNumbers)
        description.name = "EQMacRep \(target.displayName)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapUnmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw CoreAudioTapError.createFailed(identity: target.identity, status: status)
        }
        return tapID
    }

    func destroyTap(_ tapObjectID: AudioObjectID) throws {
        let status = AudioHardwareDestroyProcessTap(tapObjectID)
        guard status == noErr else {
            throw CoreAudioTapError.destroyFailed(tapObjectID: tapObjectID, status: status)
        }
    }
}
```

- [ ] **Step 3: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 5: Backend Tap Synchronization Protocol

**Files:**
- Modify: `Sources/EQMacRep/Audio/AudioBackend.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Test: `Tests/EQMacRepTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Add backend protocol**

In `AudioBackend.swift`, add:

```swift
protocol AudioBackendTapSynchronizing {
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws
    func tearDownTap(for identity: AudioAppIdentity) throws
    func tearDownAllTaps() throws
}
```

- [ ] **Step 2: Add backend test with fake manager**

Add test:

```swift
func testBackendSynchronizesOnlyActiveNonIgnoredTargets() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let safari = AudioAppIdentity(rawValue: "com.example.Safari")
    let manager = CoreAudioProcessTapManager(operations: FakeTapOperations())
    let backend = CoreAudioDiscoveryBackend(
        processDiscovery: CoreAudioProcessDiscovery(),
        deviceDiscovery: CoreAudioDeviceDiscovery(),
        tapManager: manager
    )
    backend.replaceTapTargetsForTesting([
        CoreAudioTapTarget(identity: music, displayName: "Music", processObjectIDs: [10]),
        CoreAudioTapTarget(identity: safari, displayName: "Safari", processObjectIDs: [11])
    ])

    try backend.synchronizeTaps(activeAppIDs: [music, safari], ignoredAppIDs: [music])

    XCTAssertEqual(manager.activeSessions.map(\.identity), [safari])
}
```

- [ ] **Step 3: Implement backend conformance**

In `CoreAudioDiscoveryBackend`, add:

```swift
private let tapManager: CoreAudioTapManaging
private var tapTargetsByIdentity: [AudioAppIdentity: CoreAudioTapTarget] = [:]
```

Update initializer:

```swift
init(
    processDiscovery: CoreAudioProcessDiscovery = CoreAudioProcessDiscovery(),
    deviceDiscovery: CoreAudioDeviceDiscovery = CoreAudioDeviceDiscovery(),
    eventSource: CoreAudioDiscoveryEventSource = CoreAudioDiscoveryEventSource(),
    tapManager: CoreAudioTapManaging = CoreAudioProcessTapManager()
) {
    self.processDiscovery = processDiscovery
    self.deviceDiscovery = deviceDiscovery
    self.eventSource = eventSource
    self.tapManager = tapManager
}
```

During `fetchSnapshot()`:

```swift
let targets = try processDiscovery.discoverTapTargets()
tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
return AudioBackendSnapshot(
    apps: targets.map { target in
        AudioAppSnapshot(identity: target.identity, displayName: target.displayName)
    },
    devices: try deviceDiscovery.discoverDevices()
)
```

Add conformance:

```swift
extension CoreAudioDiscoveryBackend: AudioBackendTapSynchronizing {
    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        let targets = activeAppIDs
            .subtracting(ignoredAppIDs)
            .compactMap { tapTargetsByIdentity[$0] }
        try tapManager.reconcile(targets: targets)
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        try tapManager.tearDown(identity: identity)
    }

    func tearDownAllTaps() throws {
        try tapManager.tearDownAll()
    }
}
```

Add internal testing helper:

```swift
func replaceTapTargetsForTesting(_ targets: [CoreAudioTapTarget]) {
    tapTargetsByIdentity = Dictionary(uniqueKeysWithValues: targets.map { ($0.identity, $0) })
}
```

- [ ] **Step 4: Run tap lifecycle tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

## Task 6: Store Calls Tap Synchronization

**Files:**
- Modify: `Sources/EQMacRep/State/AudioControlStore.swift`
- Test: `Tests/EQMacRepTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing store forwarding test**

Add fake backend:

```swift
private final class TapSynchronizingMockBackend: MockAudioBackend, AudioBackendTapSynchronizing {
    private(set) var synchronizedActiveIDs: Set<AudioAppIdentity> = []
    private(set) var synchronizedIgnoredIDs: Set<AudioAppIdentity> = []
    private(set) var tornDownIDs: [AudioAppIdentity] = []
    private(set) var tearDownAllCount = 0

    func synchronizeTaps(activeAppIDs: Set<AudioAppIdentity>, ignoredAppIDs: Set<AudioAppIdentity>) throws {
        synchronizedActiveIDs = activeAppIDs
        synchronizedIgnoredIDs = ignoredAppIDs
    }

    func tearDownTap(for identity: AudioAppIdentity) throws {
        tornDownIDs.append(identity)
    }

    func tearDownAllTaps() throws {
        tearDownAllCount += 1
    }
}
```

Add test:

```swift
func testRefreshSynchronizesTapsWithIgnoredApps() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let backend = TapSynchronizingMockBackend(apps: [
        AudioAppSnapshot(identity: music, displayName: "Music")
    ])
    let store = try makeStore(backend: backend)

    try store.refresh()
    try store.ignore(music)

    XCTAssertEqual(backend.synchronizedActiveIDs, [music])
    XCTAssertEqual(backend.synchronizedIgnoredIDs, [music])
    XCTAssertEqual(backend.tornDownIDs, [music])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testRefreshSynchronizesTapsWithIgnoredApps
```

Expected: assertion failure or compile failure until store forwards state.

- [ ] **Step 3: Add store helper**

In `AudioControlStore`, add:

```swift
private func synchronizeBackendTaps() throws {
    guard let tapBackend = backend as? AudioBackendTapSynchronizing else { return }
    try tapBackend.synchronizeTaps(
        activeAppIDs: Set(appSnapshots.map(\.identity)),
        ignoredAppIDs: settings.ignoredAppIDs
    )
}
```

Call after snapshot reconciliation in `refresh()`:

```swift
try synchronizeBackendTaps()
```

Call in `ignore(_:)` before persistence rebuild:

```swift
if let tapBackend = backend as? AudioBackendTapSynchronizing {
    try tapBackend.tearDownTap(for: identity)
}
try synchronizeBackendTaps()
```

Call in `unignore(_:)` after removing ignored ID:

```swift
try synchronizeBackendTaps()
```

Call in `reset()`:

```swift
if let tapBackend = backend as? AudioBackendTapSynchronizing {
    try tapBackend.tearDownAllTaps()
}
```

- [ ] **Step 4: Run store tests**

Run:

```sh
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 7: Shutdown Teardown

**Files:**
- Modify: `Sources/EQMacRep/State/AudioControlStore.swift`
- Modify: `Sources/EQMacRep/EQMacRepApp.swift`

- [ ] **Step 1: Add explicit shutdown method**

In `AudioControlStore`, add:

```swift
func shutdown() {
    stopBackendObservation()
    try? (backend as? AudioBackendTapSynchronizing)?.tearDownAllTaps()
}
```

- [ ] **Step 2: Call shutdown from app**

In `EQMacRepApp.body`, attach:

```swift
.onChange(of: NSApp.isActive) { _, _ in }
```

If SwiftUI scene hooks do not expose termination cleanly, add an `NSApplicationDelegate` adaptor in `EQMacRepApp`:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
```

Then wire `store.shutdown()` in `applicationWillTerminate`.

- [ ] **Step 3: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 8: Documentation And Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update flows**

Document:

- Phase 2 creates private unmuted taps only.
- No IOProc or aggregate device exists yet.
- Ignore/reset/quit tear down taps.

- [ ] **Step 2: Update tracker after completion**

After implementation and verification, change Phase 2 status from `Planned` to `Complete`, and set active phase to Phase 3.

- [ ] **Step 3: Run focused tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests
swift test --filter AudioControlStoreTests
```

Expected: both pass.

- [ ] **Step 4: Run full verification**

Run:

```sh
swift test
swift build
Scripts/build-debug-app.sh
open .build/EQMacRep.app
```

Manual checks:

- Grant permission from Phase 1 if not already granted.
- Switch to CoreAudio Discovery.
- Play audio from Music or Safari.
- Confirm backend status still says controls are inactive until process-tap phase.
- Ignore playing app.
- Quit app.
- Confirm system audio remains normal after quit.

## Review Notes

Phase 2 intentionally creates taps but does not read tap audio. If manual testing shows creating unmuted private taps changes real output, stop and revise before Phase 3.
