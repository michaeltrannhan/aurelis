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

- real app/device discovery
- permission flow
- process taps
- real per-app volume, mute, boost
- realtime 10-band EQ
- follow-default plus single-device routing
- safe teardown and recovery
- popup/settings usable enough for daily use

Advanced parity after minimum viable parity:

- hotkeys/HUD
- input device controls
- multi-device output
- AutoEQ/presets
- loudness/DDC/device inspector
- automation/distribution

## Phase Table

| Phase | Name | Status | Depends On | Parallel Lane | Exit Gate |
| --- | --- | --- | --- | --- | --- |
| 0 | Discovery Stabilization | Planned | Backend discovery implementation | Track A | Live refresh and stable app/device identity |
| 1 | Permissions And Safety Shell | Planned | Phase 0 | Track A/B | Permission missing/denied/granted states are safe |
| 2 | Process Tap Lifecycle Foundation | Planned | Phase 1 | Track A | Taps create/stop/tear down without audio mutation |
| 3 | Real Per-App Volume, Mute, And Boost | Planned | Phase 2 | Track A | Existing controls affect real audio safely |
| 4 | Realtime 10-Band EQ | Planned | Phase 3 | Track A | EQ applies live with realtime-safe DSP |
| 5 | Single-Device Routing | Planned | Phase 4 | Track A/C | Apps can follow default or route to one device |
| 6 | Stability, Recovery, And Unsupported Apps | Planned | Phase 5 | Track A/B | Daily-use failure handling and teardown pass soak checks |
| 7 | Popup And Settings Parity | Planned | Phase 1 service contracts | Track B | Core UI parity complete |
| 8 | Media Keys, Hotkeys, HUD, And Menu Bar Icon | Planned | Phase 3 target-selection contract | Track B | External controls work without opening popup |
| 9 | Input Device Control | Planned | Phase 0 device model expansion | Track C | Input devices discovered and controllable where supported |
| 10 | Multi-Device Output | Planned | Phase 5 | Track A/C | One app can play through multiple outputs |
| 11 | EQ Presets And AutoEQ | Planned | Phase 4 | Track B | Presets and AutoEQ profiles update live EQ |
| 12 | Loudness And Device Volume Enhancements | Planned | Phase 4, Phase 5 | Track C | Loudness, alert volume, software volume, DDC scoped and safe |
| 13 | Device Inspector, Automation, And Distribution | Planned | Phase 6 public command model | Track D | Release-quality inspector, automation, signing/update path |

## Execution Waves

### Wave 1: Make Audio Real

- Phase 0: Discovery Stabilization
- Phase 1: Permissions And Safety Shell
- Phase 2: Process Tap Lifecycle Foundation
- Phase 3: Real Per-App Volume, Mute, And Boost

Only Phase 7 UI scaffolding may run parallel here, and only after Phase 1 contracts are clear.

### Wave 2: Make Audio Useful

- Phase 4: Realtime 10-Band EQ
- Phase 5: Single-Device Routing
- Phase 6: Stability, Recovery, And Unsupported Apps

Phase 8 hotkeys/HUD and Phase 11 presets may start after their contracts are stable.

### Wave 3: Match Broader FineTune

- Phase 7: Popup And Settings Parity
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

1. Phase 0: Discovery Stabilization
2. Phase 1: Permissions And Safety Shell
3. Phase 2: Process Tap Lifecycle Foundation
4. Phase 3: Real Per-App Volume, Mute, And Boost
5. Phase 4: Realtime 10-Band EQ
6. Phase 5: Single-Device Routing
7. Phase 6: Stability, Recovery, And Unsupported Apps
8. Phase 7: Popup And Settings Parity
9. Phase 8: Media Keys, Hotkeys, HUD, And Menu Bar Icon
10. Phase 9: Input Device Control
11. Phase 10: Multi-Device Output
12. Phase 11: EQ Presets And AutoEQ
13. Phase 12: Loudness And Device Volume Enhancements
14. Phase 13: Device Inspector, Automation, And Distribution

## Active Phase

Phase 0: Discovery Stabilization

## Immediate Next Action

Review planned docs:

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

After Phase 0 approval, implement Phase 0, verify, mark Phase 0 complete, and advance active phase to Phase 1.
