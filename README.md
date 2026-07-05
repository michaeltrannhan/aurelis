# EQMacRep

EQMacRep is a learning-oriented macOS SwiftUI menu-bar replica shell inspired by FineTune. It implements the first safe layer of the app: app/device snapshots from a mock backend, per-app volume/mute/boost/EQ state, customization settings, JSON persistence, tests, and flow documentation.

This first build does not create realtime CoreAudio process taps. The code is structured around `AudioBackend` so a later CoreAudio backend can replace `MockAudioBackend` without rewriting the UI.

## Build

```sh
swift build
swift test
```

Run the debug executable:

```sh
swift run EQMacRep
```

## Current Scope

- Menu-bar popup app named EQMacRep.
- Mock active/inactive audio apps.
- Per-app volume, mute, boost, pin, ignore, and 10-band EQ state.
- Customizable appearance, popup density, default new-app volume, EQ gain range, volume step, and inactive app visibility.
- JSON settings under Application Support by default.
- Flow docs in `Documentation/flows.md`.

## Later CoreAudio Phases

1. Discover active output apps through CoreAudio process objects.
2. Discover output/input devices and default-device changes.
3. Add per-app process taps for volume, mute, and boost.
4. Add realtime EQ processing.
5. Add routing, media keys, HUD, AutoEQ, loudness, and packaging.

## License

FineTune is GPLv3. This replica is behaviorally derived from that application and is kept GPLv3-compatible.
