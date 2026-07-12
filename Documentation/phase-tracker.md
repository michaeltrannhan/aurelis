# EQMacRep FineTune Parity Phase Tracker

This file is the goal loop state. Update it at every phase boundary.

## Loop Rule

1. Review current phase scope.
2. Write or update that phase implementation plan.
3. Implement with tests.
4. Verify with `swift test`, `swift build`, and required manual checks.
5. Mark phase complete here.
6. Re-evaluate dependencies and parallel lanes.
7. Start the next unblocked phase.
8. Repeat until Phase 13 is complete.

Do not start an audio-backend phase before all required earlier backend phases are complete. UI, docs, distribution, and parser work may run in parallel when their files and contracts do not overlap with active backend work.

## Status Key

- `Proposed`: drafted but not approved.
- `Approved`: phase boundary approved, no implementation plan yet.
- `Planned`: implementation plan exists.
- `In Progress`: active implementation.
- `Blocked`: cannot progress without user decision or external dependency.
- `Complete`: implemented and verified.

## Current Milestone

Minimum viable FineTune parity:

- real app/device discovery — live HAL listeners done (code); manual verify pending
- permission flow — done in code (detect/banner/gate); grant click verify pending
- process taps — done
- real per-app volume, mute, boost — done in code; manual audio verify pending
- realtime 10-band EQ — done in code; manual audio verify pending
- follow-default plus single-device routing — done in code; 2nd-device verify pending
- safe teardown and recovery — Phase 6 hardening done in code; soak verify pending
- popup/settings usable enough for daily use — tabbed settings + keyboard + scroll done

Advanced parity after minimum viable parity:

- hotkeys/HUD — done in code (Phase 8); Accessibility-grant verify pending
- input device controls
- multi-device output
- AutoEQ/presets
- loudness/DDC/device inspector
- automation/distribution

**MVP status:** code-complete for Phases 0–8 (`swift test`: 104 tests, 0 failures).
Not yet manually verified on real audio hardware — that is the remaining gate.

## Phase Table

| Phase | Name | Status | Depends On | Parallel Lane | Exit Gate |
| --- | --- | --- | --- | --- | --- |
| 0 | Discovery Stabilization | Complete (code; manual verify pending) | Backend discovery implementation | Track A | Live refresh and stable app/device identity |
| 1 | Permissions And Safety Shell | Complete (code; grant verify pending) | Phase 0 | Track A/B | Permission missing/denied/granted states are safe |
| 2 | Process Tap Lifecycle Foundation | Complete | Phase 1 | Track A | Taps create/stop/tear down without audio mutation |
| 3 | Real Per-App Volume, Mute, And Boost | Complete (code; audio verify pending) | Phase 2 | Track A | Existing controls affect real audio safely |
| 4 | Realtime 10-Band EQ | Complete (code; audio verify pending) | Phase 3 | Track A | EQ applies live with realtime-safe DSP |
| 5 | Single-Device Routing | Complete (code; 2nd-device verify pending) | Phase 4 | Track A/C | Apps can follow default or route to one device |
| 6 | Stability, Recovery, And Unsupported Apps | Complete (code; soak verify pending) | Phase 5 | Track A/B | Daily-use failure handling and teardown pass soak checks |
| 7 | Popup And Settings Parity | Complete (code) | Phase 1 service contracts | Track B | Core UI parity complete |
| 8 | Media Keys, Hotkeys, HUD, And Menu Bar Icon | Complete (code; grant/key verify pending) | Phase 3 target-selection contract | Track B | External controls work without opening popup |
| 9 | Input Device Control | Planned | Phase 0 device model expansion | Track C | Input devices discovered and controllable where supported |
| 10 | Multi-Device Output | Planned | Phase 5 | Track A/C | One app can play through multiple outputs |
| 11 | EQ Presets And AutoEQ | Planned | Phase 4 | Track B | Presets and AutoEQ profiles update live EQ |
| 12 | Loudness And Device Volume Enhancements | Planned | Phase 4, Phase 5 | Track C | Loudness, alert volume, software volume, DDC scoped and safe |
| 13 | Device Inspector, Automation, And Distribution | Planned | Phase 6 public command model | Track D | Release-quality inspector, automation, signing/update path |

### Implementation notes (2026-07-06 audit)

- Phases 2–4 were implemented ahead of Phases 0–1. Phase 2's tap-only boundary was skipped: the current tap manager creates full IOProc/aggregate controllers (Phase 3 scope).
- Phases 3–4 pass automated tests (`swift test`, 46 tests). Manual audio verification via `.build/EQMacRep.app` is still outstanding.
- Phase 4 uses a hardcoded 48 kHz EQ sample rate in `CoreAudioTapIOController`; dynamic stream sample rate is still TODO.
- Phase 7 has partial UI work (appearance, density, main window, EQ panel) but not tabbed settings or keyboard/scroll-wheel parity.

### Implementation notes (2026-07-07 session — COMPILED + TESTS GREEN)

Phases 0, 1, 5, 7 implemented and verified this session: `swift build` succeeds
and `swift test` reports **74 tests, 0 failures** (up from 46). Manual audio/
hardware verification (permission grant, real routing on a 2nd device, popup UX)
is still owned by the user. Phase 6 in progress next; Phase 8 after.

- **Phase 0 (Discovery):** `CoreAudioDiscoveryEventSource` (HAL listeners on
  process/device/default-output), `AudioBackendUpdatePublishing`,
  `AudioControlStore.startBackendObservation/stop` (debounced), device
  default-first `sortedSnapshots`. App starts observation in `EQMacRepApp`.
- **Phase 1 (Permissions):** `Permissions/AudioCapturePermission` +
  `AudioCapturePermissionClient`, store `permissionState` + request/refresh/open,
  **tap sync gated on `allowsProcessTaps`** (tears down instead of creating when
  denied), popup banner + Audio-tab section.
- **Phase 5 (Routing):** `.setRoute` command, `CoreAudioRouteResolver`, manager
  `setAvailableOutputUIDs/setRoute/resolvedOutputUID` with only-changed-route
  rebuild, IO controller protocolized (`CoreAudioActiveTapControlling`), per-app
  route picker in `AppRowView`, `DeviceRoute.label`.
- **Phase 7 (UI parity):** tabbed `Views/Settings/*` (General/Audio/Shortcuts/
  Updates/About), `PopupKeyboardNavModel`, `ScrollWheelStepModel` + modifier,
  `PopupDimensions.maxContentHeight`, `PersistedSettings.appDisplayOrder` +
  `moveApp`/`mergeAppDisplayOrder`, keyboard nav wired in popup.
- **Phase 6 (Stability) — code written this session, PENDING BUILD:**
  `CoreAudioOrphanedAggregateCleanup` (destroy leftover `EQMacRep-` aggregates),
  `CoreAudioAggregateCrashGuard` (signal-safe fixed-slot buffer + SIGABRT/SEGV/
  BUS/TRAP handlers, tracked in `CoreAudioTapResources`/IO controller),
  `CoreAudioTapFailurePolicy` + `CoreAudioTapHealth`, manager retry cap +
  `health` + `stopAll` + failure capture, backend startup recovery gated behind
  `runStartupRecovery` (real factory only — tests never install handlers), status
  message reports active taps + issues. New tests: cleanup/tracker/policy/
  lifecycle-retry/backend-health. Run `swift build && swift test` to confirm.
- **Phase 8 (External controls) — code written this session, PENDING BUILD:**
  Pure/tested models: `MediaKeyEventDecoder`, `AppControlTargetResolver`,
  `AppControlCommandExecutor` (volume-up auto-unmute / down auto-mute),
  `MenuBarIconState`+`VolumeBucket`, `VolumeHUDState`, `ShortcutAction` defaults,
  `AppCustomization` control fields. Live layer (manual-verify only):
  `AccessibilityPermissionService`, `MediaKeyMonitor` (CGEvent tap + watchdog),
  `GlobalHotkeyRegistrar` (Carbon), `VolumeHUDView`/`VolumeHUDWindowController`,
  `ExternalControlsCoordinator`, dynamic `MenuBarExtra` icon, Shortcuts settings
  tab. New tests: decoder/target/command/menu-icon/HUD. The Carbon + CGEvent
  interop files are the highest compile risk — run `swift build` and expect to
  iterate on interop signatures.

### Session outcome (2026-07-08)

All six targeted phases (0, 1, 5, 6, 7, 8) are **code-complete and build/test
green**: `swift build` succeeds, `swift test` reports **104 tests, 0 failures**
(up from 46). Compile fixes applied during verification: AsyncStream
`onTermination` Sendable capture, Picker `if case let` refactor, `@MainActor` on
nav model + settings binding helper, `kAXTrustedCheckOptionPrompt` global avoided
via literal key, `CoreAudioTapStartFailure: Error` conformance.

Remaining before MVP can be called closed — all owned by the user (need real
hardware / permission grants; cannot be automated):
1. Grant Screen & System Audio Recording; confirm volume/mute/boost/EQ audibly
   change on Music/Safari (Phases 3/4).
2. Live discovery: connect/disconnect an output device, launch an app — list
   updates with no relaunch (Phase 0).
3. Route two apps to two devices; disconnect selected → safe fallback (Phase 5).
4. Soak: launch/quit ×10, output switch ×20, force-quit → orphan cleanup on
   relaunch, no dead taps (Phase 6).
5. Grant Accessibility; media keys + Option+Command hotkeys hit the target app;
   HUD appears; menu-bar icon tracks volume/mute (Phase 8).

Build the debug bundle for manual checks: `bash Scripts/build-debug-app.sh` then
`open .build/EQMacRep.app`.

Not started (out of this run's scope): Phases 9–13. Phase 13 (signing/
notarization) needs an Apple Developer certificate.

## Execution Waves

### Wave 1: Make Audio Real

- Phase 0: Discovery Stabilization — **in progress**
- Phase 1: Permissions And Safety Shell — **in progress**
- Phase 2: Process Tap Lifecycle Foundation — **complete**
- Phase 3: Real Per-App Volume, Mute, And Boost — **complete**

Only Phase 7 UI scaffolding may run parallel here, and only after Phase 1 contracts are clear.

### Wave 2: Make Audio Useful

- Phase 4: Realtime 10-Band EQ — **complete**
- Phase 5: Single-Device Routing — **next backend priority**
- Phase 6: Stability, Recovery, And Unsupported Apps

Phase 8 hotkeys/HUD and Phase 11 presets may start after their contracts are stable.

### Wave 3: Match Broader FineTune

- Phase 7: Popup And Settings Parity — **in progress**
- Phase 8: Media Keys, Hotkeys, HUD, And Menu Bar Icon
- Phase 9: Input Device Control
- Phase 10: Multi-Device Output
- Phase 11: EQ Presets And AutoEQ

Run as parallel tracks only with disjoint file ownership.

### Wave 4: Release Polish

- Phase 12: Loudness And Device Volume Enhancements
- Phase 13: Device Inspector, Automation, And Distribution

These should not block minimum viable parity.

## Next Phase Queue

1. Phase 0: Discovery Stabilization — finish live HAL listeners and device sort stability
2. Phase 1: Permissions And Safety Shell — permission model, banner, tap gate
3. Phase 5: Single-Device Routing — `setRoute`, resolver, per-app device picker
4. Phase 6: Stability, Recovery, And Unsupported Apps
5. Phase 7: Popup And Settings Parity — settings tabs, keyboard nav, scroll-wheel volume
6. Phase 8: Media Keys, Hotkeys, HUD, And Menu Bar Icon
7. Phase 9: Input Device Control
8. Phase 10: Multi-Device Output
9. Phase 11: EQ Presets And AutoEQ
10. Phase 12: Loudness And Device Volume Enhancements
11. Phase 13: Device Inspector, Automation, And Distribution

Phases 2–4 are complete in code but still need manual audio verification before treating MVP audio as closed.

## Active Phase

Phase 0: Discovery Stabilization and Phase 1: Permissions And Safety Shell

Run these in parallel where file ownership is disjoint: Phase 0 touches `CoreAudioDiscoveryEventSource` and store observation; Phase 1 touches `Permissions/` and popup/settings banner UI.

## Immediate Next Action

1. **Phase 0:** Implement `CoreAudioDiscoveryEventSource`, `AudioBackendUpdatePublishing`, and `AudioControlStore.startBackendObservation()` per `Documentation/plans/phase-0-discovery-stabilization.md`.
2. **Phase 1:** Implement `AudioCapturePermission` domain, client, store integration, and popup/settings banner per `Documentation/plans/phase-1-permissions-safety-shell.md`. Gate tap creation on `allowsProcessTaps`.
3. **Manual verify Phases 3–4:** Build debug app (`Scripts/build-debug-app.sh`), grant permission, confirm volume/mute/boost/EQ on Music or Safari.
4. **Then Phase 5:** Start single-device routing per `Documentation/plans/phase-5-single-device-routing.md`.

Reference plans:

- `Documentation/plans/phase-0-discovery-stabilization.md`
- `Documentation/plans/phase-1-permissions-safety-shell.md`
- `Documentation/plans/phase-2-process-tap-lifecycle.md`
- `Documentation/plans/phase-3-real-volume-mute-boost.md`
- `Documentation/plans/phase-4-realtime-10-band-eq.md`
- `Documentation/plans/phase-5-single-device-routing.md`
- `Documentation/plans/phase-6-stability-recovery-unsupported-apps.md`
- `Documentation/plans/phase-7-popup-settings-parity.md`
- `Documentation/plans/phase-8-media-keys-hotkeys-hud-menu-icon.md`
- `Documentation/plans/phase-9-input-device-control.md`
- `Documentation/plans/phase-10-multi-device-output.md`
- `Documentation/plans/phase-11-eq-presets-autoeq.md`
- `Documentation/plans/phase-12-loudness-device-volume-enhancements.md`
- `Documentation/plans/phase-13-inspector-automation-distribution.md`
