# Phase 6 Stability, Recovery, And Unsupported Apps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make real-audio mode robust enough for daily use after taps, EQ, and single-device routing exist.

**Architecture:** Add startup orphan cleanup, aggregate tracking, recovery classification, deterministic shutdown, unsupported-app policy, and user-visible backend health. Keep all recovery decisions outside the realtime callback. Treat app/device churn as normal input to a state machine, not as exceptional UI state.

**Tech Stack:** Swift 6, CoreAudio HAL device scanning, signal-safe aggregate tracking, tap manager state machine, XCTest.

---

## Reference Notes

FineTune hardens its CoreAudio path with:

- orphan aggregate cleanup on startup
- crash guard that tracks aggregate device IDs
- deterministic tap resource teardown
- device connect/disconnect callbacks
- route rebuilds when device sample rate or availability changes
- unsupported app handling through ignore/fallback behavior
- manual troubleshooting that tells users ignored apps return to normal macOS routing

Phase 6 intentionally avoids adding new visible feature areas. UI changes are limited to health/status, ignore affordances, and recovery messages.

## File Structure

- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioOrphanedAggregateCleanup.swift`: startup cleanup for `Auralis-` aggregate devices.
- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioAggregateCrashGuard.swift`: track live aggregate IDs and destroy them from crash handlers.
- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioTapFailurePolicy.swift`: classify recoverable, unsupported, and fatal CoreAudio failures.
- Create `Sources/Auralis/Audio/CoreAudio/CoreAudioTapHealth.swift`: per-app/backend health state.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioTapResources.swift`: track/untrack aggregate IDs.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessTapManager.swift`: add state machine, retry limits, stop-all, and stale-controller cleanup.
- Modify `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`: run startup cleanup, expose health status, and avoid tap attempts for unsupported apps.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: display recoverable backend health without losing persisted settings.
- Modify `Sources/Auralis/Views/MenuBarRootView.swift`: show compact backend health/error banner.
- Test `Tests/AuralisTests/CoreAudioOrphanedAggregateCleanupTests.swift`: cleanup filters only Auralis aggregates.
- Test `Tests/AuralisTests/CoreAudioAggregateCrashGuardTests.swift`: tracking slots add/remove deterministically.
- Test `Tests/AuralisTests/CoreAudioTapFailurePolicyTests.swift`: OSStatus classification.
- Extend `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`: stale cleanup, retry cap, stop-all.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Startup Orphan Aggregate Cleanup

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioOrphanedAggregateCleanup.swift`
- Test: `Tests/AuralisTests/CoreAudioOrphanedAggregateCleanupTests.swift`

- [ ] **Step 1: Write failing cleanup tests**

Create `CoreAudioOrphanedAggregateCleanupTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioOrphanedAggregateCleanupTests: XCTestCase {
    func testCleanupDestroysOnlyAuralisAggregateDevices() {
        let operations = FakeAggregateCleanupOperations(records: [
            .init(id: 1, name: "Auralis-Music", isAggregate: true),
            .init(id: 2, name: "FineTune-Music", isAggregate: true),
            .init(id: 3, name: "Auralis-USB", isAggregate: false),
            .init(id: 4, name: "Auralis-Browser", isAggregate: true)
        ])

        let destroyed = CoreAudioOrphanedAggregateCleanup.destroyOrphans(using: operations)

        XCTAssertEqual(destroyed, [1, 4])
        XCTAssertEqual(operations.destroyed, [1, 4])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioOrphanedAggregateCleanupTests
```

Expected: compile failure for missing cleanup type.

- [ ] **Step 3: Implement cleanup operations seam**

Create:

```swift
import CoreAudio
import Foundation

struct CoreAudioAggregateRecord: Equatable {
    var id: AudioObjectID
    var name: String
    var isAggregate: Bool
}

protocol CoreAudioAggregateCleanupOperating: AnyObject {
    func aggregateRecords() -> [CoreAudioAggregateRecord]
    func destroyAggregateDevice(_ id: AudioObjectID) -> OSStatus
}
```

Add system operations that read HAL devices, names, and aggregate transport/type using existing property-reader helpers.

- [ ] **Step 4: Implement cleanup**

Add:

```swift
enum CoreAudioOrphanedAggregateCleanup {
    static let aggregateNamePrefix = "Auralis-"

    @discardableResult
    static func destroyOrphans(using operations: CoreAudioAggregateCleanupOperating = SystemAggregateCleanupOperations()) -> [AudioObjectID] {
        operations.aggregateRecords().compactMap { record in
            guard record.isAggregate, record.name.hasPrefix(aggregateNamePrefix) else { return nil }
            return operations.destroyAggregateDevice(record.id) == noErr ? record.id : nil
        }
    }
}
```

- [ ] **Step 5: Run cleanup tests**

Run:

```sh
swift test --filter CoreAudioOrphanedAggregateCleanupTests
```

Expected: PASS.

## Task 2: Aggregate Crash Guard

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioAggregateCrashGuard.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioTapResources.swift`
- Test: `Tests/AuralisTests/CoreAudioAggregateCrashGuardTests.swift`

- [ ] **Step 1: Write failing tracking tests**

Create `CoreAudioAggregateCrashGuardTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioAggregateCrashGuardTests: XCTestCase {
    func testTrackerAddsAndRemovesAggregateIDs() {
        let tracker = CoreAudioAggregateTracker(maxSlots: 3)

        XCTAssertTrue(tracker.track(10))
        XCTAssertTrue(tracker.track(11))
        tracker.untrack(10)

        XCTAssertEqual(tracker.trackedIDs(), [11])
    }

    func testTrackerRejectsWhenFull() {
        let tracker = CoreAudioAggregateTracker(maxSlots: 1)

        XCTAssertTrue(tracker.track(10))
        XCTAssertFalse(tracker.track(11))
        XCTAssertEqual(tracker.trackedIDs(), [10])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioAggregateCrashGuardTests
```

Expected: compile failure for missing tracker.

- [ ] **Step 3: Implement fixed-slot tracker**

Create a non-Foundation tracker with fixed storage:

```swift
final class CoreAudioAggregateTracker {
    private var slots: [AudioObjectID]

    init(maxSlots: Int = 64) {
        slots = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: max(maxSlots, 1))
    }

    func track(_ id: AudioObjectID) -> Bool {
        guard !slots.contains(id),
              let index = slots.firstIndex(of: AudioObjectID(kAudioObjectUnknown)) else {
            return false
        }
        slots[index] = id
        return true
    }

    func untrack(_ id: AudioObjectID) {
        guard let index = slots.firstIndex(of: id) else { return }
        slots[index] = AudioObjectID(kAudioObjectUnknown)
    }

    func trackedIDs() -> [AudioObjectID] {
        slots.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }
}
```

- [ ] **Step 4: Add process-wide crash guard**

Add `CoreAudioAggregateCrashGuard.install()` with signal handlers for `SIGABRT`, `SIGSEGV`, `SIGBUS`, and `SIGTRAP`. The signal handler destroys tracked aggregate devices with `AudioHardwareDestroyAggregateDevice` and re-raises the signal.

Call:

```swift
CoreAudioAggregateCrashGuard.trackDevice(aggregateDeviceID)
CoreAudioAggregateCrashGuard.untrackDevice(aggregateDeviceID)
```

from `CoreAudioTapResources` immediately after aggregate creation and immediately before aggregate destruction.

- [ ] **Step 5: Run tracking tests**

Run:

```sh
swift test --filter CoreAudioAggregateCrashGuardTests
```

Expected: PASS.

## Task 3: Failure Policy

**Files:**
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioTapFailurePolicy.swift`
- Create: `Sources/Auralis/Audio/CoreAudio/CoreAudioTapHealth.swift`
- Test: `Tests/AuralisTests/CoreAudioTapFailurePolicyTests.swift`

- [ ] **Step 1: Write failing failure-policy tests**

Create `CoreAudioTapFailurePolicyTests.swift`:

```swift
import CoreAudio
import XCTest
@testable import Auralis

final class CoreAudioTapFailurePolicyTests: XCTestCase {
    func testDeviceMissingIsRecoverable() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.deviceUnavailable),
            .recoverable("Output device unavailable")
        )
    }

    func testPermissionDeniedDisablesTapAttempts() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.permissionDenied),
            .disabled("Screen & System Audio Recording permission denied")
        )
    }

    func testUnsupportedAppCanBeIgnored() {
        XCTAssertEqual(
            CoreAudioTapFailurePolicy.classify(.unsupportedProcess),
            .unsupported("App cannot be tapped")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CoreAudioTapFailurePolicyTests
```

Expected: compile failure for missing policy.

- [ ] **Step 3: Implement failure and health models**

Add:

```swift
enum CoreAudioTapStartFailure: Equatable {
    case deviceUnavailable
    case permissionDenied
    case unsupportedProcess
    case osStatus(OSStatus, operation: String)
}

enum CoreAudioTapFailureDecision: Equatable {
    case recoverable(String)
    case disabled(String)
    case unsupported(String)
    case fatal(String)
}

enum CoreAudioTapFailurePolicy {
    static func classify(_ failure: CoreAudioTapStartFailure) -> CoreAudioTapFailureDecision {
        switch failure {
        case .deviceUnavailable:
            return .recoverable("Output device unavailable")
        case .permissionDenied:
            return .disabled("Screen & System Audio Recording permission denied")
        case .unsupportedProcess:
            return .unsupported("App cannot be tapped")
        case let .osStatus(status, operation):
            return .recoverable("\(operation) failed with OSStatus \(status)")
        }
    }
}
```

Add:

```swift
struct CoreAudioTapHealth: Equatable {
    var activeAppCount: Int
    var failedAppMessages: [AudioAppIdentity: String]
    var backendMessage: String
}
```

- [ ] **Step 4: Run policy tests**

Run:

```sh
swift test --filter CoreAudioTapFailurePolicyTests
```

Expected: PASS.

## Task 4: Tap Manager State Machine And Retry Cap

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Test: `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write failing retry and stale-cleanup tests**

Add:

```swift
func testFailedTapDoesNotRetryForever() {
    let factory = FailingTapIOControllerFactory(error: CoreAudioTapStartFailure.unsupportedProcess)
    let manager = CoreAudioProcessTapManager(controllerFactory: factory, maxStartAttempts: 2)
    let identity = AudioAppIdentity(rawValue: "com.example.DAW")
    let app = AudioAppSnapshot(identity: identity, displayName: "DAW")

    manager.reconcile(apps: [app], ignoredAppIDs: [])
    manager.reconcile(apps: [app], ignoredAppIDs: [])
    manager.reconcile(apps: [app], ignoredAppIDs: [])

    XCTAssertEqual(factory.startAttempts, 2)
    XCTAssertEqual(manager.health.failedAppMessages[identity], "App cannot be tapped")
}

func testDisappearedAppStopsController() {
    let factory = FakeTapIOControllerFactory()
    let manager = CoreAudioProcessTapManager(controllerFactory: factory)
    let identity = AudioAppIdentity(rawValue: "com.example.Music")

    manager.reconcile(apps: [AudioAppSnapshot(identity: identity, displayName: "Music")], ignoredAppIDs: [])
    manager.reconcile(apps: [], ignoredAppIDs: [])

    XCTAssertEqual(factory.stoppedIdentities, [identity])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests/testFailedTapDoesNotRetryForever
swift test --filter CoreAudioTapLifecycleTests/testDisappearedAppStopsController
```

Expected: compile failure or failing assertions for missing state machine.

- [ ] **Step 3: Add state machine**

Track:

```swift
private enum ManagedTapState: Equatable {
    case inactive
    case starting(attempts: Int)
    case active
    case failed(CoreAudioTapFailureDecision, attempts: Int)
    case ignored
}
```

For each reconcile:

1. stop controllers for disappeared or ignored apps
2. start controllers for active eligible apps whose state is inactive
3. skip failed apps whose attempts reached `maxStartAttempts`
4. clear failure state when app disappears, route changes, or user unignores
5. publish `CoreAudioTapHealth`

- [ ] **Step 4: Add stop-all**

Add:

```swift
func stopAll() {
    for controller in controllersByIdentity.values {
        controller.stop()
    }
    controllersByIdentity.removeAll()
    resolvedOutputUIDByIdentity.removeAll()
    statesByIdentity.removeAll()
}
```

Call `stopAll()` from backend shutdown/deinit and app termination hooks.

- [ ] **Step 5: Run lifecycle tests**

Run:

```sh
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

## Task 5: Backend Startup And Health Reporting

**Files:**
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Modify: `Sources/Auralis/Views/MenuBarRootView.swift`
- Test: `Tests/AuralisTests/CoreAudioDiscoveryBackendTests.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing health tests**

Add:

```swift
func testStatusMessageIncludesTapFailures() {
    let backend = CoreAudioDiscoveryBackend(tapManager: FakeRealtimeTapController(
        health: CoreAudioTapHealth(
            activeAppCount: 1,
            failedAppMessages: [AudioAppIdentity(rawValue: "com.example.DAW"): "App cannot be tapped"],
            backendMessage: "CoreAudio active"
        )
    ))

    XCTAssertTrue(backend.statusMessage(appCount: 2, deviceCount: 1).contains("1 active tap"))
    XCTAssertTrue(backend.statusMessage(appCount: 2, deviceCount: 1).contains("1 issue"))
}
```

- [ ] **Step 2: Run health tests to verify they fail**

Run:

```sh
swift test --filter CoreAudioDiscoveryBackendTests/testStatusMessageIncludesTapFailures
```

Expected: compile failure for missing health path.

- [ ] **Step 3: Run startup cleanup once**

In `CoreAudioDiscoveryBackend.init`, call:

```swift
CoreAudioAggregateCrashGuard.install()
CoreAudioOrphanedAggregateCleanup.destroyOrphans()
```

Guard both calls so they run once per process.

- [ ] **Step 4: Expose health to UI**

`CoreAudioDiscoveryBackend.statusMessage` should include:

- app count
- device count
- active tap count
- issue count

Add a compact `AudioControlStore` health string or reuse `statusMessage` for the popup banner. Keep refresh errors non-fatal and preserve existing settings.

- [ ] **Step 5: Run health tests**

Run:

```sh
swift test --filter CoreAudioDiscoveryBackendTests/testStatusMessageIncludesTapFailures
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 6: Unsupported App And Ignore Policy

**Files:**
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Modify: `Sources/Auralis/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`
- Test: `Tests/AuralisTests/CoreAudioTapLifecycleTests.swift`

- [ ] **Step 1: Write ignore teardown test**

Add:

```swift
func testIgnoringAppStopsActiveTapAndKeepsSettings() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let backend = MockAudioBackend(apps: [
        AudioAppSnapshot(identity: music, displayName: "Music", bundleIdentifier: music.rawValue)
    ])
    let store = try makeStore(backend: backend)
    try store.refresh()
    try store.setVolume(0.4, for: music)

    try store.ignore(music)

    XCTAssertTrue(store.settings.ignoredAppIDs.contains(music))
    XCTAssertEqual(store.settings.appSettings[music]?.volume, 0.4)
}
```

- [ ] **Step 2: Make ignore command explicit**

Add backend commands:

```swift
case ignore(AudioAppIdentity)
case unignore(AudioAppIdentity)
```

Forward these from `AudioControlStore.ignore` and `AudioControlStore.unignore`.

Tap manager behavior:

- `ignore` stops and removes active controller immediately
- `unignore` clears failed state and allows next reconcile to start a tap
- settings remain stored

- [ ] **Step 3: Run ignore policy tests**

Run:

```sh
swift test --filter AudioControlStoreTests/testIgnoringAppStopsActiveTapAndKeepsSettings
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

## Task 7: Soak Checklist And Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- startup orphan aggregate cleanup
- crash aggregate tracking
- retry cap and failure health messages
- ignore/unignore tap teardown policy
- route/device churn recovery
- unsupported app handling

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter CoreAudioOrphanedAggregateCleanupTests
swift test --filter CoreAudioAggregateCrashGuardTests
swift test --filter CoreAudioTapFailurePolicyTests
swift test --filter CoreAudioTapLifecycleTests
swift test --filter CoreAudioDiscoveryBackendTests
swift test --filter AudioControlStoreTests
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

- [ ] **Step 4: Manual soak test**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Start and quit Auralis 10 times while Music or Safari plays audio.
- Switch default output 20 times between built-in output and another output.
- Connect and disconnect a USB or Bluetooth output while one app is routed to it.
- Ignore an active app and confirm it returns to normal macOS output.
- Unignore the app and confirm controls resume after refresh.
- Force quit Auralis, relaunch, and confirm orphan cleanup restores normal audio.
- Confirm status message reports active taps and issues.
- Confirm no Auralis aggregate devices remain after normal quit.

## Review Notes

Phase 6 is a hardening phase, not a feature expansion. The exit gate is predictable recovery under churn. Do not add presets, hotkeys, input controls, multi-output routing, or device inspector work here.
