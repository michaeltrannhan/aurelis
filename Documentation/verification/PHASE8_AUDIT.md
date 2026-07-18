# Phase 8 completion audit

Audit date: 2026-07-16. This document maps every Phase 8 task and completion gate in `ULTIMATE_REFACTORING_PLAN.md` to current evidence. “Automated” means the requirement is exercised without changing the user's live audio, permission, login, or sleep state. It does not convert a hands-on release row into an automated pass.

## Task evidence

| Phase 8 task | Authoritative evidence | Status |
| --- | --- | --- |
| Widget queue, bridge, schema, intent, app-group, acknowledgment, and closed-host coverage | `WidgetCommandQueueTests.swift`, `WidgetModelsTests.swift`, `WidgetRenderingTests.swift`, and signed app-group probes in `build-debug-app.sh` | Automated proof complete |
| Production aggregate-journal recovery | `CoreAudioAggregateCrashGuardTests.swift` and `CoreAudioOrphanedAggregateCleanupTests.swift` instantiate `CoreAudioAggregateOwnershipJournal` | Automated proof complete |
| Tap lifecycle failure injection | `CoreAudioTapLifecycleTests.swift` covers creation, handover, teardown ordering, retained handles, retry, and aggregate destruction failures | Automated proof complete |
| Real `AudioBufferList` layouts | `CoreAudioPCMRendererTests.swift` uses owned interleaved, planar, aliased, multi-buffer, and invalid runtime layouts | Automated proof complete |
| DSP response, stability, denormal, storage, and performance | `CoreAudioPCMRendererTests.swift`, `CoreAudioBiquadMathTests.swift`, and `CoreAudioRealtimeGainTests.swift` | Automated proof complete |
| Malformed, future, corrupt, and property/fuzz settings | `SettingsFuzzTests.swift` and `SettingsStoreTests.swift` | Automated proof complete |
| Remove fixed async sleeps from tests | No `sleep`, `usleep`, `Thread.sleep`, or `Task.sleep` call remains under `Tests/`; injected schedulers and XCTest expectations are used | Automated proof complete |
| Consolidated test support | `Tests/AuralisTests/TestSupport.swift` owns temporary paths, schedulers, layouts, and audio-buffer helpers | Automated proof complete |
| External-control and permission lifecycle through OS seams | `ExternalControlsCoordinatorTests.swift`, `AudioCapturePermissionTests.swift`, and `MediaTapRecoveryAndRelaunchTests.swift` | Automated proof complete |
| Popup/widget rendering and accessibility integration | `ViewRenderingIntegrationTests.swift`, `WidgetRenderingTests.swift`, `WidgetModelsTests.swift`, and `PopupKeyboardNavModelTests.swift` | Automated proof complete |
| Complete strict concurrency | SwiftPM/Xcode settings, `run-verification.sh strict`, and the `strict-concurrency` workflow job | 290 tests pass |
| Thread Sanitizer and sustained callback stress | `run-verification.sh tsan`, `run-verification.sh stress`, and dedicated workflow jobs | 290 TSan tests and 100,000 callbacks pass |
| Optional/manual physical hardware matrix | `HARDWARE_MATRIX.md`, `hardware-preflight.sh`, and `HardwarePreflight.swift` | Matrix defined; read-only prerequisite passes |
| Signed Debug/Release structure, entitlement, embedding, and signature validation | `build-debug-app.sh` and `test-build-verifier.sh` | Automated proof complete |
| Certificate-backed Debug/Release and shared-container execution | `run-verification.sh signed`; signed app and sandboxed widget entitlement probes exchange a nonce through the same group container | Apple Development proof complete |
| Distribution packaging/notarization verification | `package-release.sh` requires Developer ID, hardened runtime, notarization by default, stapling, Gatekeeper, ZIP extraction, and post-extraction validation | Implementation and negative gates complete; credential-backed run pending |

## Completion gates

| Completion gate | Evidence assessment |
| --- | --- |
| SwiftPM and generated Xcode suites pass | Proven: 290 SwiftPM/app tests; unsigned widget rendering 3/3; signed widget target 4/4 |
| App and widget build in Debug and Release | Proven unsigned and Apple Development-signed on arm64; bundle/package/architecture validation passes |
| Signed app and widget resolve the same app-group container | Proven by signed host test and separately signed app/widget entitlement probes exchanging and deleting a nonce |
| Strict concurrency and Thread Sanitizer pass | Proven: 290/290 under each gate |
| Widget commands work with running and closed hosts | Queue/bridge durability, stopped lease, restart drain, idempotent replay, acknowledgment ordering, and production rendering are proven in automation; the real WidgetKit app-running/app-closed exercise remains a hands-on matrix row |
| No teardown failure loses a CoreAudio resource handle | Failure injection proves failed handles and journal ownership remain retryable; real HAL teardown is still checked during the hands-on matrix |
| Audio callback meets its budget | Proven: stable preallocated storage, zero declared heap-allocation budget, finite output, and 100,000-callback gate passed in 46.384 seconds |
| Hardware matrix passes without stuck taps or orphaned aggregates | Not yet proven. The read-only preflight found two physical outputs, zero live Auralis aggregates, and zero journal records, but it did not play audio or exercise route/permission/device/sleep transitions |
| Build scripts reject build, plist, embedding, architecture, signature, or entitlement mismatch | Proven. Unsigned self-test rejects seven fault classes; signed self-test rejects nine, adding signature tampering and non–Developer ID distribution |

## Current environment boundary

- Apple silicon laptop running macOS 26.5.2 has built-in and HDMI physical outputs available.
- `hardware-preflight.sh` passes with two physical outputs, zero live owned aggregates, and an empty production journal.
- Keychain contains one Apple Development identity for team `6T8J96Z3SD`; it contains no Developer ID Application identity.
- No `auralis-notary` keychain profile exists.
- Completing the hands-on matrix would change live output routes, permissions, app/widget state, and sleep/login state. Those actions require the user to conduct or explicitly supervise the matrix.
- Developer ID packaging/notarization cannot be positively executed until its identity and notary credentials exist.

Therefore all feasible automated Phase 8 work is proven, but the overall completion gate remains open on hands-on hardware/WidgetKit/HAL evidence and a real Developer ID notarization run.
