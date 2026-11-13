# Developing Luma Luma

## Toolchain and commands

Use macOS 14 or newer and a Swift 6.0 or newer compiler from Xcode or the Xcode Command Line Tools. The local build environment uses Swift 6.4.2 on Apple silicon. The manifest's `swift-tools-version: 5.9` describes the package manifest format. Source code also uses standard-library APIs introduced in Swift 6.0.

Run the existing automated checks from the repository directory

```sh
./scripts/test-hdr.sh
```

The script compiles five standalone test executables with warnings treated as errors, runs them and removes its temporary test directory. The suites cover effect selection and activation, HDR stability and helper responses, native brightness-event routing, Boost decisions and hardware synchronization, and gamma ownership and restoration. Their helper and display backends use controlled fixtures.

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

`LightingState` keeps the selected effect, enabled state and temporary keyboard strength together. Selecting an effect while disabled configures it for the next activation. Repeating the same selection or enabled value has no effect. A manual restart uses the saved slider strength. The controller starts renderer cleanup synchronously on deactivation or effect changes, so a quick off/on sequence releases the previous session before starting another.

For built-in full-display Boost, a small Metal EDR surface activates HDR headroom. The app waits for the headroom to remain stable for two seconds within an eight-second startup window. It then asks the helper to apply a per-display RGB transfer curve, capped by available headroom and a gain of 1.45.

If an active session loses headroom, it restores the curve and waits for cleanup to finish before starting a new attempt with the latest requested strength. That attempt has its own two-second stability check and eight-second deadline. A startup timeout, helper error or ownership conflict remains visible until an explicit new activation. Turning the effect off cancels pending recovery. The controls show preparation and restoration separately from confirmed active rendering.

External, half-display and front-window Boost use Metal compositing overlays. Front-window placement reads WindowServer metadata. Eclipse and Ring Light use click-through windows.

Native brightness keys are opt-in and use a Core Graphics event tap with macOS Accessibility permission. Routing uses the selected built-in display as its reference when available. At confirmed maximum hardware brightness, **Brighter** starts Boost in steps of `1/16`, or `1/64` with Shift–Option. The keyboard strength is kept separately from the saved manual setting. On the return to zero, curve restoration starts before later brightness-down events are handed to macOS.

Backlight reads and optional synchronization dynamically load Apple's private DisplayServices framework. Availability depends on macOS and the display. The routing code passes events to macOS when required hardware values or HDR support are unavailable. Synchronization writes the reference display first and records follower failures individually.

## Gamma ownership and restoration

The helper communicates through a private process pipe and holds a per-user lock for the lifetime of its session. It snapshots the baseline curve before applying a change. Boost uploads use at most 256 samples and are verified against the display's full table. Restoration writes the saved baseline at its original resolution.

A changed curve is restored only while the helper can establish ownership. An unrelated curve change ends ownership and reports a conflict. A pending write or temporarily offline display can keep restoration active, retaining the baseline and lock until the outcome can be resolved. A new session receives a busy response during that interval, and the app retries within its startup deadline.

Turning Boost off, sleep, lock and quit release the session. Pipe disconnection also triggers restoration when the main process exits unexpectedly. The helper's restoration state must remain available until cleanup completes.

## Validation and CI

The GitHub Actions workflow runs the test script and release bundle build on `macos-15` for pushes to `main` and pull requests. It uses read-only repository access. Its first hosted run remains pending until the repository is published and a workflow is triggered.

Native UI validation on macOS 27.2.1 with an Apple silicon MacBook covered disabled effect selection, enabled effect changes, repeated selection, settings tabs, rapid off/on, and full/half display changes. At a saved Boost strength of 100%, the built-in display reached an RGB curve gain of 1.45 automatically. Disabling restored all 1,024 samples per channel exactly and retained the macOS backlight value. Separate test bundles with controlled helper responses covered the preparing indicator, timeout and helper-error messages.

Physical MacBook brightness keys were tested on November 13, 2026, with Accessibility permission enabled. A Brighter press at maximum native brightness started Boost from Off and produced a measured RGB gain of 1.028125. Shift–Option increased it to 1.03515625 and decreased it back. Held Brighter presses applied successive HDR steps. Held Darker presses restored the baseline and then continued lowering native brightness. Individual presses also crossed back to native brightness. At the end, native brightness was back at 1 and all 1,024 samples in each RGB channel exactly matched the starting curve.

The test used the current app bundle after removing and re-adding an older permission entry. On German-language macOS 27, the permission is listed under **Datenschutz & Sicherheit → Gerätesteuerung und Datenzugriff**. Keep the tested bundle in place while validating permissions, since each ad-hoc rebuild has its own code identity.

Additional hardware coverage remains for synchronized external displays and restoration after sleep, lock and quit. Check display selection and partial synchronization failures where the hardware allows them.

Also inspect the menu bar icon in light and dark appearances and open **Settings…** from the menu. Automated fixture tests cover state and protocol behavior. Hardware checks establish real HDR appearance, keyboard events, backlight changes and display restoration for the tested device.
