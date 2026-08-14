# Auralis release bundles

Prebuilt install without compiling. The product is `Auralis.app` (menu-bar app + widget), Apple Silicon only. Canonical names live in `dist.toml` and `Scripts/lib/prebuilt.sh`.

## Build the bundle

On an arm64 Mac with a Developer ID Application identity and a notarytool keychain profile:

```sh
NOTARY_PROFILE=your-profile Scripts/package-release.sh
```

Writes three files under `.build/release/`:

| Asset | Example (`0.0.8`) |
| --- | --- |
| Zip (preferred; notarization + Homebrew) | `Auralis-0.0.8-aarch64-apple-darwin.zip` |
| tar.xz (`curl \| tar -xJ`) | `Auralis-0.0.8-aarch64-apple-darwin.tar.xz` |
| SHA-256 sums | `Auralis-0.0.8-SHA256SUMS` |

Each archive has `Auralis.app` at its root. Target triple: `aarch64-apple-darwin` (Apple `arm64`). Git tag: `v0.0.8`.

## Install without compiling

```sh
Scripts/install-prebuilt.sh --user
```

Or, after a GitHub Release exists:

```sh
v=0.0.8
base=https://github.com/michaeltrannhan/aurelis/releases/download/v$v
curl -fsSL "$base/Auralis-$v-aarch64-apple-darwin.zip" -o /tmp/Auralis.zip
curl -fsSL "$base/Auralis-$v-SHA256SUMS" -o /tmp/Auralis-$v-SHA256SUMS
( cd /tmp && /usr/bin/shasum -a 256 -c "Auralis-$v-SHA256SUMS" )
/usr/bin/ditto -x -k /tmp/Auralis.zip ~/Applications
```

tar.xz variant (macOS `tar`, Apple Silicon):

```sh
curl -fsSL "$base/Auralis-$v-aarch64-apple-darwin.tar.xz" | tar -xJ -C ~/Applications
```

Homebrew Cask template: `homebrew/auralis.rb`.

Do not put `Auralis.app/Contents/MacOS/Auralis` on `PATH` by itself; the widget and code signature require the full bundle in `/Applications` or `~/Applications`.
