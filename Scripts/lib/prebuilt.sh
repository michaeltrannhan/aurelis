# Shared GitHub-release asset names and unpack helpers for Auralis.
# Sourced by Scripts/package-release.sh and Scripts/install-prebuilt.sh.
# POSIX sh. Does not change directory.

AURALIS_DIST_PACKAGE_NAME=Auralis
AURALIS_DIST_APP_NAME=Auralis.app
AURALIS_DIST_TARGET=aarch64-apple-darwin
AURALIS_DIST_LICENSE=GPL-3.0-or-later
AURALIS_DIST_GITHUB_OWNER=${AURALIS_DIST_GITHUB_OWNER:-michaeltrannhan}
AURALIS_DIST_GITHUB_REPO=${AURALIS_DIST_GITHUB_REPO:-aurelis}

auralis_dist_fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

auralis_dist_archive_basename() {
    # usage: auralis_dist_archive_basename VERSION
    printf '%s-%s-%s' "$AURALIS_DIST_PACKAGE_NAME" "$1" "$AURALIS_DIST_TARGET"
}

auralis_dist_zip_name() {
    printf '%s.zip' "$(auralis_dist_archive_basename "$1")"
}

auralis_dist_tarball_name() {
    printf '%s.tar.xz' "$(auralis_dist_archive_basename "$1")"
}

auralis_dist_checksums_name() {
    printf '%s-%s-SHA256SUMS' "$AURALIS_DIST_PACKAGE_NAME" "$1"
}

auralis_dist_tag() {
    printf 'v%s' "$1"
}

auralis_dist_asset_url() {
    # usage: auralis_dist_asset_url VERSION ASSET_FILENAME
    printf 'https://github.com/%s/%s/releases/download/v%s/%s' \
        "$AURALIS_DIST_GITHUB_OWNER" "$AURALIS_DIST_GITHUB_REPO" "$1" "$2"
}

auralis_dist_latest_version() {
    latest_url="https://github.com/${AURALIS_DIST_GITHUB_OWNER}/${AURALIS_DIST_GITHUB_REPO}/releases/latest"
    resolved=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url") ||
        auralis_dist_fail "could not resolve latest GitHub release"
    tag=${resolved##*/}
    case "$tag" in
        v[0-9]*) printf '%s\n' "${tag#v}" ;;
        *) auralis_dist_fail "latest release URL did not end in a v* tag: $resolved" ;;
    esac
}

auralis_dist_require_arm64() {
    arch=$(/usr/bin/uname -m)
    [ "$arch" = arm64 ] ||
        auralis_dist_fail "Auralis prebuilt archives are Apple Silicon (arm64) only; found '$arch'"
}

auralis_dist_write_checksums() {
    # usage: auralis_dist_write_checksums OUTPUT_DIR VERSION
    output_dir=$1
    version=$2
    checksums=$output_dir/$(auralis_dist_checksums_name "$version")
    zip_name=$(auralis_dist_zip_name "$version")
    tarball_name=$(auralis_dist_tarball_name "$version")
    [ -f "$output_dir/$zip_name" ] || auralis_dist_fail "missing zip: $output_dir/$zip_name"
    [ -f "$output_dir/$tarball_name" ] || auralis_dist_fail "missing tarball: $output_dir/$tarball_name"
    (cd "$output_dir" && /usr/bin/shasum -a 256 "$zip_name" "$tarball_name") >"$checksums" ||
        auralis_dist_fail "could not write $checksums"
}

auralis_dist_verify_checksums() {
    # usage: auralis_dist_verify_checksums CHECKSUMS_FILE DIRECTORY
    checksums=$1
    directory=$2
    [ -f "$checksums" ] || auralis_dist_fail "checksums file not found: $checksums"
    (cd "$directory" && /usr/bin/shasum -a 256 -c "$(/usr/bin/basename "$checksums")") ||
        auralis_dist_fail "SHA-256 verification failed"
}

auralis_dist_verify_asset() {
    # usage: auralis_dist_verify_asset CHECKSUMS_FILE DIRECTORY ASSET_NAME
    checksums=$1
    directory=$2
    asset=$3
    [ -f "$checksums" ] || auralis_dist_fail "checksums file not found: $checksums"
    [ -f "$directory/$asset" ] || auralis_dist_fail "asset not found: $directory/$asset"
    expected=$(/usr/bin/awk -v name="$asset" '$2 == name { print $1; exit }' "$checksums")
    [ -n "$expected" ] || auralis_dist_fail "no SHA-256 for $asset in $checksums"
    actual=$(/usr/bin/shasum -a 256 "$directory/$asset" | /usr/bin/awk '{ print $1 }')
    [ "$actual" = "$expected" ] ||
        auralis_dist_fail "SHA-256 mismatch for $asset: expected $expected, got $actual"
}

auralis_dist_unpack_zip() {
    # usage: auralis_dist_unpack_zip ARCHIVE DEST_DIR
    archive=$1
    dest=$2
    /bin/mkdir -p "$dest"
    /usr/bin/ditto -x -k "$archive" "$dest" ||
        auralis_dist_fail "could not unpack zip: $archive"
}

auralis_dist_unpack_tarball() {
    # usage: auralis_dist_unpack_tarball ARCHIVE DEST_DIR
    archive=$1
    dest=$2
    /bin/mkdir -p "$dest"
    /usr/bin/tar -xJf "$archive" -C "$dest" ||
        auralis_dist_fail "could not unpack tarball: $archive"
}

auralis_dist_create_zip() {
    # usage: auralis_dist_create_zip APP_PATH ZIP_PATH
    app_path=$1
    zip_path=$2
    /bin/mkdir -p "$(/usr/bin/dirname "$zip_path")"
    /bin/rm -f "$zip_path"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path" ||
        auralis_dist_fail "could not create zip: $zip_path"
}

auralis_dist_create_tarball() {
    # usage: auralis_dist_create_tarball APP_PATH TARBALL_PATH
    app_path=$1
    tarball_path=$2
    app_dir=$(/usr/bin/dirname "$app_path")
    app_base=$(/usr/bin/basename "$app_path")
    /bin/mkdir -p "$(/usr/bin/dirname "$tarball_path")"
    /bin/rm -f "$tarball_path"
    /usr/bin/tar -C "$app_dir" -cJf "$tarball_path" "$app_base" ||
        auralis_dist_fail "could not create tarball: $tarball_path"
}
