# Auralis Implementation Plan

## Task 1: Package And Docs

- Create SwiftPM executable target `Auralis`.
- Create XCTest target `AuralisTests`.
- Add README, license note, flow notes, and replication plan.
- Verify with `swift build`.

## Task 2: Domain Layer

- Implement `EQGainRange`, `EQCurve`, and frequency labels.
- Implement `AppCustomization`, popup density, appearance, and volume step settings.
- Implement app/device identities, app snapshots, boost levels, device route, app audio settings, and display rows.
- Verify with `EQCurveTests` and `CustomizationTests`.

## Task 3: Persistence

- Implement versioned `PersistedSettings`.
- Implement `SettingsStore.load()`, `save(_:)`, and `reset()`.
- Missing settings files load defaults.
- Malformed settings files fall back to defaults.
- Verify with `SettingsStoreTests`.

## Task 4: Backend Boundary

- Implement `AudioBackend`.
- Implement `AudioBackendSnapshot`.
- Implement `AudioBackendCommand`.
- Implement `MockAudioBackend`.
- Keep this boundary stable for later CoreAudio discovery and process taps.

## Task 5: State Coordinator

- Implement `AudioControlStore`.
- Reconcile backend snapshots with persisted settings.
- Compute visible app rows.
- Support pin, unpin, ignore, unignore, volume, mute, boost, EQ gain, customization, and reset.
- Persist after every state mutation.
- Verify with `AudioControlStoreTests`.

## Task 6: SwiftUI App

- Implement `AuralisApp`.
- Implement menu-bar popup in `MenuBarRootView`.
- Implement per-app controls in `AppRowView`.
- Implement EQ editor in `EQPanelView`.
- Implement customization UI in `SettingsView`.
- Verify with `swift build`.

## Task 7: Full Verification

Run from the repository root:

```sh
swift test
swift build
```

Expected result:

- 15 tests pass.
- Debug executable builds successfully.
