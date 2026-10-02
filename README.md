# Auralis

Auralis is a private, local-only audio mixer for the macOS menu bar. It controls
volume, mute, boost, and 10-band Process EQ per app; adds Output EQ per physical
device; routes apps to one or more outputs; and includes interactive Mixer and
EQ widgets.

Requires **macOS 14.2+ on Apple Silicon (arm64)**. Intel Macs are not supported.

## Highlights

- Per-app volume, mute, boost, pin/ignore, routing, and Process EQ.
- Per-device volume, mute, Output EQ, and reconnect-aware saved contexts.
- Named presets that copy into the current output without leaking settings
  between speakers, displays, headphones, or multi-output routes.
- Small, medium, and large Mixer widgets plus a large Process EQ widget.
- Open at login via macOS Login Items so mixing is ready after restart.
- Versioned local JSON settings, actionable recovery, and no remote telemetry.

## Install

The simplest source install is:

```sh
./install.sh
```

It tries a published prebuilt release first and otherwise builds from source.
Use `./install.sh --user` for `~/Applications`, or `./install.sh --help` for all
options. Source builds require Xcode 16.4+, XcodeGen 2.45.4, and an Apple
Development signing identity.

Release disk images contain `Auralis.app`, an Applications shortcut, a short
read-me, and a guided per-user installer. Recipients do **not** need an Apple
account. Prefer the normal Developer ID + Apple-notarized DMG. An artifact whose
name ends in `-unnotarized.dmg` can require Apple’s manual
[Open Anyway](https://support.apple.com/102445) flow and cannot provide the same
Gatekeeper assurance; verify its companion `.sha256` file before opening it.

Keep only one installed copy of `Auralis.app`. Duplicate bundle identifiers can
produce duplicate or stale widget entries.

After first launch:

1. Grant **Screen & System Audio Recording** for per-app audio controls.
2. Grant **Accessibility** for media keys and popup behavior.
3. Keep **Open at login** enabled on first run (or later in General settings).
   Turning it on registers a Login Item and opens System Settings if macOS
   needs approval.
4. Open Notification Center → **Edit Widgets**, search **Auralis**, and add a
   Mixer or EQ widget.

## Develop

```sh
make test       # SwiftPM software tests
make build      # certificate-backed Release app
make dev        # build, install, and run the Debug app
make verify     # complete verification matrix
```

`swift run Auralis` is useful for basic development, but it is not a
widget-capable `.app`. Use `make dev` for real process taps, permissions, App
Group IPC, and WidgetKit behavior.

Architecture, concurrency rules, persistence, test gates, and contributor
constraints live in [AGENTS.md](AGENTS.md).

## Package

Create an explicitly labeled local/unnotarized DMG from a certificate-backed
Release build:

```sh
make dmg
```

Create the normal distributable DMG with Developer ID and Apple notarization:

```sh
REQUIRE_NOTARIZATION=YES NOTARY_PROFILE=your-profile Scripts/package-dmg.sh
```

Official zip/tar release assets use `Scripts/package-release.sh`. Exact names,
credentials, checksum commands, and DMG behavior are documented in
[packaging/README.md](packaging/README.md).

## Practical limitations

- Per-app controls depend on Screen & System Audio Recording permission and
  CoreAudio process-tap support.
- Some digital outputs do not expose hardware volume or mute controls.
- Widget controls are buttons rather than sliders, and widget meters refresh
  more slowly than the live app UI.
- Signing, permissions, routing, hot-plug, widgets, and long-running audio
  behavior still need validation on real target hardware before a public release.

Support logs stay on the Mac at `~/Library/Logs/Auralis/`; no audio content or
diagnostics are uploaded. Attach those bounded log files when reporting a bug.

## License

Auralis is FineTune-inspired and licensed under
[GPL-3.0-or-later](LICENSE).
