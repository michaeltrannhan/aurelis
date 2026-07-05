# EQMacRep Replication Plan

## Source Application

EQMacRep replicates the architecture and user-facing control flow of FineTune:

- menu-bar-first macOS app
- app/device discovery layer
- per-app volume, mute, boost, EQ, pin, and ignore state
- JSON-backed settings
- popup controls plus settings UI
- later CoreAudio process-tap backend for real audio processing

## Build Strategy

The replica is built in layers so each flow is understandable and testable before the next layer is added.

### Phase 1: Customizable App Shell

Implemented in this project.

- SwiftUI `MenuBarExtra` app named `EQMacRep`.
- Mock backend that returns deterministic audio apps and output devices.
- Per-app volume, mute, boost, pin, ignore, and 10-band EQ state.
- Customization settings for appearance, popup density, default new-app volume, EQ gain range, volume step, and inactive app visibility.
- JSON persistence through `SettingsStore`.
- Tests for EQ behavior, customization, persistence, and app-state reconciliation.

### Phase 2: CoreAudio Discovery

Replace `MockAudioBackend.fetchSnapshot()` with a backend that observes:

- CoreAudio process objects for output-running apps.
- HAL output/input devices.
- Default-device changes.

The UI should not change because it already depends on the `AudioBackend` protocol.

### Phase 3: Process Taps And Real Controls

Add a tap backend that maps `AudioBackendCommand` values to live audio behavior:

- `setVolume`
- `setMuted`
- `setBoost`
- `setEQ`

The first implementation should support one output device and follow-default routing before adding multi-device routing.

### Phase 4: Feature Parity Expansion

Add FineTune-like advanced features after the realtime path is stable:

- single-device and multi-device routing
- realtime EQ DSP
- media-key interception
- HUD
- AutoEQ import/search
- loudness compensation
- DDC display volume
- packaging, signing, and updates

## Current Architecture

`EQMacRepApp` composes:

1. `SettingsStore`
2. `MockAudioBackend`
3. `AudioControlStore`
4. SwiftUI menu-bar and settings views

The core data flow is:

1. Backend produces app/device snapshots.
2. `AudioControlStore` reconciles snapshots with persisted settings.
3. Views render `displayRows`.
4. User actions update `AudioControlStore`.
5. The store persists JSON and forwards backend commands.

## Extension Points

- Add real discovery by conforming to `AudioBackend`.
- Add realtime audio by handling `AudioBackendCommand`.
- Add more customization by extending `AppCustomization`, then exposing it in `SettingsView`.
- Add tests before each behavior change to keep the flows understandable.
