#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration="${1:-release}"
architecture="${2:-native}"
if (( $# > 2 )); then
    echo "Usage: $0 [release|debug] [native|universal]" >&2
    exit 2
fi
case "$configuration" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug] [native|universal]" >&2; exit 2 ;;
esac
case "$architecture" in
    native|universal) ;;
    *) echo "Usage: $0 [release|debug] [native|universal]" >&2; exit 2 ;;
esac
app_version="${LUMA_APP_VERSION:-}"
build_number="${LUMA_BUILD_NUMBER:-}"
if [[ -n "$app_version" && ! "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "LUMA_APP_VERSION must contain three numeric version components" >&2
    exit 2
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "LUMA_BUILD_NUMBER must be a positive integer" >&2
    exit 2
fi

binary_dirs=()
if [[ "$architecture" == universal ]]; then
    for target in arm64 x86_64; do
        scratch=".build/universal/$target"
        swift build -c "$configuration" --arch "$target" --scratch-path "$scratch"
        binary_dirs+=("$(swift build -c "$configuration" --arch "$target" --scratch-path "$scratch" --show-bin-path)")
    done
else
    swift build -c "$configuration"
    binary_dirs+=("$(swift build -c "$configuration" --show-bin-path)")
fi
mkdir -p dist
staging_dir="$(mktemp -d "$(pwd)/dist/.build-XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
app="$staging_dir/Luma Luma.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
stage_binary() {
    local product="$1"
    local destination="$2"
    if [[ "$architecture" == universal ]]; then
        xcrun lipo -create "${binary_dirs[0]}/$product" "${binary_dirs[1]}/$product" -output "$destination"
    else
        cp "${binary_dirs[0]}/$product" "$destination"
    fi
}
stage_binary LumaLuma "$app/Contents/MacOS/LumaLuma"
stage_binary LumaLumaGammaHelper "$app/Contents/Helpers/LumaLumaGammaHelper"
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
if [[ -n "$app_version" ]]; then
    plutil -replace CFBundleShortVersionString -string "$app_version" "$app/Contents/Info.plist"
fi
if [[ -n "$build_number" ]]; then
    plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
fi
cp Packaging/LumaLuma.icns "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Helpers/LumaLumaGammaHelper"
codesign --force --sign - "$app"
codesign --verify --all-architectures --strict "$app/Contents/Helpers/LumaLumaGammaHelper"
codesign --verify --all-architectures --strict "$app"
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
