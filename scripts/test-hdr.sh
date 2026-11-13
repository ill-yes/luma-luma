#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build
test_dir="$(mktemp -d "$(pwd)/.build/hdr-tests-XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLuma/GammaBoostSession.swift Tests/LumaLumaTests/*.swift \
    -o "$test_dir/hdr-gate"
"$test_dir/hdr-gate"

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLumaGammaCore/*.swift Tests/LumaLumaGammaCoreTests/*.swift \
    -o "$test_dir/gamma-restoration"
"$test_dir/gamma-restoration"
