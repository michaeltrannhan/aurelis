# EQMacRep Flow Notes

## FineTune Flow Being Replicated

FineTune launches as a menu-bar app, creates long-lived app services, requests Screen & System Audio Recording permission, discovers CoreAudio apps and devices, creates process taps, applies persisted per-app settings, and renders controls in a menu-bar popup.

EQMacRep keeps that shape but starts with a mock backend. This makes the UI, persistence, and state transitions visible before adding realtime audio code.

## Launch Flow

1. `EQMacRepApp` creates a `SettingsStore`.
2. It creates a `MockAudioBackend` with deterministic app/device snapshots.
3. It creates an `AudioControlStore`, loading JSON settings or defaults.
4. The menu-bar extra opens `MenuBarRootView`.
5. The popup calls `refresh()`, which reconciles backend apps with persisted settings.

## Discovery Flow

First build:

1. `MockAudioBackend.fetchSnapshot()` returns mock apps and output devices.
2. `AudioControlStore.refresh()` stores snapshots in memory.
3. New apps receive default settings from `AppCustomization`.

Later CoreAudio build:

1. A CoreAudio backend observes `kAudioHardwarePropertyProcessObjectList`.
2. Helper processes are mapped to responsible apps.
3. Device changes are read from HAL device-list/default-device properties.
4. The backend emits the same snapshot shape used by the mock backend.

## App State Flow

1. UI actions call `AudioControlStore` methods.
2. The store updates `PersistedSettings`.
3. The store saves JSON through `SettingsStore`.
4. The store forwards supported commands to the backend.
5. `displayRows` is rebuilt from snapshots plus pinned/ignored state.

Pinned apps stay visible when inactive. Ignored apps are hidden and are the future place where real CoreAudio taps will be torn down.

## EQ Flow

The first build stores a 10-band `EQCurve` per app. Gains are normalized to exactly 10 bands and clamped to the selected range: 6 dB, 12 dB, or 18 dB.

Later, a realtime EQ processor can consume the same `EQCurve` values when a process tap is active.

## Persistence Flow

`SettingsStore` reads and writes a versioned `PersistedSettings` JSON document. Missing files load defaults. Malformed files also load defaults so the app remains usable; the next successful save writes valid JSON to the configured settings path.

## Customization Flow

`SettingsView` edits `AppCustomization`. Changing EQ range reclamps existing app EQ curves. Popup density changes row sizing and width. Default new-app volume affects apps first seen after the change.

## Routing Flow

The first build records routing intent through `DeviceRoute`, but the UI focuses on follow-default behavior and mock output devices. Real routing belongs to the later process-tap and aggregate-device phase.
