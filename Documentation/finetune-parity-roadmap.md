# FineTune Parity Roadmap

This roadmap splits EQMacRep into reviewable, trackable phases to reach FineTune-like behavior before adding new extensions. Each phase should become its own implementation plan after review.

Track phase status and active goal state in `Documentation/phase-tracker.md`.

## References

- FineTune repository scope: menu-bar macOS app for per-app volume, multi-device output, audio routing, and 10-band EQ.
  <https://github.com/ronitsingh10/FineTune>
- FineTune release notes used for parity targets: input devices, multi-output routing, pinned apps, hotkeys, HUD, settings tabs, loudness, AutoEQ, DDC, device inspector, URL automation, and updates.
  <https://github.com/ronitsingh10/FineTune/releases>
- FineTune troubleshooting note: ignored apps should tear down process taps and return to normal macOS routing.
  <https://github.com/ronitsingh10/FineTune/blob/main/guide/troubleshooting.md>

## Current State

- [x] SwiftUI menu-bar shell
- [x] Mock backend
- [x] Per-app volume, mute, boost, pin, ignore, and EQ state
- [x] JSON persistence
- [x] Backend picker
- [x] CoreAudio discovery for output apps and output devices
- [ ] Live discovery listeners
- [ ] Permission flow
- [ ] Process taps
- [ ] Real audio mutation
- [ ] Routing
- [ ] Packaging

## Parallelization Model

Some work can run in parallel, but only after shared interfaces are reviewed.

- Track A, CoreAudio backend: permissions, taps, real volume, real EQ, routing. Mostly sequential because each phase depends on tap lifecycle correctness.
- Track B, UI and settings: settings tabs, popup polish, keyboard navigation, HUD, menu bar icon. Can run parallel after Track A exposes stable state models.
- Track C, devices and inputs: device inspector, input devices, DDC/software volume. Can run parallel after device model is expanded.
- Track D, distribution: signing, notarization, Sparkle updates, crash diagnostics. Can run parallel after app architecture stabilizes.

Do not parallelize two tasks that both edit tap lifecycle, route switching, or DSP graph ownership.

## Phase 0: Discovery Stabilization

**Goal:** Make current CoreAudio Discovery mode reliable enough to build taps on top.

**Status:** Partly done.

**Acceptance criteria:**

- [ ] Real output apps appear without manual relaunch after app starts.
- [ ] Real output devices refresh on connect, disconnect, and default-device change.
- [ ] Helper processes coalesce into stable parent app identities.
- [ ] Obvious Apple/system daemons stay hidden.
- [ ] Discovery errors show useful status without crashing popup.
- [ ] Mock mode still works.
- [ ] `swift test` and `swift build` pass.

**Parallelizable:** UI copy/docs can run parallel. CoreAudio listener work should stay single-threaded.

## Phase 1: Permissions And Safety Shell

**Goal:** Add first-launch permission flow for Screen & System Audio Recording and safe fallback states.

**Acceptance criteria:**

- [ ] App detects permission state.
- [ ] First launch shows clear banner/action when permission is missing.
- [ ] User can open System Settings from app.
- [ ] Denied permission leaves app usable in mock/discovery-only mode.
- [ ] Backend never attempts taps without permission.
- [ ] Permission state is reflected in popup and settings.
- [ ] Tests cover permission-state mapping and store status.

**Parallelizable:** UI banner/settings copy can run parallel with permission service after service interface is agreed.

## Phase 2: Process Tap Lifecycle Foundation

**Goal:** Create, start, stop, and tear down process taps without changing audio yet.

**Acceptance criteria:**

- [ ] Tap manager creates one tap per eligible app.
- [ ] Tap manager skips ignored apps.
- [ ] Tap manager filters unsupported apps safely.
- [ ] Stop order is explicit and tested.
- [ ] App termination tears down all taps.
- [ ] Device switch or app disappearance tears down stale taps.
- [ ] No real gain, mute, boost, EQ, or routing applied yet.
- [ ] Manual test confirms system audio returns to normal after quit.

**Parallelizable:** None for tap lifecycle internals. Docs/manual test checklist can run parallel.

## Phase 3: Real Per-App Volume, Mute, And Boost

**Goal:** Make existing volume, mute, and boost controls affect real app audio on one output path.

**Acceptance criteria:**

- [ ] `setVolume` changes real audio level.
- [ ] `setMuted` silences and restores real audio.
- [ ] `setBoost` supports configured boost levels up to 4x.
- [ ] Gain is smoothed enough to avoid obvious clicks.
- [ ] Gain staging prevents extreme clipping where practical.
- [ ] Persisted state is applied when app starts playing.
- [ ] Ignored app returns to normal macOS audio path.
- [ ] Manual test covers Music/Safari/browser helper app.

**Parallelizable:** Popup icon/slider polish can run parallel after command semantics are stable.

## Phase 4: Realtime 10-Band EQ

**Goal:** Apply stored EQ curves to real tapped app audio.

**Acceptance criteria:**

- [ ] 10-band EQ runs in realtime on audio render path.
- [ ] EQ bypass/reset works.
- [ ] Gain range settings apply to live processing.
- [ ] EQ changes update without rebuilding whole app state.
- [ ] DSP code avoids allocations on realtime path.
- [ ] Tests cover coefficient generation and curve mapping.
- [ ] Manual test confirms audible EQ change and no obvious crackle.

**Parallelizable:** Preset UI can start only after EQ model and DSP API are stable.

## Phase 5: Single-Device Routing

**Goal:** Route each tapped app to one selected output device, with follow-default as baseline.

**Acceptance criteria:**

- [ ] App route can follow default output device.
- [ ] App route can select one specific output device.
- [ ] Device changes are reflected in route validity.
- [ ] Missing selected device falls back safely.
- [ ] Switching route has safe teardown/rebuild order.
- [ ] UI clearly shows selected route per app.
- [ ] Manual test confirms two apps can target different devices.

**Parallelizable:** Device picker UI can run parallel after route model is agreed.

## Phase 6: Stability, Recovery, And Unsupported Apps

**Goal:** Make real-audio mode robust enough for daily use.

**Acceptance criteria:**

- [ ] Rapid device switching does not leak taps or aggregates.
- [ ] App start/quit cycles do not leave dead taps.
- [ ] Ignored apps clear taps and settings according to chosen policy.
- [ ] DAWs, VoIP tools, and low-level audio apps can be ignored safely.
- [ ] Backend reports recoverable failures in UI.
- [ ] Shutdown path is deterministic.
- [ ] Manual soak test passes for several app/device changes.

**Parallelizable:** Troubleshooting docs and ignore/edit-mode UI can run parallel.

## Phase 7: Popup And Settings Parity

**Goal:** Bring core UI closer to FineTune usability before advanced audio features.

**Acceptance criteria:**

- [ ] Settings has General, Audio, Shortcuts, Updates, About tabs.
- [ ] Popup fits small laptop screens.
- [ ] Keyboard navigation works: arrows, Return/Space, Escape, mute shortcut.
- [ ] Scroll-wheel volume works on sliders.
- [ ] App/device names have truncation and tooltips.
- [ ] Edit mode supports hide/ignore and reorder.
- [ ] Theme and popup size apply live.

**Parallelizable:** Yes. Mostly independent from CoreAudio if models are stable.

## Phase 8: Media Keys, Hotkeys, HUD, And Menu Bar Icon

**Goal:** Add system-feeling controls outside the popup.

**Acceptance criteria:**

- [ ] App volume up/down hotkeys target audible app first, frontmost app fallback.
- [ ] App mute hotkey works.
- [ ] Toggle popup hotkey works.
- [ ] Holding volume hotkey ramps smoothly.
- [ ] Volume-up auto-unmutes muted target.
- [ ] HUD shows current target and level.
- [ ] Menu bar icon reflects current device/output state.

**Parallelizable:** Hotkey service and HUD UI can run parallel after target-selection API is agreed.

## Phase 9: Input Device Control

**Goal:** Add FineTune-like input device visibility and controls.

**Acceptance criteria:**

- [ ] Input devices discovered and shown in separate tab.
- [ ] Input level and mute state displayed.
- [ ] Input gain/mute controls work when hardware supports them.
- [ ] Bluetooth codec downgrade risk is handled or explicitly avoided.
- [ ] Virtual input devices are classified correctly.
- [ ] Output and input tabs do not confuse route controls.

**Parallelizable:** Can run parallel with output routing after shared device model expands.

## Phase 10: Multi-Device Output

**Goal:** Support routing one app to multiple output devices.

**Acceptance criteria:**

- [ ] Multi-output route mode exists per app.
- [ ] User can select multiple output devices.
- [ ] Aggregate device creation and teardown are deterministic.
- [ ] Device drift/sync problems are handled or surfaced.
- [ ] Multi-output badge appears in app row.
- [ ] Single-device route still works.
- [ ] Manual test confirms one app plays on two devices.

**Parallelizable:** UI picker can run parallel after aggregate manager API is agreed. Backend internals should stay single-owner.

## Phase 11: EQ Presets And AutoEQ

**Goal:** Add reusable EQ workflows after realtime EQ is stable.

**Acceptance criteria:**

- [ ] Built-in EQ presets.
- [ ] User presets can save, rename, delete.
- [ ] Preset names validate.
- [ ] AutoEQ profiles can be imported or searched.
- [ ] Applying profile updates app EQ curve and live DSP.
- [ ] Invalid profile data is rejected with clear UI.

**Parallelizable:** Preset storage/UI and AutoEQ import parser can run parallel.

## Phase 12: Loudness And Device Volume Enhancements

**Goal:** Add later FineTune audio enhancements.

**Acceptance criteria:**

- [ ] Loudness compensation toggle exists and defaults off.
- [ ] Loudness equalization has target level and limiter/compressor safety.
- [ ] Alert volume reads and writes macOS alert volume.
- [ ] Software device volume supports devices without hardware volume.
- [ ] Hardware volume, software volume, and DDC controls are clearly distinguished.
- [ ] DDC monitor volume auto-detects supported displays and handles hot-plug.

**Parallelizable:** Alert volume, software volume, and DDC can run in parallel if device-control ownership is split.

## Phase 13: Device Inspector, Automation, And Distribution

**Goal:** Finish app-quality features needed for a FineTune-like release.

**Acceptance criteria:**

- [ ] Device inspector shows sample rate, transport, format, UID, and hog-mode status.
- [ ] Sample-rate picker works where supported.
- [ ] URL automation supports set volume, step volume, mute, route, and reset.
- [ ] App has signing and notarization path.
- [ ] Sparkle or chosen updater works.
- [ ] Release checklist covers permissions, quit cleanup, upgrades, and rollback.

**Parallelizable:** Automation and distribution can run parallel with device inspector after public command model is stable.

## Extension Backlog After FineTune Parity

Do not start these until parity phases are reviewed.

- [ ] Per-app stereo panning.
- [ ] Per-app profiles by workspace/time/device.
- [ ] Audio activity history.
- [ ] CLI companion.
- [ ] Shortcuts actions beyond URL scheme.
- [ ] Advanced metering/spectrum view.
- [ ] Cloud sync for presets.

## Review Decision Needed

Approve or edit these before implementation planning:

- [ ] Phase boundaries.
- [ ] Priority order.
- [ ] Which phases can be parallelized.
- [ ] Minimum viable parity target.
- [ ] Whether packaging/update work belongs before or after advanced audio.
