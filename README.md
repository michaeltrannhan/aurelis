# Auralis

Auralis is a macOS SwiftUI menu-bar audio controller inspired by FineTune. Phases 0–8 and 10 are implemented in code, including CoreAudio discovery and process taps, per-app volume/mute/boost/EQ, single- and multi-device routing, global controls, typed recovery state, first-run guidance, and versioned JSON persistence.

The application, executable, Swift/Xcode targets, widget, bundle identifiers, URL scheme, and release artifacts all use the Auralis identity.

Signed builds require the `com.michaeltrannhan.Auralis`, `com.michaeltrannhan.Auralis.Widget`, and `group.com.michaeltrannhan.Auralis` capabilities in the selected Apple Developer team. On first launch, grant Screen & System Audio Recording and Accessibility, then add the widget from the gallery.

## Build

```sh
swift build
swift test
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

`build-debug-app.sh` and `build-release-app.sh` are the two build entry points.
Both use the shared internal builder to regenerate the Xcode project via
[xcodegen](https://github.com/yonaskolb/XcodeGen), build via `xcodebuild`,
validate the embedded widget and serialized App Intent parameters, and reject a
provisioning profile that does not authorize the configured App Group. Install
xcodegen first:

```sh
brew install xcodegen
```

## Desktop Widget

Auralis ships two macOS WidgetKit configurations across three supported sizes:

- **Auralis Mixer / systemSmall** — output device volume + mute toggle + open-app link.
- **Auralis Mixer / systemMedium** — up to 3 app rows with mute toggle, volume up/down, boost cycle, and refresh (visual parity with the desktop mixer window).
- **Auralis EQ / systemLarge** — a focused 10-band EQ chart with ±0.5 dB buttons per band.

Interactive controls (mute `Toggle`, volume/boost/EQ `Button`s) are backed by `AppIntent`s that queue commands into a shared App Group container. The app drains the queue via a `DispatchSource` file watcher and applies changes to its `AudioControlStore`. The app writes a `WidgetSnapshot` (compact Codable summary) to the same container on every store change so the widget always renders fresh state.

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

The bundle script defaults to the project's Apple Development team and identity
so the Screen & System Audio Recording grant survives rebuilds. Signed builds
also authorize Xcode to create or download missing provisioning profiles. Make
sure the appropriate Apple ID is signed in under Xcode's Accounts settings, then
override the team or identity when needed:

```sh
DEVELOPMENT_TEAM=TEAMID \
SIGN_IDENTITY='Apple Development' \
Scripts/build-debug-app.sh
```

Set `ALLOW_PROVISIONING_UPDATES=NO` only when the required certificates and
profiles are already installed, such as on a locked-down or offline CI runner.

If no identity is available, create or import an Apple Development or local Code
Signing certificate in Keychain Access. Ad-hoc signing is intentionally rejected
because its designated requirement changes whenever the executable is rebuilt.
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
