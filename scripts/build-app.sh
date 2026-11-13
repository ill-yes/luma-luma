#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac

swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p dist
staging_dir="$(mktemp -d "$(pwd)/dist/.build-XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
app="$staging_dir/Luma Luma.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$binary_dir/LumaLuma" "$app/Contents/MacOS/"
cp "$binary_dir/LumaLumaGammaHelper" "$app/Contents/Helpers/"
cp Packaging/Info.plist "$app/Contents/"
cp Packaging/LumaLuma.icns "$app/Contents/Resources/"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Helpers/LumaLumaGammaHelper"
codesign --force --sign - "$app"
codesign --verify --strict "$app/Contents/Helpers/LumaLumaGammaHelper"
codesign --verify --strict "$app"
destination="$(pwd)/dist/Luma Luma.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging_dir/previous.app"
fi
if ! mv "$app" "$destination"; then
    if [[ -e "$staging_dir/previous.app" ]]; then
        mv "$staging_dir/previous.app" "$destination"
    fi
    exit 1
fi
printf '%s\n' "$destination"
