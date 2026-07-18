# Auralis

Auralis is a macOS SwiftUI menu-bar audio controller inspired by FineTune. Phases 0–8 and 10 are implemented in code, including CoreAudio discovery and process taps, per-app volume/mute/boost/EQ, single- and multi-device routing, global controls, typed recovery state, first-run guidance, and versioned JSON persistence.

The application, executable, Swift/Xcode targets, widget, bundle identifiers, URL scheme, and release artifacts all use the Auralis identity. On first launch, Auralis imports compatible settings from the previous application identity when no Auralis settings file exists.

Because the app and widget bundle identifiers changed, macOS treats Auralis as a new installation: grant Screen & System Audio Recording and Accessibility again, then remove and re-add any existing widget. After confirming that Auralis imported the expected settings, quit and remove any previously installed `EQMacRep.app`; macOS cannot replace it automatically because it has a different bundle identifier. Signed builds also require the `com.michaeltrannhan.Auralis`, `com.michaeltrannhan.Auralis.Widget`, and `group.com.michaeltrannhan.Auralis` capabilities in the selected Apple Developer team.

## Build

```sh
swift build
swift test
```

Run the debug executable:

```sh
swift run Auralis
```

For real per-app volume testing, run the debug app bundle so macOS can read `NSAudioCaptureUsageDescription` and request Screen & System Audio Recording permission:

```sh
Scripts/build-debug-app.sh
open .build/Auralis.app
```

The bundle script regenerates the Xcode project via [xcodegen](https://github.com/yonaskolb/XcodeGen) and builds via `xcodebuild` so that the widget extension is properly signed and provisioned. Install xcodegen first:

```sh
brew install xcodegen
```

## Desktop Widget

Auralis ships a macOS desktop widget (WidgetKit) with two families:

- **systemSmall** — output device volume + mute toggle + open-app link.
- **systemMedium** — up to 3 app rows with mute toggle, volume up/down, boost cycle, and refresh (visual parity with the desktop mixer window).
- **systemLarge** — mixer rows plus a 10-band EQ chart with ±0.5 dB buttons per band.

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
DispatchSource ←────────────────── WidgetCommandQueue.append()
    ↓ drainPending()                 (from AppIntent.perform())
AudioControlStore
```

### Adding the widget

1. Build and launch the app: `Scripts/build-debug-app.sh && open .build/Auralis.app`
2. Open the widget gallery: click the date/time in the menu bar → **Edit Widgets** (or System Settings → Desktop & Dock → Widgets).
3. Search for **Auralis** and drag the Mixer or EQ widget to your desktop.

### Limitations

- Widgets cannot host `Slider`, `Menu`, `popover`, or drag gestures. Volume is adjusted via ± buttons; boost via a cyclic button; EQ via ±0.5 dB buttons per band. The full slider/drag UI is available in the app window.
- Live audio levels update at the widget's timeline refresh rate (≈60 s steady-state, 1 s after an intent), not in real-time.
- App icons render as SF Symbols (`waveform`) because the widget extension cannot access Launch Services.

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
For unsigned CI verification, use `CODE_SIGNING_ALLOWED=NO`; add
`CONFIGURATION=Release RUN_TESTS=NO` to verify the Release artifact path.

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
`Scripts/package-release.sh`; see
[`Documentation/verification/RELEASE_CHECKLIST.md`](Documentation/verification/RELEASE_CHECKLIST.md)
and the
[`physical hardware matrix`](Documentation/verification/HARDWARE_MATRIX.md).

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
- Flow docs in `Documentation/flows.md`.

## Remaining external release gates

1. Complete the real-hardware permission, audio, multi-output, device-disconnect, media-key, latency, and soak matrix.
2. Run Developer ID packaging and notarization with release credentials when distribution begins.

## License

FineTune is GPLv3. This replica is behaviorally derived from that application and is kept GPLv3-compatible.
