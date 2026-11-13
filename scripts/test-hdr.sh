#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build
test_dir="$(mktemp -d "$(pwd)/.build/hdr-tests-XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLuma/LightingState.swift Tests/LumaLumaTests/LightingStateTests.swift \
    -o "$test_dir/lighting-state"
"$test_dir/lighting-state"

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLuma/GammaBoostSession.swift Tests/LumaLumaTests/GammaBoostSessionTests.swift \
    -o "$test_dir/hdr-gate"
"$test_dir/hdr-gate"

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLuma/Shortcuts.swift Tests/LumaLumaTests/BrightnessEventTests.swift \
    -o "$test_dir/brightness-events"
"$test_dir/brightness-events"

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLuma/BrightnessKeyRouting.swift Tests/LumaLumaTests/BrightnessKeyRoutingTests.swift \
    -o "$test_dir/brightness-routing"
"$test_dir/brightness-routing"

swiftc -parse-as-library -warnings-as-errors \
    Sources/LumaLumaGammaCore/*.swift Tests/LumaLumaGammaCoreTests/*.swift \
    -o "$test_dir/gamma-restoration"
"$test_dir/gamma-restoration"
