# Auralis release artifacts

Auralis ships an intact `Auralis.app` containing the menu-bar host and widget.
Every deliverable is Apple Silicon-only and preserves the nested code signature.

## Choose the trust level

| Deliverable | Build on publisher Mac | Use on recipient Mac |
| --- | --- | --- |
| Notarized DMG | Developer ID Application certificate and notarytool profile | Normal Gatekeeper flow; no Apple account required |
| Unnotarized DMG | Apple Development or Developer ID certificate | Verify external checksum; macOS may require Open Anyway |
| Zip/tar public release | Developer ID Application certificate and notarytool profile | Installer/Homebrew automation |

There is no supported unsigned/ad-hoc Auralis distribution. A stable
certificate-backed designated requirement is needed for Screen Recording grants,
the widget, and App Group IPC. Notarization is what turns that signed build into
the normal Gatekeeper-friendly public artifact.

## Disk images

Create a local/community DMG:

```sh
Scripts/package-dmg.sh
```

This builds Release and writes:

```text
.build/release/Auralis-0.0.8-aarch64-apple-darwin-unnotarized.dmg
.build/release/Auralis-0.0.8-aarch64-apple-darwin-unnotarized.dmg.sha256
```

Create the normal public DMG:

```sh
REQUIRE_NOTARIZATION=YES \
NOTARY_PROFILE=your-profile \
SIGN_IDENTITY='Developer ID Application' \
Scripts/package-dmg.sh
```

This notarizes and staples both the app and disk image, then writes the same
names without `-unnotarized`. Use `SKIP_BUILD=YES APP_PATH=/path/Auralis.app`
to package an existing validated Release app.

Each image contains:

- `Auralis.app` with its embedded widget and original signatures;
- an `Applications` shortcut for drag installation;
- `Install Auralis.command`, a guided `~/Applications` installer; and
- `READ ME.txt` with permissions and Gatekeeper instructions.

The packager validates source and mounted copies, bundle IDs, arm64-only
executables, certificate class, matching signing teams, hardened runtime, DMG
structure, and external SHA-256. The guided installer never disables Gatekeeper
or removes quarantine. For an unnotarized build, use Apple’s supported Privacy &
Security → Open Anyway path only after verifying the download.

Verify before mounting:

```sh
shasum -a 256 -c Auralis-0.0.8-aarch64-apple-darwin-unnotarized.dmg.sha256
```

## Zip and tar release

On an arm64 Mac with a Developer ID Application identity and notarytool profile:

```sh
NOTARY_PROFILE=your-profile Scripts/package-release.sh
```

Writes:

| Asset | Example (`0.0.8`) |
| --- | --- |
| Zip (preferred; notarization + Homebrew) | `Auralis-0.0.8-aarch64-apple-darwin.zip` |
| tar.xz | `Auralis-0.0.8-aarch64-apple-darwin.tar.xz` |
| SHA-256 sums | `Auralis-0.0.8-SHA256SUMS` |

Install a verified prebuilt without compiling:

```sh
Scripts/install-prebuilt.sh --user
```

Canonical names live in `dist.toml` and `Scripts/lib/prebuilt.sh`. Git tags use
`v{version}` and the GitHub origin is `michaeltrannhan/aurelis`. The Homebrew Cask
template is `homebrew/auralis.rb`.

Do not distribute only `Auralis.app/Contents/MacOS/Auralis`; the full bundle is
required for its widget, entitlements, metadata, and signature.
