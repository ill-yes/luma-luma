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
if [[ "$configuration" == release ]]; then
    for binary in "$app/Contents/MacOS/LumaLuma" "$app/Contents/Helpers/LumaLumaGammaHelper"; do
        # Remove linker debug maps, including absolute paths to build objects.
        xcrun strip -S "$binary"
        scan_status=0
        LC_ALL=C grep -aFq \
            -e "$(pwd)/" -e '/Users/' -e '/home/' -e '/Volumes/' -e '/var/folders/' \
            "$binary" || scan_status=$?
        case "$scan_status" in
            0)
                printf 'Private build path found in release binary %s\n' "${binary##*/}" >&2
                exit 1
                ;;
            1) ;;
            *)
                printf 'Could not inspect release binary %s\n' "${binary##*/}" >&2
                exit 1
                ;;
        esac
    done
fi
cp Packaging/Info.plist "$app/Contents/"
cp Packaging/LumaLuma.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE"
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
