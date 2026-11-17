#!/bin/bash
set -euo pipefail

if [[ $# != 4 || ( "$4" != arm64 && "$4" != x86_64 ) ]]; then
    echo "Usage: $0 IMAGE VERSION BUILD_NUMBER ARCH" >&2
    exit 2
fi

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

repo="$(cd "$(dirname "$0")/.." && pwd)"
image="$1"
version="$2"
build_number="$3"
architecture="$4"
hdiutil verify -quiet "$image"
mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumaluma-dmg-XXXXXX")"
mounted=false
cleanup() {
    local status=$?
    if [[ "$mounted" == true ]]; then
        hdiutil detach -quiet "$mount_dir" || exit 1
    fi
    rmdir "$mount_dir" || exit 1
    exit "$status"
}
trap cleanup EXIT
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" "$image"
mounted=true

app="$mount_dir/Luma Luma.app"
[[ -d "$app" && ! -L "$app" ]] || fail "The disk image is missing the app bundle"
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]] || fail "The disk image is missing the Applications link"

plist="$app/Contents/Info.plist"
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

[[ "$(plist_value CFBundleShortVersionString)" == "$version" &&
   "$(plist_value CFBundleVersion)" == "$build_number" &&
   "$(plist_value CFBundleIdentifier)" == dev.illyes.lumaluma ]] || fail "Unexpected app version or bundle identity"
[[ "$(plist_value LSMinimumSystemVersion)" == 14.0 ]] || fail "Unexpected app deployment target"
cmp "$repo/LICENSE" "$app/Contents/Resources/LICENSE"
cmp "$repo/Packaging/LumaLuma.icns" "$app/Contents/Resources/LumaLuma.icns"

for binary in "$app/Contents/MacOS/LumaLuma" "$app/Contents/Helpers/LumaLumaGammaHelper"; do
    [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || fail "Missing executable ${binary##*/}"
    architectures="$(xcrun lipo -archs "$binary")"
    [[ "$architectures" == "$architecture" ]] || fail "Unexpected architecture for ${binary##*/}: $architectures (expected $architecture)"
    minimum="$(xcrun vtool -arch "$architecture" -show-build "$binary" | awk '$1 == "minos" { print $2 }')"
    [[ "$minimum" == 14.0 ]] || fail "Unexpected deployment target for ${binary##*/}: $minimum"
done

codesign --verify --deep --all-architectures --strict "$app"
