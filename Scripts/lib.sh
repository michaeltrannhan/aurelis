# Shared helpers for Auralis Scripts/. Source after setting SCRIPT_DIR.
# Canonical commands: ./install.sh, Scripts/auralis.sh {install|build|test|dev|release}
# Prebuilt names/unpack: Scripts/lib/prebuilt.sh (sourced by install-prebuilt.sh).

set -eu
set -o pipefail

if [ -z "${AURALIS_LIB_SH:-}" ]; then
    AURALIS_LIB_SH=1

    if [ -z "${SCRIPT_DIR:-}" ]; then
        SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    fi
    REPOSITORY_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

    # Pinned XcodeGen release (CI and local source builds share this).
    XCODEGEN_VERSION=2.45.4
    XCODEGEN_SHA256=090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef
    XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

    APP_PRODUCT_NAME=${APP_PRODUCT_NAME:-Auralis}
    APP_BUNDLE_ID=${APP_BUNDLE_ID:-com.michaeltrannhan.Auralis}
    WIDGET_NAME=${WIDGET_NAME:-AuralisWidget}
    WIDGET_BUNDLE_ID=${WIDGET_BUNDLE_ID:-com.michaeltrannhan.Auralis.Widget}

    fail() {
        printf 'error: %s\n' "$*" >&2
        exit 1
    }

    require_command() {
        command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
    }

    require_file() {
        [ -e "$1" ] || fail "required path not found: $1"
    }

    auralis_noninteractive() {
        case "${AURALIS_YES:-}" in YES|yes|true|TRUE|1) return 0 ;; esac
        case "${CI:-}" in true|TRUE|1) return 0 ;; esac
        [ -t 0 ] && [ -t 1 ] && return 1
        return 0
    }

    auralis_load_versions() {
        if [ -z "${MARKETING_VERSION:-}" ] || [ -z "${CURRENT_PROJECT_VERSION:-}" ]; then
            eval "$(
                /usr/bin/awk '
                    /MARKETING_VERSION:/ {
                        gsub(/[" \t]/, "", $2)
                        printf "MARKETING_VERSION=${MARKETING_VERSION:-%s}\n", $2
                    }
                    /CURRENT_PROJECT_VERSION:/ {
                        gsub(/[" \t]/, "", $2)
                        printf "CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION:-%s}\n", $2
                        exit
                    }
                ' "$REPOSITORY_ROOT/project.yml"
            )"
        fi
        [ -n "${MARKETING_VERSION:-}" ] || fail "could not read MARKETING_VERSION from project.yml"
        [ -n "${CURRENT_PROJECT_VERSION:-}" ] || fail "could not read CURRENT_PROJECT_VERSION from project.yml"
    }

    auralis_detect_platform() {
        AURALIS_OS=$(/usr/bin/uname -s)
        AURALIS_ARCH=$(/usr/bin/uname -m)
    }

    require_macos_arm64() {
        auralis_detect_platform
        [ "$AURALIS_OS" = Darwin ] ||
            fail "Auralis requires macOS (found '$AURALIS_OS')"
        [ "$AURALIS_ARCH" = arm64 ] ||
            fail "Auralis requires Apple Silicon (arm64); found '$AURALIS_ARCH'"
    }

    prepend_path() {
        export PATH="$1:$PATH"
        if [ -n "${GITHUB_PATH:-}" ]; then
            printf '%s\n' "$1" >>"$GITHUB_PATH"
        fi
    }

    xcodegen_install_root() {
        if [ -n "${AURALIS_XCODEGEN_ROOT:-}" ]; then
            printf '%s\n' "$AURALIS_XCODEGEN_ROOT"
        elif [ -n "${RUNNER_TEMP:-}" ]; then
            printf '%s\n' "$RUNNER_TEMP/auralis-xcodegen-$XCODEGEN_VERSION"
        else
            printf '%s\n' "$REPOSITORY_ROOT/.build/tools/xcodegen-$XCODEGEN_VERSION"
        fi
    }

    xcodegen_reported_version() {
        command -v xcodegen >/dev/null 2>&1 || return 1
        xcodegen --version 2>/dev/null | /usr/bin/awk '{ print $NF }'
    }

    # Install or reuse the pinned XcodeGen. Idempotent; CI-safe.
    ensure_xcodegen() {
        installed=$(xcodegen_reported_version || true)
        if [ "$installed" = "$XCODEGEN_VERSION" ]; then
            printf 'Using XcodeGen %s (%s)\n' "$XCODEGEN_VERSION" "$(command -v xcodegen)"
            return 0
        fi

        INSTALL_ROOT=$(xcodegen_install_root)
        BIN_DIR="$INSTALL_ROOT/bin"
        ZIP_PATH="$INSTALL_ROOT/xcodegen.zip"
        /bin/mkdir -p "$INSTALL_ROOT" "$BIN_DIR"

        if [ -x "$BIN_DIR/xcodegen" ]; then
            cached=$("$BIN_DIR/xcodegen" --version 2>/dev/null | /usr/bin/awk '{ print $NF }' || true)
            if [ "$cached" = "$XCODEGEN_VERSION" ]; then
                prepend_path "$BIN_DIR"
                printf 'Using cached XcodeGen %s at %s\n' "$XCODEGEN_VERSION" "$BIN_DIR"
                return 0
            fi
        fi

        require_command curl
        printf '==> Installing XcodeGen %s (sha256-verified)\n' "$XCODEGEN_VERSION"
        curl -fsSL "$XCODEGEN_URL" -o "$ZIP_PATH"
        ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$ZIP_PATH" | /usr/bin/awk '{ print $1 }')
        [ "$ACTUAL_SHA" = "$XCODEGEN_SHA256" ] ||
            fail "XcodeGen zip SHA-256 mismatch: expected $XCODEGEN_SHA256, got $ACTUAL_SHA"

        rm -rf "$INSTALL_ROOT/extract"
        mkdir -p "$INSTALL_ROOT/extract"
        /usr/bin/unzip -q "$ZIP_PATH" -d "$INSTALL_ROOT/extract"

        if [ -x "$INSTALL_ROOT/extract/bin/xcodegen" ]; then
            cp "$INSTALL_ROOT/extract/bin/xcodegen" "$BIN_DIR/xcodegen"
        elif [ -x "$INSTALL_ROOT/extract/xcodegen" ]; then
            cp "$INSTALL_ROOT/extract/xcodegen" "$BIN_DIR/xcodegen"
        elif [ -x "$INSTALL_ROOT/extract/xcodegen/bin/xcodegen" ]; then
            cp "$INSTALL_ROOT/extract/xcodegen/bin/xcodegen" "$BIN_DIR/xcodegen"
        else
            fail "could not locate xcodegen binary inside release zip"
        fi
        chmod +x "$BIN_DIR/xcodegen"

        VERSION=$("$BIN_DIR/xcodegen" --version 2>/dev/null | /usr/bin/awk '{ print $NF }')
        [ "$VERSION" = "$XCODEGEN_VERSION" ] ||
            fail "installed XcodeGen reports '$VERSION'; expected $XCODEGEN_VERSION"

        prepend_path "$BIN_DIR"
        printf 'Installed XcodeGen %s (sha256 verified) to %s\n' "$XCODEGEN_VERSION" "$BIN_DIR"
    }

    require_xcode_toolchain() {
        require_command swift
        require_command xcodebuild

        SWIFT_VERSION=$(swift --version 2>/dev/null | /usr/bin/awk 'NR==1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\.[0-9]/) { print $i; exit }
            }
        }')
        [ -n "$SWIFT_VERSION" ] || fail "could not parse Swift version"
        SWIFT_MAJOR=${SWIFT_VERSION%%.*}
        [ "$SWIFT_MAJOR" -ge 6 ] || fail "Swift >= 6 required; found '$SWIFT_VERSION'"

        XCODE_VERSION=$(xcodebuild -version 2>/dev/null | /usr/bin/awk 'NR==1 { print $2 }')
        [ -n "$XCODE_VERSION" ] || fail "could not parse Xcode version"
        XCODE_MAJOR=${XCODE_VERSION%%.*}
        XCODE_MINOR=$(printf '%s' "$XCODE_VERSION" | /usr/bin/awk -F. '{ print ($2 == "" ? 0 : $2) }')
        if [ "$XCODE_MAJOR" -lt 16 ] || { [ "$XCODE_MAJOR" -eq 16 ] && [ "$XCODE_MINOR" -lt 4 ]; }; then
            fail "Xcode >= 16.4 required; found '$XCODE_VERSION'"
        fi
    }

    auralis_ci_preflight() {
        require_macos_arm64
        require_xcode_toolchain
        require_command xcodegen
        installed=$(xcodegen_reported_version || true)
        [ "$installed" = "$XCODEGEN_VERSION" ] ||
            fail "XcodeGen $XCODEGEN_VERSION required; found '${installed:-unknown}'"

        printf 'ci-preflight ok: arch=%s swift=%s xcode=%s xcodegen=%s developer_dir=%s\n' \
            "$AURALIS_ARCH" \
            "$SWIFT_VERSION" \
            "$XCODE_VERSION" \
            "$installed" \
            "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || printf unknown)}"
    }

    quit_app_by_bundle_id() {
        /usr/bin/osascript -e "tell application id \"$1\" to quit" \
            >/dev/null 2>&1 || true
    }

    copy_app_bundle() {
        src=$1
        dest=$2
        [ -d "$src" ] || fail "app bundle not found: $src"
        /bin/mkdir -p "$(/usr/bin/dirname -- "$dest")" ||
            fail "cannot create $(/usr/bin/dirname -- "$dest") (check permissions)"
        dest_dir=$(/usr/bin/dirname -- "$dest")
        [ -w "$dest_dir" ] ||
            fail "cannot write to $dest_dir (try --user for a per-user install)"
        staged=$dest.auralis-staging
        /bin/rm -rf "$staged"
        /usr/bin/ditto "$src" "$staged" || fail "could not copy $src"
        /bin/rm -rf "$dest" || fail "cannot replace $dest (is it in use by another user?)"
        /bin/mv "$staged" "$dest"
    }

    # Copy a signed Auralis.app into /Applications or ~/Applications and
    # refresh the widget gallery. Used by install-app.sh and install-prebuilt.sh.
    auralis_install_bundle() {
        src_app=$1
        scope=$2
        launch=${3:-YES}

        case "$scope" in
            system)
                install_dir=/Applications
                other_app=$HOME/Applications/$APP_PRODUCT_NAME.app
                ;;
            user)
                install_dir=$HOME/Applications
                other_app=/Applications/$APP_PRODUCT_NAME.app
                ;;
            *) fail "unknown install scope: $scope" ;;
        esac

        if [ -d "$other_app" ]; then
            other_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \
                "$other_app/Contents/Info.plist" 2>/dev/null || true)
            [ "$other_id" = "$APP_BUNDLE_ID" ] &&
                fail "$APP_PRODUCT_NAME is already installed at $other_app; remove it first (duplicate bundle identifiers break the widget gallery)"
        fi

        target_app=$install_dir/$APP_PRODUCT_NAME.app
        quit_app_by_bundle_id "$APP_BUNDLE_ID"
        if [ -d "$target_app" ]; then
            printf '==> Replacing %s\n' "$target_app"
        fi
        copy_app_bundle "$src_app" "$target_app"
        /usr/bin/codesign --verify --deep --strict "$target_app" ||
            fail "installed app failed signature verification"
        printf '==> Installed %s\n' "$target_app"
        APP_PATH="$target_app" RELAUNCH_APP="$launch" \
            "$SCRIPT_DIR/refresh-widget-gallery.sh"
    }

    print_install_next_steps() {
        printf '==> Done. Next steps:\n'
        printf '    1. Grant Screen & System Audio Recording when prompted.\n'
        printf '    2. Grant Accessibility when prompted.\n'
        printf '    3. Click the date/time in the menu bar -> Edit Widgets -> search Auralis.\n'
    }
fi
