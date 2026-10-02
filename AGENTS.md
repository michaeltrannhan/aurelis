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
| `README.md` | Humans: capabilities, install, permissions, essential caveats |
| `packaging/README.md` | Zip/tar/DMG names, trust levels, checksums, packaging |

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
| `packaging/` | Distribution contract, DMG payload, Homebrew cask template |
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

### Lifecycle and resource ownership

- An owner must not strongly retain an unbounded `Task` whose body strongly
  retains that owner. Suspend first, then briefly upgrade a weak owner per
  iteration, or move the loop into a separately owned worker.
- `stop()` is a quiescence boundary: close admission, cancel producers, await
  their completion, drain or cancel ordered work, remove subscriptions/listeners,
  and release processors/controllers. `deinit` is a best-effort fallback, not
  the primary shutdown path.
- Every HAL listener, `DispatchSource`, Combine subscription, retry task, meter
  loop, process tap, aggregate, and widget watcher needs an explicit symmetric
  teardown. Retiring tap controllers must be stopped as well as the active one.
- Keep waits and retry delays cancellable. Never hold an actor or main-actor
  isolation across an infinite monitoring loop when callers need shutdown.

### UI flow ownership

- Text entry owns printable keys and arrows while search is focused; inspectors
  own their editing keys; only then may popup row shortcuts act. Keep this
  priority in `PopupKeyboardOwnership` rather than duplicating view predicates.
- First run exposes one contextual completion action: continue discovery until
  process-tap permission exists, then start mixing. Launch at login is a
  checkbox on that sheet (default on) plus General settings; `SMAppService`
  is the source of truth, not settings JSON. Do not register on launch.
- Transient HUD animation state belongs to the window controller/state model.
  Replacing an `NSHostingView` recreates SwiftUI `@State`, so do not keep peak or
  decay history only inside the hosted view.
- Views emit commands and render snapshots. They do not own CoreAudio work,
  widget transport, or long-lived discovery tasks.

## Install, build, test

```sh
./install.sh                           # same as Scripts/install-app.sh / Scripts/auralis.sh install
make install                           # ./install.sh --yes
make build                             # Scripts/build-release-app.sh
make test                              # swift test
Scripts/auralis.sh {install|build|test|dev|verify|release|dmg}
RUN_APP=YES Scripts/build-debug-app.sh
```

Install tries **prebuilt first** (`Scripts/install-prebuilt.sh` / `Scripts/lib/prebuilt.sh` — GitHub `michaeltrannhan/aurelis` or a local `.build/release` artifact), then source. Flags: `--from-source`, `--prebuilt`, `--yes` (also when not a TTY or `CI=true`), `--user` / `--system`, `--skip-build`, `--no-launch`.

- `Scripts/build-app.sh` is internal. Public builders: `build-debug-app.sh`, `build-release-app.sh`.
- `swift run Auralis` is not a widget-capable `.app`. Unsigned `CODE_SIGNING_ALLOWED=NO` builds are not WidgetKit/App Group installs.

## Testing

**Software (always, including CI):**

```sh
swift test                             # 371 tests; CoreAudioHardwareTests skip without AURALIS_HW_TESTS
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

### DMG distribution contract

| Artifact | Publisher requirement | Recipient experience |
| --- | --- | --- |
| `Auralis-{version}-aarch64-apple-darwin.dmg` | Developer ID Application + `NOTARY_PROFILE`; `REQUIRE_NOTARIZATION=YES` | Normal Gatekeeper confirmation; no Apple account |
| `Auralis-{version}-aarch64-apple-darwin-unnotarized.dmg` | Apple Development or Developer ID certificate; no notarization | External SHA-256 verification plus possible Privacy & Security → Open Anyway; no Apple account |

`Scripts/package-dmg.sh` rejects unsigned and ad-hoc apps because permissions,
WidgetKit, and App Group identity depend on a stable certificate-backed
designated requirement. The unnotarized artifact is a testing/community
deliverable, never equivalent to an Apple-notarized public release. It must stay
visibly named `-unnotarized.dmg`.

The DMG contains the intact signed app, `/Applications` link,
`Install Auralis.command`, and `READ ME.txt`. The guided installer verifies both
bundle identifiers, arm64-only executables, certificate classes, matching teams,
hardened runtime, and nested signatures. It installs to `~/Applications`, moves
an existing valid Auralis copy to Trash, refuses a second system copy, and does
not remove quarantine or disable Gatekeeper. Keep the companion `.dmg.sha256`
outside the image so it can authenticate the download before mounting.

## Conventions

- Swift 6, complete concurrency. Backend calls stay off the main actor and out of views.
- Identity: `Auralis` / `com.michaeltrannhan.Auralis` / `com.michaeltrannhan.Auralis.Widget`.
- Additive settings migrations; missing Output EQ loads flat.
- Local logs only. FineTune-adapted UI keeps a short source comment.
- Edit `project.yml`, regenerate; do not hand-edit `Auralis.xcodeproj`.
- Keep `README.md` concise and human-facing; put architecture, CI, and packaging
  internals here or in `packaging/README.md`.
- Don’t add x86_64/universal/ad-hoc signing, stack aggregates, edit `.github/workflows`, or relicense.
- Don’t commit `.build/`, `DerivedData/`, generated Xcode projects, or `Documentation/`.
