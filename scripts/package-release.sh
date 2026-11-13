#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $# != 2 || ! "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 VERSION BUILD_NUMBER" >&2
    exit 2
fi
version="$1"
build_number="$2"
LUMA_APP_VERSION="$version" LUMA_BUILD_NUMBER="$build_number" ./scripts/build-app.sh release universal

verify_bundle() {
    local bundle="$1"
    local plist="$bundle/Contents/Info.plist"
    local binary target minimum architectures
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.illyes.lumaluma ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 14.0 ]]
    cmp LICENSE "$bundle/Contents/Resources/LICENSE"
    cmp Packaging/LumaLuma.icns "$bundle/Contents/Resources/LumaLuma.icns"
    codesign --verify --deep --all-architectures --strict "$bundle"
    for binary in "$bundle/Contents/MacOS/LumaLuma" "$bundle/Contents/Helpers/LumaLumaGammaHelper"; do
        architectures=" $(xcrun lipo -archs "$binary") "
        if [[ "$architectures" != *" arm64 "* || "$architectures" != *" x86_64 "* ]]; then
            echo "Missing Universal architecture in ${binary##*/}:$architectures" >&2
            return 1
        fi
        for target in arm64 x86_64; do
            minimum="$(xcrun vtool -arch "$target" -show-build "$binary" | awk '$1 == "minos" { print $2 }')"
            if [[ "$minimum" != 14.0 ]]; then
                echo "Unexpected deployment target for ${binary##*/} ($target): $minimum" >&2
                return 1
            fi
        done
    done
}

app="$(pwd)/dist/Luma Luma.app"
verify_bundle "$app"
staging_dir="$(mktemp -d "$(pwd)/dist/.release-XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
archive="LumaLuma-$version-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging_dir/$archive"
(
    cd "$staging_dir"
    shasum -a 256 "$archive" > "$archive.sha256"
)
ditto -x -k "$staging_dir/$archive" "$staging_dir/unpacked"
verify_bundle "$staging_dir/unpacked/Luma Luma.app"
diff -r "$app" "$staging_dir/unpacked/Luma Luma.app"
mv "$staging_dir/$archive" "dist/$archive"
mv "$staging_dir/$archive.sha256" "dist/$archive.sha256"
printf '%s\n' "$(pwd)/dist/$archive" "$(pwd)/dist/$archive.sha256"
