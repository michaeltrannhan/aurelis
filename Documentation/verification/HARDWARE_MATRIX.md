# Auralis physical hardware matrix

This matrix is optional for ordinary pull requests and mandatory before a hardware-impacting release. Record macOS/build/device details and attach the app log, aggregate ownership journal, and failure notes to the release evidence.

## Read-only preflight

Before touching live audio, run:

```sh
Scripts/hardware-preflight.sh
```

The preflight uses CoreAudio's live device registry and the production ownership-journal location. It fails unless at least two physical output devices are available and the starting state contains neither a live `Auralis-*` aggregate nor an outstanding journal record. Override the availability threshold with `MIN_PHYSICAL_OUTPUTS=1` only for a single-device row. It never plays audio, changes routes, requests permissions, or substitutes for the exercises below; retain its output with the release evidence.

## Required configurations

| Area | Minimum configurations | Required exercise |
| --- | --- | --- |
| Mac | Apple silicon laptop; Apple silicon desktop when available; Intel Mac when supported | Fresh launch, quit, relaunch, sleep/wake, logout/login |
| macOS | Oldest supported (14.2); current stable; next beta when available | Permission grant/deny/revoke, restart-required flow |
| Built-in output | Speakers; headphone jack when present | Volume, mute, boost, all EQ bands, route changes |
| USB | Class-compliant stereo DAC; multichannel interface | Plug/unplug while active, sample-rate changes, default-device changes |
| Bluetooth/AirPlay | Bluetooth headphones; AirPlay output when available | Connect/disconnect, latency transition, route fallback |
| Digital/display | HDMI or DisplayPort audio | Default change, display sleep/wake, route recovery |
| Multi-output | Two physical devices with different clock/sample-rate behavior | Ordered route, reorder, member removal, aggregate teardown |
| Controls | Hardware media keys and global shortcuts | Accessibility denied/granted, tap disable/recovery, repeated start/stop |
| Widget | Small/medium/large widgets | App running, app closed, restart with queued command, stale host lease |

## Pass procedure

1. Start with no `Auralis-*` aggregate devices and an empty ownership journal.
2. Exercise volume, mute, boost, all ten EQ bands, every route type, and rapid route reordering while audio is continuous.
3. Unplug each selected output during playback, reconnect it, change the system default, and repeat across sleep/wake.
4. Revoke and restore Screen & System Audio Recording and Accessibility permissions; verify failures remain visible and recovery actions work.
5. Close the host, confirm widget controls are disabled, reopen it, and confirm new commands receive durable acknowledgments.
6. Quit normally and force-terminate once during an active multi-output session; relaunch and verify journal recovery.

A configuration passes only when there is no stuck-muted source, orphaned aggregate, lost ownership-journal handle, unacknowledged applied widget command, duplicate hotkey/media tap, non-finite audio, or audible output left after teardown. Attach the exact failing row and do not mark the release matrix complete with an unexplained skip.
