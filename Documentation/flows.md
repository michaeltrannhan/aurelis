# EQMacRep Flow Notes

## FineTune Flow Being Replicated

FineTune launches as a menu-bar app, creates long-lived app services, requests Screen & System Audio Recording permission, discovers CoreAudio apps and devices, creates process taps, applies persisted per-app settings, and renders controls in a menu-bar popup.

EQMacRep keeps that shape with a mock backend for tests and a CoreAudio backend for real discovery. The current CoreAudio path creates private process taps for active apps, applies volume, mute, boost, and realtime 10-band EQ on a follow-default output path, and tears down taps on ignore/reset/quit. Live HAL discovery listeners, permission gating, explicit per-app routing, and stability hardening are still in progress.

## Launch Flow

1. `EQMacRepApp` creates a `SettingsStore`.
2. It loads persisted settings and reads `AppCustomization.backendMode`.
3. `AudioBackendFactory` creates either `MockAudioBackend` or `CoreAudioDiscoveryBackend`.
4. It creates an `AudioControlStore`, loading JSON settings or defaults.
5. The menu-bar extra opens `MenuBarRootView`.
6. The popup calls `refresh()`, which reconciles backend apps with persisted settings. Discovery currently refreshes on popup open and manual refresh only; live HAL listeners are planned in Phase 0.

## Discovery Flow

Mock mode:

1. `MockAudioBackend.fetchSnapshot()` returns mock apps and output devices.
2. `AudioControlStore.refresh()` stores snapshots in memory.
3. New apps receive default settings from `AppCustomization`.

CoreAudio Discovery mode:

1. `CoreAudioProcessDiscovery` reads `kAudioHardwarePropertyProcessObjectList`.
2. Each process object is mapped from PID, running-output state, bundle identifier, and `NSRunningApplication` display metadata.
3. Helper processes are coalesced into their parent app identity where CoreAudio exposes both records.
4. EQMacRep's own process and obvious CoreAudio/system daemons are filtered out.
5. The backend emits the same snapshot shape used by the mock backend and caches tap targets by app identity.
6. `CoreAudioDeviceDiscovery` reads HAL device-list and default-output properties.
7. Devices without output streams and hidden devices are filtered out.
8. The default output UID is passed to the tap manager for follow-default output.

## App State Flow

1. UI actions call `AudioControlStore` methods.
2. The store updates `PersistedSettings`.
3. The store saves JSON through `SettingsStore`.
4. The store forwards supported commands to the backend.
5. `displayRows` is rebuilt from snapshots plus pinned/ignored state.

Pinned apps stay visible when inactive. Ignored apps are hidden and any active CoreAudio tap for that app is torn down.

In CoreAudio Discovery mode, `setVolume`, `setMuted`, `setBoost`, and `setEQ` update realtime state for the active tap controller. If tap setup fails, refresh still keeps discovered rows visible and surfaces a tap setup error in the status text.

## EQ Flow

EQMacRep stores a 10-band `EQCurve` per app. Gains are normalized to exactly 10 bands and clamped to the selected range: 6 dB, 12 dB, or 18 dB.

The CoreAudio tap IO path applies the app's `EQCurve` through a stereo biquad cascade before volume, mute, boost, ramp, and limiter processing. Flat EQ curves bypass the biquad stage while still preserving the same persisted settings model.

## Persistence Flow

`SettingsStore` reads and writes a versioned `PersistedSettings` JSON document. Missing files load defaults. Malformed files also load defaults so the app remains usable; the next successful save writes valid JSON to the configured settings path.

## Customization Flow

`SettingsView` edits `AppCustomization`. Changing EQ range reclamps existing app EQ curves. Popup density changes row sizing and width. Default new-app volume affects apps first seen after the change.

Backend mode is also stored in `AppCustomization`. Changing it in Settings replaces the backend immediately, refreshes rows, and tears down old taps.

## Routing Flow

The current CoreAudio path follows the default output device when creating per-app aggregate devices. Explicit per-app routing through `DeviceRoute`, multi-output, and device-switch recovery belong to later phases.

## Permission Flow

Real process taps require macOS 14.2 or newer, Screen & System Audio Recording permission, and an app bundle with `NSAudioCaptureUsageDescription`. The debug bundle path exists (`Scripts/build-debug-app.sh`), but permission-state detection, popup/settings banner UI, and tap-creation gating are still planned in Phase 1. Until then, taps may be attempted without a permission check.

## Debug App Bundle Flow

Real process taps require macOS 14.2 or newer and an app bundle with `NSAudioCaptureUsageDescription`. Use `Scripts/build-debug-app.sh` and open `.build/EQMacRep.app` for manual audio testing. Running with `swift run EQMacRep` is useful for UI smoke tests, but it is not the correct permission path for real per-app volume.
