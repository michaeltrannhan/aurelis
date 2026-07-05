# EQMacRep

EQMacRep is a learning-oriented macOS SwiftUI menu-bar replica shell inspired by FineTune. It implements a CoreAudio discovery backend, per-app volume/mute/boost state, early process-tap volume routing, customization settings, JSON persistence, tests, and flow documentation.

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

## Current Scope

- Menu-bar popup app named EQMacRep.
- CoreAudio active output app and output device discovery.
- Per-app volume, mute, boost, pin, ignore, and 10-band EQ state.
- Early per-app volume, mute, and boost processing through private CoreAudio process taps.
- Customizable appearance, popup density, default new-app volume, EQ gain range, volume step, and inactive app visibility.
- JSON settings under Application Support by default.
- Flow docs in `Documentation/flows.md`.

## Later CoreAudio Phases

1. Harden permission banners, fallback behavior, and unsupported-app handling.
2. Add realtime EQ processing.
3. Add routing, media keys, HUD, AutoEQ, loudness, and packaging.

## License

FineTune is GPLv3. This replica is behaviorally derived from that application and is kept GPLv3-compatible.
