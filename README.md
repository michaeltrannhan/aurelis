# EQMacRep

EQMacRep is a macOS SwiftUI menu-bar audio controller inspired by FineTune. Phases 0–8 are implemented in code, including CoreAudio discovery and process taps, per-app volume/mute/boost/EQ/routing, global controls, typed recovery state, first-run guidance, and versioned JSON persistence.

## Build

```sh
swift build
swift test
```

Run the debug executable:

```sh
swift run EQMacRep
```

For real per-app volume testing, run the debug app bundle so macOS can read `NSAudioCaptureUsageDescription` and request Screen & System Audio Recording permission:

```sh
Scripts/build-debug-app.sh
open .build/EQMacRep.app
```

The bundle script uses the first valid certificate-backed code-signing identity
in your keychains so the Screen & System Audio Recording grant survives rebuilds.
Pin a specific certificate when needed:

```sh
SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' Scripts/build-debug-app.sh
```

If no identity is available, create or import an Apple Development or local Code
Signing certificate in Keychain Access. Ad-hoc signing is intentionally rejected
because its designated requirement changes whenever the executable is rebuilt.

## Current Scope

- Menu-bar popup app named EQMacRep.
- CoreAudio active output app and output device discovery.
- Per-app volume, mute, boost, pin, ignore, and 10-band EQ state.
- Early per-app volume, mute, and boost processing through private CoreAudio process taps.
- Customizable appearance, popup density, default new-app volume, EQ gain range, volume step, and inactive app visibility.
- JSON settings under Application Support by default.
- First-run permission guidance, actionable failures, ignored-app restoration, and safe reset confirmation.
- Flow docs in `Documentation/flows.md`.

## Remaining Release Gates and Later Phases

1. Complete the real-hardware permission, audio, routing, device-disconnect, media-key, and soak matrix.
2. Remove the remaining fixed 48 kHz EQ assumption and finish continuous-control coalescing.
3. After the daily-use gate: presets/AutoEQ, input controls, multi-output, diagnostics, signing, notarization, and updates.

## License

FineTune is GPLv3. This replica is behaviorally derived from that application and is kept GPLv3-compatible.
