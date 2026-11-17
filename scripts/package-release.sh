#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ $# -lt 3 || $# -gt 4 || ! "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ||
      ! "$2" =~ ^[1-9][0-9]*$ || ( "$3" != arm64 && "$3" != x86_64 ) ]]; then
    echo "Usage: $0 VERSION BUILD_NUMBER ARCH [FILE_STEM]" >&2
    exit 2
fi
version="$1"
build_number="$2"
architecture="$3"
file_stem="${4-LumaLuma-$version-macos-$architecture}"
if [[ ! "$file_stem" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$file_stem" == *.dmg ]]; then
    echo "FILE_STEM must be a plain filename without the .dmg extension" >&2
    exit 2
fi

output_dir="$(pwd)/dist"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.release-XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT
payload="$staging_dir/payload"
LUMA_APP_VERSION="$version" LUMA_BUILD_NUMBER="$build_number" LUMA_APP_OUTPUT_DIR="$payload" \
    ./scripts/build-app.sh release "$architecture"
ln -s /Applications "$payload/Applications"

image="$file_stem.dmg"
hdiutil create -quiet -format UDZO -fs HFS+ -volname "Luma Luma" -srcfolder "$payload" "$staging_dir/$image"
./scripts/verify-dmg.sh "$staging_dir/$image" "$version" "$build_number" "$architecture"
(
    cd "$staging_dir"
    shasum -a 256 "$image" > "$image.sha256"
)
mv "$staging_dir/$image" "$staging_dir/$image.sha256" "$output_dir/"
printf '%s\n' "$output_dir/$image" "$output_dir/$image.sha256"
