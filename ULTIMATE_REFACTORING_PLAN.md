# EQMacRep Ultimate Refactoring Plan

Date of audit: 2026-07-15

This is the implementation handoff from a repository-wide manual review. The audit covered all 74 production Swift files, all 25 Swift test files, `Package.swift`, `project.yml`, product plists/entitlements, and `Scripts/build-debug-app.sh`. Documentation was intentionally excluded from the review scope.

## Starting instructions for a fresh conversation

Use this file as the source of truth. Implement the phases in order, beginning with Phase 0. Do not attempt the entire roadmap in one unreviewable change. At the start of each phase:

1. Re-read the relevant source and tests because the working tree may have changed since this audit.
2. Preserve unrelated user changes and inspect `git status` before editing.
3. Turn each phase into a small working plan with explicit tests.
4. Add regression coverage before or alongside each behavioral fix.
5. Run both SwiftPM tests and the generated Xcode app/widget build whenever applicable.
6. Do not declare a phase complete until its completion gate passes.

Suggested prompt for the next conversation:

> Read `ULTIMATE_REFACTORING_PLAN.md`, inspect the current working tree, and implement Phase 0 completely. Preserve unrelated changes, add the required tests/checks, and verify the completion gate before stopping.

## Verified audit baseline

- `swift test`: 172 tests passed, 0 failed.
- Generated Xcode Debug app and widget extension: built successfully with signing disabled.
- The real Xcode build compiled the widget, while SwiftPM currently does not.
- Signed entitlements and real app-group communication were not validated.
- Physical CoreAudio route/device behavior was not validated.
- The repository already contained modified and untracked widget/project work at audit time. Those changes belonged to the user and were not modified during the review.

Audit-time working tree:

```text
 M .gitignore
 M README.md
 M Resources/EQMacRep-Info.plist
 M Scripts/build-debug-app.sh
 M Sources/EQMacRep/EQMacRepApp.swift
?? Resources/EQMacRep.entitlements
?? Resources/EQMacRepWidget-Info.plist
?? Resources/EQMacRepWidget.entitlements
?? Sources/EQMacRep/Widget/
?? Sources/EQMacRepWidget/
?? project.yml
```

## Release blockers

- `Sources/EQMacRep/Widget/WidgetBridge.swift:131`: The watcher opens `commands.json`, then startup draining deletes the watched inode. Watch the command directory or reopen after delete/rename.
- `Sources/EQMacRep/Widget/WidgetCommandQueue.swift:39`: Atomic writes replace the file inode and invalidate the watcher after the first command.
- `Sources/EQMacRep/Widget/WidgetCommandQueue.swift:28`: Cross-process read-modify-write and drain-delete operations have no locking. Concurrent commands can be overwritten or lost.
- `Sources/EQMacRepWidget/WidgetAppIntents.swift:23`: Intents only enqueue commands and do not ensure a host is running to consume them.
- `Sources/EQMacRepWidget/WidgetMixerView.swift:83`: Device mute emits an application-mute command with a synthetic `device:` identity that the bridge cannot resolve.
- `project.yml:57`: The widget `CFBundlePackageType` is overridden to `APPL`; the built extension plist confirmed the incorrect value. It must be `XPC!`.
- `Scripts/build-debug-app.sh:21`: `grep ... || true` hides `xcodebuild` failures, allowing a stale app to be copied and reported as successful.
- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift:189`: Render code assumes the first buffer is interleaved stereo `Float32`; other layouts are corrupted or ignored.
- `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAggregateCrashGuard.swift:48`: Fatal signal handlers call non-async-signal-safe CoreAudio APIs and access non-atomic shared state.
- `Sources/EQMacRep/Domain/EQCurve.swift`: Synthesized decoding bypasses band-count and gain normalization. Short arrays crash EQ controls; long arrays can crash the widget.
- `Sources/EQMacRep/EQMacRepApp.swift:66`: Backend observation and external controls start inside `MenuBarExtra` content `.task`, so they may not start until the menu opens.
- `Sources/EQMacRep/State/AudioControlStore.swift:543`: `Dictionary(uniqueKeysWithValues:)` trusts backend and persisted identifiers and can terminate on duplicates.

## Complete finding inventory

### Widget and app-group transport

- Timeline reload happens before command application and snapshot publication, so widgets normally reload stale state.
- Snapshots older than three seconds trigger one-second polling indefinitely, even when the host app is closed.
- The fallback Application Support path cannot reliably connect an unsandboxed host and sandboxed widget. Missing app-group access must be an explicit error.
- Shared-container lookup, encoding, decoding, reading, and writing errors are swallowed.
- Snapshot and command payloads have no schema version or tolerant migration strategy.
- `commandAckURL` is declared but unused.
- `cycleBoost` accepts nonexistent identities and can create phantom persisted settings.
- Direction values are unbounded instead of using a two-case direction type.
- Snapshot encoding and filesystem work inherit `@MainActor`.
- The EQ widget claims to target the frontmost app but selects the first active/persisted app.
- Widget EQ rendering indexes a fixed frequency array using arbitrary decoded gain indices.
- Widget entry family, appearance, bundle ID, output state, gain range, `showEQButton`, and `volumeStep` contain unused or dead data paths.
- URL routing validates only the scheme and depends on a brittle window title.

### CoreAudio and real-time processing

- The render callback processes only the first buffer and does not clear all unsupported/trailing output regions.
- Mutable DSP types rely on `@unchecked Sendable` and `nonisolated(unsafe)` rather than an enforced executor contract.
- Swift arrays and reference-counted DSP state remain reachable from real-time work; allocation and ARC safety are not proven.
- Failed targets without a live session can remain in manager bookkeeping after the target disappears.
- Initial tap creation failures have no retry independent of unrelated HAL events.
- Fatal, unsupported, disabled, and recoverable failure classifications do not materially control retry behavior.
- Tap bookkeeping is deleted before destruction succeeds, losing handles needed for retry.
- `tearDownAll` aborts on the first failure instead of cleaning every resource.
- Tap resource destruction ignores `OSStatus` failures and clears IDs anyway.
- Sample-rate changes are handled both in the I/O controller and by rebuilding complete sessions.
- Placeholder taps create unnecessary resources while no output route exists.
- Rebuilds start the replacement before stopping the old muted tap, creating an unverified overlap window.
- Output-volume controller state crosses queues under `@unchecked Sendable`.
- Partial output-volume listener installation can leak the first listener when the second fails.
- Unsupported output volume/mute reads become fake `100%` and unmuted state.
- CoreAudio property-array reads assume property size is stable between size and value queries.
- Discovery events use an unbounded `AsyncStream`; listener registration errors are invisible.
- `name:<displayName>` fallback identities can merge unrelated bundleless processes.
- Helper-parent matching is quadratic and heuristic matches can attach unrelated processes.
- Physical devices inside the system-default aggregate are not represented as default-route members.
- Aggregate builder preconditions can terminate on invalid route state that should produce typed errors.
- Orphan cleanup matches by name prefix, can target unrelated aggregates, and ignores cleanup failures.
- Crash guard replaces existing signal handlers without chaining or restoration.
- Soft-limiter/ramp coefficient construction does not reject invalid sample rates or durations.
- Production app levels remain zero, making loudest-app targeting, meters, and level-derived menu state misleading.
- Backend command support is discovered through optional casts, causing silent no-ops instead of explicit capability errors.
- `Dictionary(uniqueKeysWithValues:)` can also trap on duplicate discovered process identities.
- Several CoreAudio discovery failures collapse into false/default values rather than distinguishing unsupported, unavailable, and transient failure.

### Store, persistence, and domain models

- Synchronous discovery, tap reconciliation, volume reads, and JSON saves execute from `@MainActor` refresh paths.
- Persistence errors are reported as backend errors.
- Pin, ignore, unignore, customization, reset, backend switch, and refresh use inconsistent mutation/commit/rollback ordering.
- Customization rollback covers immediate backend-switch failure but not later persistence or refresh failure.
- Shutdown ignores repository flush and tap teardown errors.
- Settings repository debounce work inherits main-actor execution.
- All settings read/decode errors silently return defaults, allowing later writes to destroy recoverable data.
- Future schema versions are treated as current and rewritten.
- Failed saves clear pending work and have no durable retry state.
- Synthesized decoding bypasses volume, route, EQ, ordering, and identity invariants.
- NaN and nonfinite input behavior is not consistently defined.
- Topology refreshes persist settings even when nothing changed.
- Continuous EQ edits are keyed by app rather than app, band, and gesture token.
- Early exits from continuous-edit flush can leave task/baseline state active.
- Gesture begin can be emitted repeatedly during one drag.
- Observation ownership and backend switching contain dead/no-op state.
- Output and tap capabilities are represented by optional runtime casts.
- App target resolution compares a display name with a frontmost bundle identifier.
- Debug backend selection is persisted into a production settings model and can be overwritten by release enforcement.
- Debug refresh writes synchronously to a fixed, unbounded `/tmp` log.
- Recovery actions and affected device IDs exist in issue models but are not wired through the UI.
- Permission state cannot reliably distinguish denied from never requested after relaunch.
- Relaunch quits the current process without confirming that opening the replacement succeeded.
- The settings URL helper assumes a returned URL exists.
- Fallback application identity strings are collision-prone and lack an explicit migration strategy.

### Lifecycle, controls, and UI

- Termination logic is registered in multiple scene locations and can run twice.
- Widget bridge starts before initial discovery, producing empty state and unresolved commands.
- Window routing relies on a title rather than a stable scene identifier.
- Accessibility permission request code is not connected to onboarding/settings.
- Menu-bar popup visibility is never maintained, so HUD suppression cannot work.
- `arrangeInFront:` does not reliably toggle a `MenuBarExtra`.
- Hotkey callbacks use unretained state and installed event handlers are not removed.
- Media-key tap creation failures and permanent flapping shutdown are not surfaced.
- Precise trackpad deltas each become a full step; zero delta becomes a decrement.
- App rows are not in a true bounded scroll area and can clip for large app lists.
- Popup layout and quick-action target models are tested but mostly unused by production views.
- Keyboard navigation state is stored as a plain property inside a SwiftUI value view and can be recreated.
- Return and Space keyboard semantics are inconsistent and can unexpectedly toggle mute.
- Output controls disappear from the main window when no application rows exist.
- Unsupported devices show enabled controls backed by fake values.
- Route Apply reports no failure and closes the editor even after rejection.
- Multi-output priority cannot be reordered except by remove/re-add.
- Onboarding Accessibility is always incomplete and offers no request action.
- Onboarding dismisses even when initial persistence fails.
- Missing usage-description configuration can be hidden behind permission presentation even though System Settings cannot repair it.
- Only the most recent issue is visibly presented, leaving other failures/actions inaccessible.
- HUD style is persisted but the classic style has no distinct implementation.
- Updates settings exposes placeholder phase text rather than a working updater.
- Missing application icons are not negatively cached, causing repeated LaunchServices work.
- Restore All performs many individual persistence and tap-reconciliation cycles.
- Output slider defaults persist on every tick rather than committing/batching an edit.
- Menu popup maximum-height calculation can exceed extremely short screens.
- EQ panel layout helpers contain unused/misnamed branches.

### Build configuration and scripts

- The documented `SIGN_IDENTITY` environment variable is unused.
- `arch=arm64` excludes Intel/universal builds.
- Script execution assumes the current directory is the repository root.
- Project, scheme, and product names are hardcoded without validation.
- Build output filtering hides warning/error context and does not preserve a complete useful log.
- Build settings are queried repeatedly.
- `xcodegen` and `xcodebuild` prerequisites are not checked.
- Final app, embedded widget, plist types, architectures, and signatures are insufficiently validated.
- Strict concurrency is set to `minimal`, hiding ownership problems in a Swift 6 project.
- The generated Xcode project has no test target/scheme.
- Team and development signing identity are hardcoded globally, including release configuration.
- Main app version values are duplicated rather than derived from shared build settings.
- Bundle IDs and app-group identifiers are repeated across YAML, plist, entitlements, and code.
- Signed app-group behavior has no smoke test.
- Host/widget sandbox assumptions are undocumented in executable validation and the fallback transport cannot bridge them.
- SwiftPM omits the widget target, so `swift test` cannot compile the widget.
- SwiftPM platform declaration and packaged deployment target are not aligned precisely.
- The URL scheme is globally registered but only minimally validated.
- There is no trustworthy release packaging/signing/notarization verification path.

### Test-suite gaps and refactoring

- No widget command queue, watcher, bridge, snapshot, intent, app-closed, or app-group tests exist.
- Crash-guard tests exercise a separate tracker rather than the production signal guard.
- Tap lifecycle tests omit initial-start retry, vanished failed targets, partial destroy failure, teardown continuation, and resource preservation.
- Tap fakes reuse fixed IDs and do not expose duplicate/overlap behavior.
- Audio tests do not construct actual multi-buffer/non-interleaved `AudioBufferList` cases.
- DSP assertions mainly prove output changes and stays finite, not correct frequency response or real-time behavior.
- Settings tests omit malformed band arrays, out-of-range values, duplicate display order, future versions, corruption quarantine, and failed-save retry.
- Store tests omit failure after backend switch, persistence compensation, shutdown failure, and several mutation transactions.
- Async observation/repository tests use fixed sleeps and can become timing-sensitive.
- Temporary test directories and fake infrastructure are duplicated and not consistently cleaned.
- The continuous volume test ends at its starting value and does not prove latest-value delivery.
- Layout-model constants are unit tested even when the production view does not use the model.
- External controls, Accessibility, hotkey lifecycle, media-tap restart, and popup behavior lack tests.
- Unsupported device capabilities and partial listener-registration failure lack tests.
- CoreAudio property topology changes between size/read lack tests.
- Widget visual/accessibility behavior and popup scrolling lack integration coverage.
- No strict-concurrency, Thread Sanitizer, sustained audio stress, or real-time allocation gate exists.
- No optional/manual physical hardware matrix exists for built-in, USB, HDMI, AirPlay, aggregate, sample-rate, permission, relaunch, and crash-recovery behavior.

## Phased implementation roadmap

### Phase 0 — Make builds and tests trustworthy

Tasks:

- [x] Remove the widget `CFBundlePackageType: APPL` override and verify the built extension is `XPC!`.
- [x] Set `APPLICATION_EXTENSION_API_ONLY=YES` on the widget target.
- [x] Add `EQMacRepTests` to the generated Xcode project and shared scheme.
- [x] Extract widget snapshot/command models into a shared target compiled by the app, widget, and tests.
- [x] Rewrite `build-debug-app.sh` with pipeline failure propagation and explicit `xcodebuild` status capture.
- [x] Preserve a full build log while still printing a concise terminal summary.
- [x] Derive repository root from the script path.
- [x] Make architecture, team, and signing identity configurable.
- [x] Validate prerequisites, generated project, product path, embedded `.appex`, plist types, versions, architectures, bundle IDs, and entitlements.
- [x] Add a Release build verification path even if distribution/notarization remains a later phase.

Completion gate:

- An intentionally broken Swift source causes the script to return nonzero.
- The widget plist is `XPC!`.
- Debug app, widget, and tests run from one generated Xcode scheme.
- SwiftPM tests still pass.
- No stale product can be reported as a successful build.

### Phase 1 — Protect persisted data and crash recovery

Tasks:

- [x] Add custom tolerant decoding for EQ, app settings, routes, ordering, identity, widget snapshots, and commands.
- [x] Normalize EQ to exactly ten finite, clamped bands at every boundary.
- [x] Normalize volume and route invariants during decode.
- [x] Dedupe backend rows and persisted display ordering without traps.
- [x] Reject future settings versions without rewriting them.
- [x] Quarantine corrupt files and expose a recovery issue while preserving the original.
- [x] Move disk operations to a persistence actor.
- [x] Retain dirty state after failed saves and retry with bounded backoff.
- [x] Replace signal-time CoreAudio destruction with a durable ownership journal.
- [x] Validate journal entries and perform best-effort cleanup on next launch.

Completion gate:

- Malformed, truncated, duplicate, nonfinite, short-EQ, long-EQ, corrupt, and future-version fixtures do not crash or overwrite originals.
- Save failure retains dirty state and succeeds after fault removal.
- Fatal signal handlers perform no CoreAudio or filesystem operations.
- Journaled aggregates are safely recovered on the next launch.

### Phase 2 — Build a deterministic tap lifecycle

Target model:

```text
absent -> desired -> starting -> running
                       |           |
                       v           v
                    retrying <- unhealthy
                       |           |
                       v           v
                     failed     stopping -> absent
```

Tasks:

- [x] Replace parallel target/session/retry dictionaries with one `TapSessionState` per identity.
- [x] Serialize every transition on one actor/executor.
- [x] Route initial and runtime recoverable failures through the same retry scheduler.
- [x] Make unsupported, disabled, permission-denied, fatal, and recoverable decisions executable.
- [x] Preserve resource handles until destruction succeeds.
- [x] Make teardown-all attempt every resource and aggregate failures.
- [x] Remove placeholder taps when no output route exists.
- [x] Define controller replacement/handover and rollback semantics.
- [x] Consolidate sample-rate handling.
- [x] Define retention/pruning rules for cached routes and gains.

Completion gate:

- Failure injection proves no desired/running/failed identity becomes orphaned in bookkeeping.
- Initial recoverable failures retry without unrelated HAL events.
- Unsupported/fatal failures do not loop.
- Teardown failures preserve handles and later retry successfully.
- Teardown-all attempts every session.

### Phase 3 — Harden real-time audio processing

Tasks:

- [x] Capture and validate stream formats during controller setup.
- [x] Support interleaved and non-interleaved `Float32`, multiple buffers, and actual channel counts.
- [x] Zero all unprocessed/remainder output regions.
- [x] Reject unsupported formats before render work begins.
- [x] Publish immutable, preallocated coefficient/state snapshots.
- [x] Remove `@unchecked Sendable` and `nonisolated(unsafe)` from mutable DSP ownership.
- [x] Ensure render code performs no allocation, locking, logging, filesystem access, or object destruction.
- [x] Add real metering or remove level-based product behavior.
- [x] Sanitize coefficient inputs.

Completion gate:

- Multi-buffer, non-interleaved, stereo-isolation, remainder, and unsupported-format tests pass.
- Known impulse and frequency-response tests pass at supported sample rates.
- Sustained processing stays finite and avoids denormal instability.
- Real-time allocation and callback-time measurements meet an explicit budget.
- Thread Sanitizer passes non-real-time ownership stress tests.

### Phase 4 — Replace widget IPC

Tasks:

- [x] Replace shared-array `commands.json` with an app-group command directory.
- [x] Write one atomic file per UUID command.
- [x] Watch the directory rather than a replaceable file inode.
- [x] Claim commands by atomic rename.
- [x] Validate and execute commands idempotently.
- [x] Write acknowledgment/result records before deleting completed work.
- [x] Add schema version, command ID, creation time, expiry, target type, target identity, and normalized action.
- [x] Add a real output-device mute command.
- [x] Decide and implement the closed-host contract: launch host, helper/XPC service, or honest disabled UI.
- [x] Reload timelines only after result snapshot/ack publication.
- [x] Poll rapidly only while a known command is pending.
- [x] Surface missing app-group access as a configuration error.
- [x] Remove unused widget fields and correct frontmost-app semantics/copy.

Completion gate:

- Concurrent enqueue/drain never loses a command.
- Watcher continues across atomic file creation/deletion.
- Duplicate delivery is harmless.
- Crash between claim and acknowledgment recovers.
- Stale/invalid commands are rejected predictably.
- Device mute works.
- App-closed behavior is explicit and tested.
- Timeline reload displays the applied result rather than stale state.

### Phase 5 — Refactor store concurrency and transactions

Tasks:

- [x] Introduce an `AudioEngineActor` for discovery, HAL events, output observation, and tap ownership.
- [x] Keep `AudioControlStore` main-actor-only and publish immutable engine snapshots to it.
- [x] Introduce a `SettingsPersistenceActor`.
- [x] Define a mutation transaction with previous state, desired state, engine work, durable commit, and compensation.
- [x] Use transactions for pin, ignore, unignore, restore-all, customization, route, backend switch, reset, and defaults.
- [x] Split backend, tap, permission, and persistence issue domains.
- [x] Coalesce topology event bursts with newest-only buffering.
- [x] Persist only dirty state.
- [x] Model output capabilities explicitly.
- [x] Create edit sessions keyed by app, control, EQ band, and gesture token.
- [x] Make shutdown one idempotent operation that flushes, stops observers, tears down all taps, and journals leftovers.

Completion gate:

- No HAL or filesystem work executes on the main actor.
- Every mutation has tested success, engine-failure, persistence-failure, and compensation behavior.
- Event bursts produce bounded refresh work.
- Shutdown attempts every cleanup step and reports/journals incomplete work.

### Phase 6 — Repair lifecycle and external controls

Tasks:

- [x] Create one `AppLifecycleCoordinator` owned from application startup.
- [x] Start discovery, permission refresh, output observation, hotkeys, media keys, and widget transport independently of scene rendering.
- [x] Centralize termination and make all stop operations idempotent.
- [x] Replace title-based window discovery with stable scene/window identifiers.
- [x] Validate exact URL routes.
- [x] Connect Accessibility request, status, and System Settings behavior to onboarding/settings.
- [x] Publish hotkey/media-key registration and operational failures.
- [x] Remove unretained callback hazards and unregister handlers/taps.
- [x] Add controlled media-tap recovery after flapping.
- [x] Confirm relaunch success before terminating the current process.

Completion gate:

- Backend events and controls work before the menu is ever opened.
- Lifecycle start/stop can be invoked repeatedly without duplication or leaks.
- Permission and registration failures are visible and recoverable.
- Popup/window commands use stable routing.

### Phase 7 — Finish product UI behavior

Tasks:

- [x] Put menu application rows in a bounded `ScrollView` using the real layout model.
- [x] Keep output-device controls independent of application rows.
- [x] Hide/disable volume and mute based on explicit capabilities.
- [x] Give keyboard navigation stable ownership and documented Return/Space behavior.
- [x] Accumulate precise trackpad deltas and ignore zero/irrelevant events.
- [x] Make route Apply result-bearing and preserve the editor on failure.
- [x] Add route reordering.
- [x] Dismiss onboarding only after persistence succeeds.
- [x] Display all relevant issues and implement every advertised recovery action.
- [x] Implement classic HUD behavior or remove the setting.
- [x] Remove the placeholder Updates tab until an updater exists.
- [x] Remove unused widget/model/layout fields and dead helpers.
- [x] Make Restore All a single transaction.
- [x] Cache icon misses and avoid repeated main-thread resolution.

Completion gate:

- Large app lists scroll and remain keyboard accessible.
- Unsupported device controls cannot be invoked.
- Failed routes/onboarding commits remain visible and actionable.
- No user setting is persisted without a corresponding behavior.
- Dead presentation models and placeholder product controls are removed.

### Phase 8 — Expand verification and release gates

Status on 2026-07-16: code-complete and automated gates green. `swift test`,
complete strict-concurrency checking, and Thread Sanitizer each pass 290 tests.
The standalone 100,000-callback audio stress gate passes, and the generated
Xcode Debug app/widget/tests plus Release app/widget both build and pass
structural validation. Apple Development-signed Debug and Release products also
pass signature, entitlement, embedding, and live cross-process app-group checks.
Developer ID notarization and the physical hardware matrix remain external
release evidence.

Tasks:

- [x] Add widget queue, bridge, schema, intent, app-group, acknowledgment, and closed-host tests.
- [x] Test production aggregate journal recovery rather than a separate tracker.
- [x] Add tap lifecycle failure-injection coverage.
- [x] Add real `AudioBufferList` layout tests.
- [x] Add DSP response, stability, denormal, allocation, and performance tests.
- [x] Add malformed/future/corrupt settings and property/fuzz tests.
- [x] Replace fixed async sleeps with injected clocks/schedulers or observable expectations.
- [x] Consolidate test builders, spies, clocks, and temporary storage cleanup.
- [x] Add external-control and permission lifecycle tests through injected OS seams.
- [x] Add popup/widget rendering and accessibility integration tests.
- [x] Enable complete strict-concurrency checking.
- [x] Add Thread Sanitizer and sustained audio stress jobs.
- [x] Define an optional/manual physical hardware matrix.
- [x] Add signed Debug/Release validation for entitlements, app-group declarations, embedding, and signatures.
- [x] Run certificate-backed Debug/Release validation and confirm live app/widget access to the same app-group container.
- [x] Add release packaging/signing/notarization verification when distribution begins.

Automated verification status (2026-07-16): SwiftPM, generated Xcode Debug/Release,
complete strict-concurrency, Thread Sanitizer, 100,000-callback stress, signed
product validation, production widget rendering, live app-group access, and
verifier fault-injection gates pass. A read-only hardware preflight also found
two physical outputs and a clean aggregate/journal starting state. Hands-on
hardware exercises, Developer ID packaging, and notarization evidence remain
pending because they require disruptive user interaction or distribution
credentials that are not available in this environment.

Completion gate:

- SwiftPM and generated Xcode test suites both pass.
- App and widget build in Debug and Release.
- Signed app and widget resolve the same app-group container.
- Strict concurrency and Thread Sanitizer gates pass.
- Widget commands have reliable app-running and app-closed behavior.
- No teardown failure loses a CoreAudio resource handle.
- Audio callback performance meets the agreed budget.
- Hardware matrix passes without stuck muted taps or orphaned aggregates.
- Build scripts fail on build, plist, embedding, architecture, signature, or entitlement mismatch.

Automated completion evidence (2026-07-16):

- `swift test`: 290 tests, 0 failures.
- `swift test -Xswiftc -strict-concurrency=complete`: 290 tests, 0 failures.
- `swift test --sanitize=thread`: 290 tests, 0 failures.
- 100,000-callback sustained render stress: passed in 46.384 seconds.
- Generated Xcode unsigned Debug build and test: 290 app tests plus 3 production
  widget rendering tests passed; embedded widget is `XPC!`.
- Generated Xcode Apple Development-signed Debug build and test: 290 app tests
  plus 4 widget tests passed, including live host app-group resolution.
- Generated Xcode unsigned and Apple Development-signed Release builds: passed
  structural validation.
- Signed app and sandboxed widget entitlement probes resolved
  `com.michaeltrannhan.EQMacRep.group` to the same container and exchanged a
  nonce across processes.
- Product verifier self-tests rejected build, plist, embedding, architecture,
  bundle-identifier, entitlement, missing-notary-configuration, signed-product
  tampering, and non–Developer ID distribution faults.
- Read-only hardware preflight on an Apple silicon laptop found built-in and
  HDMI physical outputs, zero live `EQMacRep-*` aggregates, and an empty
  production ownership journal.
- `git diff --check` and verification-script shell syntax: passed.

The requirement-by-requirement evidence audit is recorded in
`Documentation/verification/PHASE8_AUDIT.md`.

External completion evidence still required:

- Complete `Documentation/verification/HARDWARE_MATRIX.md` on physical output
  devices and permission states.
- Run Developer ID packaging, notarization, stapling, and Gatekeeper validation
  when distribution credentials are available.

## Recommended change sequence

Keep changes reviewable by using roughly this pull-request/commit sequence:

1. Trustworthy Xcode project and build script.
2. Safe model decoding and corrupt-settings preservation.
3. Durable aggregate ownership journal.
4. Tap lifecycle state machine and teardown error handling.
5. Format-aware, real-time-safe DSP pipeline.
6. Durable widget command transport and acknowledgment protocol.
7. Audio/persistence actor ownership and store transactions.
8. Application lifecycle, permissions, hotkeys, and media keys.
9. Popup, output-device, route, onboarding, issue, and settings cleanup.
10. Concurrency, performance, signed-build, widget, and hardware verification gates.

Do not combine the tap lifecycle, DSP rewrite, widget transport, and store-actor migration into a single change. Each alters failure behavior and needs an independently green baseline.
