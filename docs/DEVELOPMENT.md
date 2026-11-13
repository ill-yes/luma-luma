# Developing Luma Luma

## Toolchain and commands

Use macOS 14 or newer and a Swift 6.0 or newer compiler from Xcode or the Xcode Command Line Tools. The local build environment uses Swift 6.4.2 on Apple silicon. The manifest's `swift-tools-version: 5.9` describes the package manifest format. Source code also uses standard-library APIs introduced in Swift 6.0.

Run the existing automated checks from the repository directory

```sh
./scripts/test-hdr.sh
```

The script compiles four standalone test executables with warnings treated as errors, runs them and removes its temporary test directory. The suites cover HDR stability and helper responses, native brightness-event routing, Boost decisions and hardware synchronization, and gamma ownership and restoration. Their helper and display backends use controlled fixtures.

Build the packaged app with

```sh
./scripts/build-app.sh
```

For a debug bundle, use

```sh
./scripts/build-app.sh debug
```

The build script compiles the app and helper for the host architecture, packages them with the icon and MIT License, checks the property list and applies local ad-hoc signatures. The completed bundle is `dist/Luma Luma.app`. Check the signature with

```sh
codesign --verify --deep --strict 'dist/Luma Luma.app'
```

`swift build` also compiles the package executables. Use the packaged app for runtime testing so that its helper, metadata and resources are in their expected locations. Generated products live in the ignored `.build` and `dist` directories.

## Package structure

| Target | Responsibility |
| --- | --- |
| `LumaLuma` | AppKit lifecycle, SwiftUI controls, preferences, shortcuts, display selection and rendering. |
| `LumaLumaGammaCore` | Display-curve representation, ownership, readback verification and restoration. |
| `LumaLumaGammaHelper` | Separate process that owns a gamma session and restores its baseline after release or disconnection. |

`Packaging` contains the app property list and icon. `scripts` contains the test runner, bundle builder and icon generator. `Tests` contains the standalone test programs.

## Rendering and brightness keys

For built-in full-display Boost, a small Metal EDR surface activates HDR headroom. The app waits for the headroom to remain stable for two seconds within an eight-second startup window. It then asks the helper to apply a per-display RGB transfer curve, capped by available headroom and a gain of 1.45.

External, half-display and front-window Boost use Metal compositing overlays. Front-window placement reads WindowServer metadata. Eclipse and Ring Light use click-through windows.

Native brightness keys are opt-in and use a Core Graphics event tap with macOS Accessibility permission. Routing uses the selected built-in display as its reference when available. At confirmed maximum hardware brightness, **Brighter** starts Boost in steps of `1/16`, or `1/64` with Shift–Option. The keyboard strength is kept separately from the saved manual setting. On the return to zero, curve restoration starts before later brightness-down events are handed to macOS.

Backlight reads and optional synchronization dynamically load Apple's private DisplayServices framework. Availability depends on macOS and the display. The routing code passes events to macOS when required hardware values or HDR support are unavailable. Synchronization writes the reference display first and records follower failures individually.

## Gamma ownership and restoration

The helper communicates through a private process pipe and holds a per-user lock for the lifetime of its session. It snapshots the baseline curve before applying a change. Boost uploads use at most 256 samples and are verified against the display's full table. Restoration writes the saved baseline at its original resolution.

A changed curve is restored only while the helper can establish ownership. An unrelated curve change ends ownership and reports a conflict. A pending write or temporarily offline display can keep restoration active, retaining the baseline and lock until the outcome can be resolved. A new session receives a busy response during that interval, and the app retries within its startup deadline.

Turning Boost off, sleep, lock and quit release the session. Pipe disconnection also triggers restoration when the main process exits unexpectedly. The helper's restoration state must remain available until cleanup completes.

## Validation and CI

The GitHub Actions workflow runs the test script and release bundle build on `macos-15` for pushes to `main` and pull requests. It uses read-only repository access. Its first hosted run remains pending until the repository is published and a workflow is triggered.

Physical MacBook brightness-key acceptance remains outstanding. On a supported MacBook with Accessibility permission, test single presses and held keys from the normal brightness range through HDR Boost and back, including Shift–Option steps. Observe both the macOS brightness value and RGB curve during the transition. Check display selection, partial synchronization failures where the hardware allows them, and restoration after Off, sleep, lock and quit.

Also inspect the menu bar icon in light and dark appearances and open **Settings…** from the menu. Automated fixture tests cover state and protocol behavior. Real HDR appearance, keyboard events, backlight changes and display restoration require these hardware checks.
