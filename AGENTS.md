# AGENTS.md

Instructions for coding agents working in this repository.

## What this is

Auralis is a macOS 14.2+ **Apple Silicon (arm64) only** SwiftUI menu-bar audio mixer: per-app volume/mute/boost/Process EQ, per-device Output EQ, multi-output routing via private CoreAudio aggregates, WidgetKit mixer/EQ widgets, and versioned JSON persistence. FineTune-inspired; `LICENSE` is **GPL-3.0-or-later**. GitHub origin: **`michaeltrannhan/aurelis`** (not `auralis`).

Intel, universal binaries, ad-hoc signing, and remote telemetry are out of scope.

## How to apply agents

| File | Audience |
| --- | --- |
| `AGENTS.md` (this file) | Cursor, Codex, and other agents that read a root `AGENTS.md` |
| `CLAUDE.md` | Claude Code / Claude-oriented sessions |
| `README.md` | Humans: install, permissions, widget gallery, hardware caveats |
| `packaging/README.md` | Prebuilt zip/tar.xz names and unpack |

Point the agent at the repo root. Do **not** add `.cursor/rules/` unless a Cursor-only constraint cannot live here. `Documentation/` and `ULTIMATE_REFACTORING_PLAN.md` are gitignored — do not commit them.

## Layout

| Path | Role |
| --- | --- |
| `Package.swift` | SwiftPM: `Auralis`, `AuralisWidgetShared`, `AuralisTests` (no widget extension) |
| `project.yml` | XcodeGen source of truth |
| `Auralis.xcodeproj/` | Generated; gitignored |
| `Makefile` | `make install` / `make build` / `make test` (and verify/release/dev) |
| `install.sh` | Canonical install; execs `Scripts/install-app.sh` |
| `Sources/Auralis/` | Host app |
| `Sources/AuralisWidget/` | WidgetKit UI |
| `Sources/AuralisWidgetShared/` | Shared snapshot/command models |
| `Scripts/` | Build, install, verification, packaging |
| `packaging/` | `dist.toml`, Homebrew cask template |
| `Tests/AuralisTests/` | SwiftPM + Xcode |
| `Tests/AuralisWidgetTests/` | Xcode scheme only |

## Architecture

Control flow is command-in, snapshot-out. Do not call CoreAudio from views.

- **`AudioControlStore`** (`@MainActor`): UI-facing settings, rows, recovery. Does **not** call backend methods itself.
- **`AudioEngineActor`**: exclusive owner of discovery, HAL listeners, metering, taps, aggregates.
- **`AudioBackend`**: `MockAudioBackend` (tests) vs `CoreAudioDiscoveryBackend` (production; Release forces this).
- **`ControlCommandCoordinator` / `ControlSurface`**: ordered mutations from UI, keys, hotkeys, widgets.
- **Persistence**: `SettingsStore`, JSON v9. Corrupt files quarantined; future versions fail closed. Output contexts keyed by CoreAudio UID; named presets are copy-in templates.
- **Widget IPC**: App Group. Host writes `WidgetSnapshot`; AppIntents enqueue; host drains via `WidgetBridge`. Interactive AppIntents compile into **both** app and widget (`project.yml`).
- **Routing**: non-stacked private aggregates; first output is clock; Output EQ per physical device. Do not leak one output’s context into another.

## Install, build, test

```sh
./install.sh                           # same as Scripts/install-app.sh / Scripts/auralis.sh install
make install                           # ./install.sh --yes
make build                             # Scripts/build-release-app.sh
make test                              # swift test
Scripts/auralis.sh {install|build|test|dev|verify|release}
RUN_APP=YES Scripts/build-debug-app.sh
```

Install tries **prebuilt first** (`Scripts/install-prebuilt.sh` / `Scripts/lib/prebuilt.sh` — GitHub `michaeltrannhan/aurelis` or a local `.build/release` artifact), then source. Flags: `--from-source`, `--prebuilt`, `--yes` (also when not a TTY or `CI=true`), `--user` / `--system`, `--skip-build`, `--no-launch`.

- `Scripts/build-app.sh` is internal. Public builders: `build-debug-app.sh`, `build-release-app.sh`.
- `swift run Auralis` is not a widget-capable `.app`. Unsigned `CODE_SIGNING_ALLOWED=NO` builds are not WidgetKit/App Group installs.

## Testing

**Software (always, including CI):**

```sh
swift test                             # 351 AuralisTests; CoreAudioHardwareTests skip without AURALIS_HW_TESTS
Scripts/run-verification.sh all        # or: preflight|strict|tsan|asan|ubsan|stress|xcode|coverage
```

- **`SoftwarePipelineE2ETests`**: v8 fixture → v9 migrate, store mutations persist/reload (`Tests/AuralisTests/Fixtures/mixer-settings-v8.json`). Mock backend; not hardware-gated.
- **`CoreAudioPCMRendererTests.testVolumeMuteAndBoostLandOnRenderedPCM`**: volume/mute/boost land on rendered PCM.
- Prefer `MockAudioBackend` and temp settings (`TestSupport.swift`). Seeded fuzz failures become regression tests.
- Sanitizer gates set `AURALIS_INSTRUMENTED_TESTS=1`. Coverage floor 59%.
- **`AuralisWidgetTests`** (`WidgetRenderingTests`) run only via the Xcode `Auralis` scheme (`xcode` / `signed` gates), not SwiftPM.

**Hardware (default OFF):**

```sh
AURALIS_HW_TESTS=1 swift test --filter CoreAudioHardwareTests
AURALIS_HW_TESTS=1 AURALIS_HW_MUTATION=1 swift test --filter CoreAudioHardwareTests   # optional restore-safe volume write
Scripts/hardware-preflight.sh          # separate non-XCTest gate (also: Scripts/run-verification.sh hardware)
```

`CoreAudioHardwareTests` skip unless `AURALIS_HW_TESTS=1`. Mutation (`AURALIS_HW_MUTATION=1`) is optional and restore-safe. Preflight is not a substitute for the soak/permission/routing matrix. Process taps, Screen Recording, Accessibility, and live widgets need a certificate-backed `.app` on real hardware.

## CI and release

PR / push (macos-15, Xcode 16.4): setup runs `Scripts/ci-preflight.sh`, then `Scripts/run-verification.sh` for **strict / tsan / asan / ubsan / stress / xcode / coverage**. The `signed` gate is local (needs a signing identity).

Hardware CI is **off** unless `AURALIS_HW_TESTS=1` via `workflow_dispatch` (`run_hardware`) or PR labels `hardware` / `e2e-device` — then `Scripts/run-verification.sh hardware` plus `swift test --filter CoreAudioHardwareTests`.

Tags `v*`: `Scripts/package-release.sh` publishes `Auralis-{version}-aarch64-apple-darwin.zip`, `.tar.xz`, and `Auralis-{version}-SHA256SUMS`. Hosted runners **skip publish** without Developer ID Application and `NOTARY_PROFILE`. Local: `NOTARY_PROFILE=your-profile Scripts/package-release.sh`.

## Conventions

- Swift 6, complete concurrency. Backend calls stay off the main actor and out of views.
- Identity: `Auralis` / `com.michaeltrannhan.Auralis` / `com.michaeltrannhan.Auralis.Widget`.
- Additive settings migrations; missing Output EQ loads flat.
- Local logs only. FineTune-adapted UI keeps a short source comment.
- Edit `project.yml`, regenerate; do not hand-edit `Auralis.xcodeproj`.
- Don’t add x86_64/universal/ad-hoc signing, stack aggregates, edit `.github/workflows`, rewrite README install sections, or relicense.
- Don’t commit `.build/`, `DerivedData/`, generated Xcode projects, or `Documentation/`.
