# Backend Discovery Implementation Plan

## Decision

The next backend phase should implement **real CoreAudio discovery only**:

- real output app discovery
- real output device discovery
- backend selection between mock and CoreAudio discovery
- UI/state reconciliation using the existing `AudioBackend` protocol

This phase must **not** create process taps, mute apps, reroute audio, or apply realtime EQ yet. Those actions are the riskier part of the project and should come after discovery is stable.

## Why This Phase Comes First

FineTune's backend has two separate responsibilities:

1. Discover apps/devices that are producing or receiving audio.
2. Create realtime process taps and mutate audio.

EQMacRep already has the app state, UI, settings, EQ model, and mock backend. The next useful step is to replace fake snapshots with real CoreAudio snapshots while leaving the app-control commands as no-ops. That gives a functional, visible improvement without risking broken or silent system audio.

## Test Balance

The goal is functional progress first, with only the tests that protect expensive-to-debug boundaries.

For this phase, do **not** add a large test suite. Add only:

- parser/mapper tests for converting raw discovery records into `AudioAppSnapshot`
- mapper tests for converting raw device records into `AudioDeviceSnapshot`
- a store-level test that backend selection still lets mock mode work

Do manual verification for real CoreAudio discovery by running the app and confirming real apps/devices appear.

## User-Facing Scope

After this phase:

- Settings has a backend mode picker: `Mock` or `CoreAudio Discovery`.
- Mock mode behaves exactly as it does today.
- CoreAudio Discovery mode shows real output-running apps when available.
- CoreAudio Discovery mode shows real output devices.
- Per-app sliders, mute, boost, and EQ still persist state, but do not affect real audio yet.
- The popup status explains that real controls are not active until the process-tap phase.

## Architecture

### Backend Mode

Add a persisted backend selection:

```swift
enum BackendMode: String, CaseIterable, Codable, Identifiable {
    case mock
    case coreAudioDiscovery
}
```

Add `backendMode` to `AppCustomization` or a small `BackendSettings` model. Keeping it in `AppCustomization` is acceptable for now because Settings already owns app behavior preferences.

### Backend Factory

Add a small factory so `EQMacRepApp` does not hardcode one backend:

```swift
enum AudioBackendFactory {
    static func makeBackend(mode: BackendMode) -> any AudioBackend
}
```

For this phase:

- `.mock` returns `MockAudioBackend`.
- `.coreAudioDiscovery` returns `CoreAudioDiscoveryBackend`.

Because backend mode is persisted, the app should choose the backend on launch from loaded settings.

### CoreAudioDiscoveryBackend

Create:

```text
Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift
Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessDiscovery.swift
Sources/EQMacRep/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift
Sources/EQMacRep/Audio/CoreAudio/CoreAudioPropertyReader.swift
```

Responsibilities:

- `CoreAudioDiscoveryBackend`: conforms to `AudioBackend`; combines process and device discovery.
- `CoreAudioProcessDiscovery`: reads CoreAudio process objects and resolves display names.
- `CoreAudioDeviceDiscovery`: reads HAL output devices and default output.
- `CoreAudioPropertyReader`: small typed helpers around `AudioObjectGetPropertyData`.

### Command Behavior

In this phase, `CoreAudioDiscoveryBackend.apply(_:)` should not mutate system audio. It should accept commands and record/log that the command is pending for the future tap phase.

This lets the existing UI keep working:

- volume persists
- mute persists
- boost persists
- EQ persists

But real sound remains unchanged until the process-tap phase.

## Discovery Flow

### App Discovery

1. Read `kAudioHardwarePropertyProcessObjectList`.
2. For each process object:
   - read PID
   - check whether process is running
   - read bundle identifier when available
   - resolve `NSRunningApplication` by PID
   - use localized app name when available
   - use bundle identifier as stable identity when available
   - fall back to `name:<displayName>`
3. Filter out EQMacRep's own process.
4. Filter obvious CoreAudio/system daemons.
5. Emit `AudioAppSnapshot` values.

This does not need FineTune's full helper-process responsibility mapping yet. Add that later if browser helper apps appear poorly.

### Device Discovery

1. Read `kAudioHardwarePropertyDevices`.
2. For each device:
   - read UID
   - read name
   - check output stream support
   - skip hidden devices when the property is available
3. Read `kAudioHardwarePropertyDefaultOutputDevice`.
4. Mark the matching `AudioDeviceSnapshot.isDefault`.

## Implementation Tasks

### Task 1: Backend Mode

Files:

- `Sources/EQMacRep/Domain/AppCustomization.swift`
- `Sources/EQMacRep/EQMacRepApp.swift`
- `Sources/EQMacRep/Views/SettingsView.swift`
- `Tests/EQMacRepTests/CustomizationTests.swift`

Steps:

1. Add `BackendMode`.
2. Persist it through `AppCustomization`.
3. Add the Settings picker.
4. Add one lightweight test that default mode is `.mock`.

### Task 2: Backend Factory

Files:

- `Sources/EQMacRep/Audio/AudioBackendFactory.swift`
- `Tests/EQMacRepTests/AudioBackendFactoryTests.swift`

Steps:

1. Add factory method.
2. Return `MockAudioBackend` for `.mock`.
3. Return `CoreAudioDiscoveryBackend` for `.coreAudioDiscovery`.
4. Add a minimal test for mock factory creation.

### Task 3: CoreAudio Property Helpers

Files:

- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioPropertyReader.swift`

Steps:

1. Add typed helpers for scalar values, arrays, strings, and booleans.
2. Keep helpers small and synchronous.
3. Do not add a broad HAL abstraction yet.

Testing:

- No unit test required unless helpers are split into pure mapping functions.
- Rely on build plus manual discovery verification.

### Task 4: Device Discovery

Files:

- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDeviceDiscovery.swift`
- `Tests/EQMacRepTests/CoreAudioMappingTests.swift`

Steps:

1. Add a pure `mapDeviceRecord` function.
2. Test mapping and default-device marking with fake records.
3. Add real CoreAudio enumeration method.
4. Filter devices without output streams.

### Task 5: Process Discovery

Files:

- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessDiscovery.swift`
- `Tests/EQMacRepTests/CoreAudioMappingTests.swift`

Steps:

1. Add a pure `mapProcessRecord` function.
2. Test identity fallback and self-process filtering with fake records.
3. Add real CoreAudio process enumeration.
4. Filter obvious system daemons.

### Task 6: CoreAudioDiscoveryBackend

Files:

- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioDiscoveryBackend.swift`

Steps:

1. Compose process and device discovery.
2. Return `AudioBackendSnapshot`.
3. Accept commands as discovery-phase no-ops.
4. Surface discovery errors through `AudioControlStore.statusMessage`.

### Task 7: App Wiring

Files:

- `Sources/EQMacRep/EQMacRepApp.swift`
- `Sources/EQMacRep/State/AudioControlStore.swift`
- `Documentation/flows.md`

Steps:

1. Load settings before backend creation.
2. Create backend through `AudioBackendFactory`.
3. Allow backend mode change to require app relaunch or add a simple "Restart app to apply backend mode" message.
4. Update docs with CoreAudio discovery flow.

For the first pass, relaunch-required is acceptable and simpler.

## Manual Verification

Run:

```sh
swift test
swift build
swift run EQMacRep
```

Then:

1. Open Settings.
2. Switch backend mode to `CoreAudio Discovery`.
3. Relaunch the app if required.
4. Play audio in Music, Safari, or another app.
5. Open EQMacRep popup.
6. Confirm real app names appear.
7. Confirm real output devices appear.
8. Move sliders and toggle EQ to confirm state persists after app restart.
9. Confirm real system audio is not changed yet.

## Stop Condition

Stop this phase when:

- CoreAudio mode shows real apps/devices.
- Mock mode still works.
- Existing state controls still persist.
- No process taps or realtime audio mutation have been added.
- `swift test` and `swift build` pass.

## Next Phase After Review

After this plan is approved and implemented, the next plan should cover process taps:

- permission prompt
- tap creation
- tap teardown
- applying volume/mute/boost
- safe failure and fallback behavior
- one-output-device only
