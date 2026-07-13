# EQMacRep Flow Notes

## FineTune Flow Being Replicated

FineTune launches as a menu-bar app, creates long-lived app services, requests Screen & System Audio Recording permission, discovers CoreAudio apps and devices, creates process taps, applies persisted per-app settings, and renders controls in a menu-bar popup.

EQMacRep keeps that shape with a mock backend for tests and a CoreAudio backend for real discovery. The current CoreAudio path creates private process taps for active apps, applies volume, mute, boost, realtime 10-band EQ, and explicit single- or multi-device routing, and tears down taps on ignore/reset/quit. Live HAL listeners, permission gating, and stability hardening are implemented; real-hardware verification remains required.

## Launch Flow

1. `EQMacRepApp` creates a `SettingsStore`.
2. It loads persisted settings and reads `AppCustomization.backendMode`.
3. `AudioBackendFactory` creates either `MockAudioBackend` or `CoreAudioDiscoveryBackend`, owned by `AudioSessionCoordinator`.
4. It creates an `AudioControlStore`, loading JSON settings or defaults through `AudioSettingsRepository`; capture permission is owned by `AudioPermissionCoordinator`.
5. The menu-bar extra opens `MenuBarRootView`.
6. The popup calls `refresh()`, which reconciles backend apps with persisted settings. Live HAL listeners debounce process/device/default-output changes into subsequent refreshes.

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
7. Devices without output streams or stable UIDs, hidden devices, and aggregate devices are filtered out so an EQMacRep aggregate cannot be selected recursively.
8. When the system default is itself a user Aggregate/Multi-Output Device, discovery expands its ordered active physical subdevice UIDs. EQMacRep-owned and nested aggregates are never routed recursively.
9. Default output UIDs and physical nominal sample rates are passed to the tap manager for follow-default routing and live topology validation.

## App State Flow

1. UI actions send nonthrowing intents to `AudioControlStore`.
2. The store updates `PersistedSettings` and forwards the matching command to the backend.
3. Once the backend accepts the command, the store saves versioned JSON through `AudioSettingsRepository` and `SettingsStore`; continuous volume/EQ gestures debounce intermediate work and flush their final value when editing ends.
4. If backend application or persistence fails, the store restores the previous route/control value and publishes an issue.
5. `displayRows` is rebuilt from snapshots plus pinned/ignored state.

Pinned apps stay visible when inactive. Ignored apps are hidden and any active CoreAudio tap for that app is torn down.

In CoreAudio Discovery mode, control intents update realtime state for the active tap controller. Failed commands roll optimistic UI state back and publish an actionable `AudioIssue`. Failed refreshes preserve the last successful rows and devices.

## EQ Flow

EQMacRep stores a 10-band `EQCurve` per app. Gains are normalized to exactly 10 bands and clamped to the selected range: 6 dB, 12 dB, or 18 dB.

The CoreAudio tap IO path applies the app's `EQCurve` through a stereo biquad cascade before volume, mute, boost, ramp, and limiter processing. Flat EQ curves bypass the biquad stage while still preserving the same persisted settings model.

## Persistence Flow

`SettingsStore` reads and writes a versioned `PersistedSettings` JSON document. Missing files load defaults. Malformed files also load defaults so the app remains usable; the next successful save writes valid JSON to the configured settings path.

On the first refresh for each discovered app, non-default persisted route and DSP state are replayed into the backend before tap synchronization. A restored tap therefore starts on its saved outputs instead of briefly starting on the system default.

## Customization Flow

`SettingsView` edits `AppCustomization`. Changing EQ range reclamps existing app EQ curves. Popup density changes row sizing and width. Default new-app volume affects apps first seen after the change.

Backend mode is also stored in `AppCustomization`. Debug builds can switch it; production builds keep the selector hidden.

## Routing Flow

Each app can follow the system default, select one output UID, or store an ordered multi-output UID list. Route normalization removes duplicates while preserving order; the first available selected device is the aggregate's main/clock device.

For multi-output, `CoreAudioProcessTapManager` resolves the stored list against currently available devices and creates one private, stacked aggregate containing the process tap and every resolved output. A stacked aggregate mirrors the same processed stream to every subdevice; a non-stacked aggregate concatenates channels and does not mirror. HAL reconciles differing nominal sample rates inside the aggregate (the clock device sets the aggregate rate), so no upfront rate validation is needed — the controller reads the aggregate's actual nominal rate after creation for DSP coefficients. Drift compensation is disabled for the clock device and enabled for each follower. After aggregate creation the controller verifies active membership by device UID. An inactive set fails with a visible route issue instead of silently playing through only some devices.

The controller reads the aggregate's nominal sample rate before starting IO, observes subsequent rate changes, and serializes EQ/gain updates with the Core Audio render queue. HAL listeners also observe physical nominal-rate and aggregate-composition changes. The manager includes sample rates in its resolved topology signature, so a rate change safely rebuilds and revalidates an otherwise unchanged UID set.

Route-set changes rebuild the controller outside the realtime callback. Missing or inactive members are skipped while remaining selected devices continue; if all selected devices disappear, routing falls back to the current default. A failed user-initiated rebuild keeps the previous controller and route active and publishes an issue. Automatic failures use bounded backoff and retry after topology changes; selecting a route is an immediate explicit retry. The picker stages checklist edits and applies them together to avoid rebuilding once per click.

## Permission Flow

Real process taps require macOS 14.2 or newer, Screen & System Audio Recording permission, and an app bundle with `NSAudioCaptureUsageDescription`. First-run guidance explains the requirement, popup/settings surfaces expose permission actions, and tap creation is gated safely. Accessibility remains optional and is only required for media-key control.

## Debug App Bundle Flow

Real process taps require macOS 14.2 or newer and an app bundle with `NSAudioCaptureUsageDescription`. Use `Scripts/build-debug-app.sh` and open `.build/EQMacRep.app` for manual audio testing. The script requires a persistent certificate-backed code-signing identity (auto-selecting the first valid identity, or accepting `SIGN_IDENTITY=...`) so TCC recognizes rebuilt bundles. Running with `swift run EQMacRep` is useful for UI smoke tests, but it is not the correct permission path for real per-app volume.
