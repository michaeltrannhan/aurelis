# Auralis

Auralis is a macOS SwiftUI menu-bar audio controller inspired by FineTune. It includes CoreAudio discovery and process taps, per-app volume/mute/boost/EQ, single- and multi-device routing, automatic per-output contexts, reusable preset templates, reconnect-aware output settings, global controls, typed recovery state, first-run guidance, and versioned JSON persistence.

The application, executable, Swift/Xcode targets, widget, bundle identifiers, URL scheme, and release artifacts all use the Auralis identity.

Signed builds use the `com.michaeltrannhan.Auralis` and
`com.michaeltrannhan.Auralis.Widget` bundle identifiers. By default, the build
derives a provisioning-free macOS App Group from the signing certificate's team
identifier. On first launch, grant Screen & System Audio Recording and
Accessibility, then add the widget from the gallery.

## Install

Prerequisites: an Apple-silicon Mac running macOS 14.2 or later, Xcode 16.4 or
newer (Swift 6 or newer), one valid Apple Development code-signing identity in
the login keychain, and [XcodeGen 2.45.4](https://github.com/yonaskolb/XcodeGen/releases/tag/2.45.4).
The SwiftPM package, generated Xcode project, and distribution scripts are
arm64-only; Intel Macs are unsupported. CI uses Xcode 16.4 as its reproducible
baseline and permits newer local Xcode versions.

```sh
brew install xcodegen
```

One command builds the signed Release app, installs it, registers the desktop widget, and launches Auralis:

```sh
Scripts/install-app.sh
```

This installs to `/Applications`. For a per-user install that needs no admin rights:

```sh
Scripts/install-app.sh --user
```

which installs to `~/Applications` instead. Keep only one installed copy: two `Auralis.app` bundles share one bundle identifier, which duplicates the widget gallery entry and confuses AppIntent delivery; the installer refuses to proceed when it detects a second copy.

After the first launch:

1. Grant **Screen & System Audio Recording** when prompted (required to see and control per-app audio).
2. Grant **Accessibility** when prompted (required for media-key and popup behavior).
3. Click the date/time in the menu bar → **Edit Widgets** → search **Auralis** and drag a widget to the desktop.

Useful flags: `--skip-build` reinstalls the last Release build, `--no-launch` installs without starting the app. `Scripts/install-app.sh --help` lists all options.

## Build

```sh
swift build --arch arm64
swift test --arch arm64
```

Run the debug executable:

```sh
swift run Auralis
```

For real per-app volume and widget testing, build and run the certificate-backed Debug app bundle:

```sh
RUN_APP=YES Scripts/build-debug-app.sh
```

This writes the validated product to `.build/products/Debug/Auralis.app`. With
`RUN_APP=YES`, it installs a disposable development copy at
`/Applications/Auralis-Debug.app` before registering and launching the widget.
The stable installation prevents Launch Services and WidgetKit from retaining a
disposable Xcode DerivedData or repository build after it has been replaced. To
build without installing or launching, omit `RUN_APP=YES`.

Debug diagnostics are detailed and local: the app keeps a bounded operation log
at `.build/logs/runtime/Auralis-debug.log` (plus one rotated `.1` backup), and an
interactive run captures the app, widget extension, and relevant macOS signing
or sandbox events in a timestamped
`.build/logs/runtime/Auralis-unified-*.log`.

Build the Release product with minimal support diagnostics separately:

```sh
Scripts/build-release-app.sh
```

The Release app is written to `.build/products/Release/Auralis.app`. It does not
contain the repo-local Debug path or detailed operation tracing. It records only
session summaries, warnings, and errors to the macOS unified log and to the
bounded local files `~/Library/Logs/Auralis/Auralis.log` and
`Auralis.log.1`. There is no remote telemetry or user/audio-content collection;
those two files can be attached to a bug report.

`build-debug-app.sh` and `build-release-app.sh` are the two build entry points; `install-app.sh` chains the Release build into a full installation.
Both use the shared internal builder to regenerate the Xcode project via
[xcodegen](https://github.com/yonaskolb/XcodeGen), build via `xcodebuild`,
validate the embedded widget and serialized App Intent parameters, and verify
live shared-container access between separately signed app and widget probes.
Install the pinned XcodeGen version first (CI downloads its official
`xcodegen.zip` and validates SHA-256
`090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef`):

```sh
brew install xcodegen
```

## Desktop Widget

Auralis ships two macOS WidgetKit configurations:

- **Auralis Mixer / systemSmall** — a focused master-output remote with volume down/up, mute, current profile, and active-app status.
- **Auralis Mixer / systemMedium** — master output with quick output cycling plus two app rows with mute, volume, boost, and refresh.
- **Auralis Mixer / systemLarge** — a control-center layout with Global/output configuration status, direct output selection, a roomy master volume/mute panel, batch mute/unmute/50% actions, and two full app mixer rows.
- **Auralis EQ / systemLarge** — a focused 10-band EQ chart with ±0.5 dB buttons per band.

Interactive controls are backed by `AppIntent`s that queue absolute commands into a shared App Group container. This includes output selection, device and app volume/mute, profile application, batch active-app controls, boost, EQ, and refresh. The app drains the queue via a `DispatchSource` file watcher and applies changes to its `AudioControlStore`. The app writes a `WidgetSnapshot` (compact Codable summary) to the same container on every store change so the widget always renders fresh state.

## Profiles and device reconnects

Changing an output device's volume, mute state, or selecting it as the default output in Auralis is persisted by device UID. Auralis reapplies that state at launch and when that device disconnects and later reconnects. It deliberately does not overwrite ordinary hardware-key or Control Center changes while the device remains connected.

Audio contexts and presets are available from the main-window header, menu-bar
popup, Audio settings, and the large Mixer widget. Every physical output owns
an automatically saved context keyed by its CoreAudio UID. That context contains
the complete per-app mix—routing, volume, mute, boost, and EQ—so LG UltraFine
settings cannot leak into MacBook Speakers after an unplug or default-output
change. Newly discovered outputs start neutral: follow the system default,
default app volume, unmuted, 1× boost, and flat EQ.

Named presets are detached templates. Applying one copies its mix into a single
output context; later edits remain local to that output and save automatically.
Unavailable explicit routes temporarily follow the current system output while
retaining their saved UID for restoration on reconnect. CoreAudio hot-plug
bursts are stabilized before Auralis commits the final context switch. Version-8
persistence preserves existing output configurations as automatic contexts and
keeps Global profiles as copyable presets.

### Widget architecture

```
App process                          Widget extension process
────────────                         ────────────────────────
AudioControlStore                    TimelineProvider
    ↓ objectWillChange                   ↓ getTimeline
WidgetBridge                           WidgetSnapshotReader.read()
    ↓ makeSnapshot()                    ↓
WidgetSnapshotWriter.write()        Widget views (systemSmall/Medium/Large)
    → App Group container              ↑
DispatchSource ←────────────────── WidgetCommandQueue.enqueue()
    ↓ drain()                        (from AppIntent.perform())
AudioControlStore
```

### Adding the widget

1. Build and launch the signed app: `RUN_APP=YES Scripts/build-debug-app.sh`
2. Open the widget gallery: click the date/time in the menu bar → **Edit Widgets** (or System Settings → Desktop & Dock → Widgets).
3. Search for **Auralis** and drag the Mixer or EQ widget to your desktop.

The debug runner installs to the stable `/Applications` path and refreshes
WidgetKit registration before launch. If **Auralis** is
still absent, or the gallery previously showed duplicate entries, run:

```sh
Scripts/refresh-widget-gallery.sh
```

This unregisters and re-registers `/Applications/Auralis-Debug.app`'s widget,
restarts the per-user
`chronod` and Notification Center processes, and relaunches Auralis. Close any
open **Edit Widgets** window before running it, then reopen the gallery and
search for **Auralis**. The builder also removes disposable registrations from
Xcode DerivedData and legacy `.build` output paths.

### Limitations

- Widgets cannot host `Slider`, `Menu`, `popover`, or drag gestures. Volume is adjusted via ± buttons; boost via a cyclic button; EQ via ±0.5 dB buttons per band. The full slider/drag UI is available in the app window.
- Live audio levels update at the widget's timeline refresh rate (≈60 s steady-state, 1 s after an intent), not in real-time.
- Widget headers and fallback app rows use the bundled Auralis brand mark and audio glyph. Per-application icons still cannot be resolved through Launch Services from the widget extension.

The bundle script uses an Apple Development identity so the Screen & System
Audio Recording grant survives rebuilds. When exactly one matching team is
installed, the script infers its identifier and uses a
`<TeamIdentifier>.com.michaeltrannhan.Auralis` App Group. Apple supports this
macOS-specific form without registering the group or embedding provisioning
profiles, so an Xcode account is not required after the certificate is present.
Override the inferred team or identity when needed:

```sh
DEVELOPMENT_TEAM=TEAMID \
SIGN_IDENTITY='Apple Development' \
Scripts/build-debug-app.sh
```

To use a registered `group.*` App Group instead, opt into Xcode-managed
provisioning:

```sh
DEVELOPMENT_TEAM=TEAMID \
APP_GROUP_ID=group.com.michaeltrannhan.Auralis \
CODE_SIGN_STYLE=Automatic \
REGISTER_APP_GROUPS=YES \
ALLOW_PROVISIONING_UPDATES=YES \
Scripts/install-app.sh
```

That mode requires the corresponding Apple account, bundle identifiers,
capability, and profiles.

If no identity is available, add an Apple account in Xcode to create an Apple
Development certificate, or import an existing certificate and private key.
Ad-hoc signing is intentionally rejected because its designated requirement
changes whenever the executable is rebuilt.
For unsigned CI compilation and product verification, use
`CODE_SIGNING_ALLOWED=NO Scripts/build-debug-app.sh` or
`CODE_SIGNING_ALLOWED=NO Scripts/build-release-app.sh`. Unsigned output is not a
functional desktop-widget installation: WidgetKit and the shared App Group must
be exercised with the default certificate-backed build.

## Verification and release

Run the complete automated matrix, or one independently repeatable gate:

```sh
Scripts/run-verification.sh all
Scripts/run-verification.sh strict
Scripts/run-verification.sh tsan
Scripts/run-verification.sh asan
Scripts/run-verification.sh ubsan
Scripts/run-verification.sh coverage
Scripts/run-verification.sh stress
Scripts/run-verification.sh xcode
Scripts/run-verification.sh signed
Scripts/run-verification.sh hardware
```

The stress iteration count is configurable with `AURALIS_STRESS_ITERATIONS`.
The Xcode gate renders the production small, medium, and large widget views and
runs a product-verifier fault matrix. The `signed` gate additionally exercises
live app/widget access to the shared app-group container and distribution
rejection paths. The read-only `hardware` gate verifies that physical outputs
are available and the aggregate/journal starting state is clean; it does not
replace the hands-on hardware matrix.
Certificate-backed Release packaging and notarization use
`Scripts/package-release.sh`. Before distributing, verify the signed artifact,
notarization, permissions, audio routes, and widget behavior on physical hardware.

## Current Scope

- Menu-bar popup app named Auralis.
- Desktop widget (systemSmall/Medium/Large) with interactive mute, volume, boost, and EQ controls via AppIntents.
- CoreAudio active output app and output device discovery.
- Reconnect-aware per-device volume/mute restoration and preferred default-output selection.
- Named profiles for app controls, output routes, device controls, and preferred output.
- Per-app volume, mute, boost, pin, ignore, and 10-band EQ state.
- Per-app follow-default, single-output, and ordered multi-output routing through private CoreAudio aggregate devices, with active-device and matching-sample-rate validation.
- Early per-app volume, mute, and boost processing through private CoreAudio process taps.
- Customizable appearance, popup density, default new-app volume, EQ gain range, volume step, and inactive app visibility.
- JSON settings under Application Support by default.
- First-run permission guidance, actionable failures, ignored-app restoration, and safe reset confirmation.
- Local engineering notes are intentionally not versioned.

## Remaining external release gates

1. Complete the real-hardware permission, audio, multi-output, device-disconnect, media-key, latency, and soak matrix.
2. Run Developer ID packaging and notarization with release credentials when distribution begins.

## License

FineTune is GPLv3. This replica is behaviorally derived from that application and is kept GPLv3-compatible.
