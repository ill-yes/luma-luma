# 🛠️ Development

Build, test and understand Luma Luma's native macOS implementation.

[Project overview](../README.md) · [User guide](USAGE.md) · [Validation](VALIDATION.md) · [Contributing](../CONTRIBUTING.md)

## 🚀 Local setup

Use macOS 14 or newer and Xcode or the Xcode Command Line Tools with Swift 6.0 or newer. The locally tested compiler is Swift 6.4.2 on Apple silicon. `swift-tools-version: 5.9` declares the package manifest format, while the source uses standard-library APIs introduced in Swift 6.0.

From the repository root, run

```sh
./scripts/test-hdr.sh
./scripts/build-app.sh
open 'dist/Luma Luma.app'
```

For a debug app bundle, use

```sh
./scripts/build-app.sh debug
```

`swift build` also compiles the package executables. Use the packaged app for runtime testing so that its helper, metadata and resources are available at the expected paths.

## 📦 Build and packaging

The build script compiles the app and helper for the host architecture. It packages the icon and MIT License, validates the property list, and applies local ad-hoc signatures. The output is `dist/Luma Luma.app`.

Release packaging strips linker debug metadata from both executables before signing. It then scans the executable bytes for the checkout path and private home, volume and temporary-directory paths. A match or scan error fails the build before the staged bundle is installed. Debug builds retain their symbols for local debugging.

Verify the result with

```sh
codesign --verify --deep --strict 'dist/Luma Luma.app'
cmp LICENSE 'dist/Luma Luma.app/Contents/Resources/LICENSE'
```

After replacing an ad-hoc build, macOS may require you to grant brightness-key access again. If this happens, re-add the current app in macOS privacy settings. [User guide](USAGE.md)

Generated products are stored in the ignored `.build` and `dist` directories. The bundled app contains the same MIT License as the source repository.

### App icon

The README and app icon share the source image at `docs/assets/luma-luma.png`. After updating it, regenerate the icon family and rebuild the app.

```sh
swift scripts/make-icon.swift dist/LumaLuma.iconset
iconutil --convert icns dist/LumaLuma.iconset --output Packaging/LumaLuma.icns
./scripts/build-app.sh
```

## 🧩 Repository structure

| Path or target | Purpose |
| --- | --- |
| `Sources/LumaLuma` | AppKit lifecycle, SwiftUI controls, preferences, shortcuts and display rendering. |
| `Sources/LumaLumaGammaCore` | Display-curve representation, ownership, verification and restoration. |
| `Sources/LumaLumaGammaHelper` | Separate process that owns a gamma session and handles release or disconnection. |
| `Tests` | Standalone state, event-routing, helper-protocol and gamma-ownership tests. |
| `Packaging` | App property list and icon. |
| `scripts` | Test runner, app builder and icon generator. |
| `docs` | User guidance, development information and validation evidence. |

## 💡 Effect state and rendering

`LightingState` stores the selected effect, enabled state and temporary keyboard strength. Selecting an effect while disabled prepares it for the next activation. Repeating the same selection or enabled value has no effect. A manual restart uses the saved slider strength.

The controller starts renderer cleanup synchronously on deactivation or effect changes. A quick off/on sequence therefore releases the previous session before a new session acquires the helper.

For built-in full-display Boost, a small Metal EDR surface activates HDR headroom. The app waits for two seconds of stable headroom within an eight-second startup window. It then requests a per-display RGB transfer curve, capped by available headroom and a gain of 1.45.

If an active session loses headroom, it restores the curve and waits for cleanup to finish before starting a new attempt with the latest requested strength. Each attempt has its own stability check and startup deadline. A timeout, helper error or ownership conflict remains visible until a new activation. Turning the effect off cancels pending recovery.

External, half-display and front-window Boost use Metal compositing overlays. Front-window placement reads WindowServer metadata. Eclipse and Ring Light use click-through windows.

## ⌨️ Brightness-key routing

Native brightness keys are opt-in and use a Core Graphics event tap with macOS Accessibility permission. The selected built-in display is the reference when available. At confirmed maximum hardware brightness, **Brighter** starts Boost in steps of `1/16`, or `1/64` with **Shift–Option**. The keyboard strength is separate from the saved manual setting.

On the return to zero, curve restoration starts before subsequent brightness-down events reach macOS. Token checks reject stale helper replies after a stopped or replaced session. Recovery also waits for an outstanding command callback, so a delayed conflict or error remains terminal.

Backlight reads and optional synchronization dynamically load Apple's private DisplayServices framework. Availability depends on macOS and the display. Events pass to macOS when required hardware values or HDR support are unavailable. Synchronization writes the reference display first and records follower failures individually.

## 🔄 Gamma ownership and restoration

The helper communicates through a private process pipe and holds a per-user lock for its session. It snapshots the baseline curve before applying a change. Boost uploads use at most 256 samples and are verified against the display's full table. Restoration writes the saved baseline at its original resolution.

A curve is restored only while the helper can establish ownership. An unrelated curve change ends ownership and reports a conflict. A pending write or temporarily offline display can keep restoration active, retaining the baseline and lock until the result can be resolved. During that interval, a new session receives a busy response and the app retries within its startup deadline.

Turning Boost off, sleeping, locking and quitting release the session. Pipe disconnection also triggers restoration if the main process exits unexpectedly.

## ✅ Tests and CI

`./scripts/test-hdr.sh` compiles five standalone test executables with warnings treated as errors. It runs each suite and removes its temporary test directory. Review the suite coverage and measured hardware results. [Validation](VALIDATION.md)

The GitHub Actions workflow runs the tests and release bundle build on `macos-15` for pushes to `main` and pull requests. It uses read-only repository access, compares the bundled license and verifies the app signature. The first hosted run is pending publication and a workflow trigger.
