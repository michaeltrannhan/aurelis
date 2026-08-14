# CLAUDE.md

Guidance for Claude Code (`claude.ai/code`) in this repository. Cursor and other agents should start from `AGENTS.md`; humans from `README.md`. Facts below must stay aligned with those files.

## Project

Auralis is a **macOS 14.2+ / Apple Silicon (arm64)** SwiftUI menu-bar mixer: CoreAudio process taps, per-app volume/mute/boost/Process EQ, per-device Output EQ, private (non-stacked) aggregate routing, WidgetKit mixer/EQ widgets, reconnect-aware output contexts, and version-9 JSON settings.

License: **GPL-3.0-or-later** (`LICENSE`). GitHub origin: **`michaeltrannhan/aurelis`** (not `auralis`). No Intel/universal builds, no ad-hoc signing, no remote telemetry.

## Commands

```sh
./install.sh                           # = Scripts/install-app.sh; prebuilt then source
make install                           # ./install.sh --yes
make build
make test                              # swift test
Scripts/auralis.sh {install|build|test|dev|verify|release}
swift build && swift test && swift run Auralis   # SwiftPM; not a widget .app
RUN_APP=YES Scripts/build-debug-app.sh
Scripts/build-release-app.sh           # Scripts/build-app.sh is internal
Scripts/run-verification.sh all
Scripts/run-verification.sh <gate>     # preflight|strict|tsan|asan|ubsan|stress|xcode|coverage|signed|hardware
```

Install flags: `--from-source`, `--prebuilt`, `--yes` (also non-TTY / `CI=true`), `--user` / `--system`, `--skip-build`, `--no-launch`. Prebuilt path: `Scripts/install-prebuilt.sh` / `Scripts/lib/prebuilt.sh`. Need Xcode ≥ 16.4, Swift 6, XcodeGen (CI: 2.45.4), arm64. Unsigned `CODE_SIGNING_ALLOWED=NO` is not a working widget/App Group install.

## Architecture

```
Views / AppIntents / media keys / hotkeys
        ↓ ControlCommandCoordinator (ControlSurface)
AudioControlStore (@MainActor)     ← settings, rows, recovery UI
        ↓ commands / snapshots only
AudioEngineActor                   ← exclusive backend owner
        ↓
AudioBackend  Mock | CoreAudioDiscoveryBackend (taps, aggregates, HAL)
        ↓
SettingsStore (JSON v9, UID-keyed output contexts, quarantined corrupt files)

Widget: WidgetBridge writes WidgetSnapshot to App Group;
        AppIntents enqueue commands; host drains and applies.
```

`Package.swift` has no widget extension. Interactive AppIntents compile into **both** app and widget (`project.yml`). Release forces CoreAudio; tests use `MockAudioBackend` unless hardware-gated.

## Testing

**Software (always, CI):** `swift test` — **351** `AuralisTests`; `CoreAudioHardwareTests` skip. Then `Scripts/run-verification.sh` for strict/tsan/asan/ubsan/stress/xcode/coverage.

- `SoftwarePipelineE2ETests` — v8 fixture → v9 migrate, persist/reload (not hardware-gated).
- `CoreAudioPCMRendererTests.testVolumeMuteAndBoostLandOnRenderedPCM` — volume/mute/boost on rendered PCM.
- `AuralisWidgetTests` only via the Xcode `Auralis` scheme, not SwiftPM.

**Hardware (default OFF):** CI sets `AURALIS_HW_TESTS=1` on `workflow_dispatch` (`run_hardware`) or PR labels `hardware` / `e2e-device`.

```sh
AURALIS_HW_TESTS=1 swift test --filter CoreAudioHardwareTests
AURALIS_HW_TESTS=1 AURALIS_HW_MUTATION=1 swift test --filter CoreAudioHardwareTests
Scripts/hardware-preflight.sh          # non-XCTest; also Scripts/run-verification.sh hardware
```

`signed` is local (signing identity). Hosted PR CI does not run it. Process taps and live widgets need a certificate-backed `.app` on real hardware.

## CI and release

macos-15 / Xcode 16.4: `Scripts/ci-preflight.sh`, then the software verification gates above. Tags `v*`: `Scripts/package-release.sh` → zip + tar.xz + SHA256SUMS under `.build/release/`. Hosted runners skip publish without Developer ID / `NOTARY_PROFILE`.

## Working here

- Swift 6, complete concurrency. Keep backend calls off the main actor and out of views.
- Edit `project.yml`, then regenerate — do not hand-edit `Auralis.xcodeproj`.
- Preserve per-device contexts; missing Output EQ loads flat.
- Do not stack aggregates, add telemetry, or relicense.
- Do not edit `.github/workflows` or rewrite README install sections unless asked.
- Do not commit `.build/`, `DerivedData/`, generated Xcode projects, or gitignored `Documentation/`.
