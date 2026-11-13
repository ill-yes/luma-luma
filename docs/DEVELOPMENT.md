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

For a Universal app containing both `arm64` and `x86_64` code, run

```sh
./scripts/build-app.sh release universal
```

Both the app and gamma helper are built for each architecture, then merged with `lipo`. Optional `LUMA_APP_VERSION` and `LUMA_BUILD_NUMBER` values set the packaged app's version. For example, to build and validate a versioned Universal ZIP and its SHA-256 checksum, run

```sh
./scripts/package-release.sh 1.0.0 3
```

This produces `dist/LumaLuma-1.0.0-macos-universal.zip` and `dist/LumaLuma-1.0.0-macos-universal.zip.sha256`. Packaging checks the two architectures, macOS 14 deployment target, version fields, signatures, bundled license and icon. It also unpacks the ZIP and verifies the resulting app.

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
| `Tests` | Standalone state, automation, event-routing, helper-protocol and gamma-ownership tests. |
| `Packaging` | App property list and icon. |
| `scripts` | Test runner, app builder and icon generator. |
| `docs` | User guidance, development information and validation evidence. |

## 💡 Effect state and rendering

`LightingState` stores the selected effect, enabled state and temporary keyboard strength. Selecting an effect while disabled prepares it for the next activation. Repeating the same selection or enabled value has no effect. A manual restart uses the saved slider strength.

The controller starts renderer cleanup synchronously on deactivation or effect changes. A quick off/on sequence therefore releases the previous session before a new session acquires the helper.

For built-in full-display Boost, a small Metal EDR surface activates HDR headroom. The app waits for two seconds of stable headroom within an eight-second startup window. It then requests a per-display RGB transfer curve, capped by available headroom and a gain of 1.45.

If an active session loses headroom, it restores the curve and waits for cleanup to finish before starting a new attempt with the latest requested strength. Each attempt has its own stability check and startup deadline. A timeout, helper error or ownership conflict remains visible until a new activation. Turning the effect off cancels pending recovery.

External, half-display and front-window Boost use Metal compositing overlays. Front-window placement reads WindowServer metadata. Eclipse and Ring Light use click-through windows.

### Display profiles and brightness transitions

The controller resolves the display group and individual participation before it builds a render target for each selected display. Optional profile fields override the global effect values. Preferences store profiles keyed by unique Core Graphics display UUID. A display without a unique UUID gets overrides for the current connection. Native brightness is read from the display on reconnect.

The slider uses the Apple brightness adapter for native levels. Crossing into HDR writes native maximum when needed and reads it back before requesting Boost for the target. Returning to the native range removes that display's Boost. For the built-in RGB curve, an explicit restoration result controls the native write. The controller waits for a confirmed restore or a result indicating that no restoration is needed. Conflicts and unconfirmed restores cancel the write.

The pending request tracks the latest slider value. The controller checks the selected display and its identity again before applying a deferred change. Target changes, display reconfiguration and pause events invalidate outstanding slider requests. Other monitors can keep rendering throughout a transition.

The renderer reports each target's requested strength, confirmed RGB curve gain or presented Metal overlay gain, and current and potential EDR headroom. The Diagnostics tab shows these values and the render status. The clipboard report omits identifying display information and local paths.

## ⌨️ Brightness-key routing

Native brightness keys are opt-in and use a Core Graphics event tap with macOS Accessibility permission. The selected built-in display is the reference when available. At confirmed maximum hardware brightness, **Brighter** starts Boost in steps of `1/16`, or `1/64` with **Shift–Option**. The keyboard strength is separate from the saved manual setting.

On the return to zero, curve restoration starts before subsequent brightness-down events reach macOS. Token checks reject stale helper replies after a stopped or replaced session. Recovery also waits for an outstanding command callback, so a delayed conflict or error remains terminal.

Backlight reads and writes dynamically load Apple's private DisplayServices framework for the slider and optional key synchronization. Availability depends on macOS and the display. Events pass to macOS when required hardware values or HDR support are unavailable. Synchronization writes the reference display first and records follower failures individually.

## 🌤️ Ambient Boost

The sensor adapter uses IOKit registry reads to find the integrated light sensor and read its `CurrentLux` property. The service class and property keys are undocumented. A missing, ambiguous or invalid reading is reported as unavailable.

The controller combines a participating, active built-in HDR display, a verified native level at maximum and the power rule into a single eligibility check. The policy processes lux readings on a two-second timer. It requires four seconds at or above the activation threshold and eight seconds at or below the deactivation threshold, with six seconds of tolerance for missing readings. Auto-Boost owns only the effect it started. Manual disable or dimming suppresses automatic activation until a confirmed dark period. Pause events release automatic Boost and clear the sample history before polling resumes.

## 🔄 Gamma ownership and restoration

The helper communicates through a private process pipe and holds a per-user lock for its session. It snapshots the baseline curve before applying a change. Boost uploads use at most 256 samples and are verified against the display's full table. Restoration writes the saved baseline at its original resolution.

A curve is restored only while the helper can establish ownership. An unrelated curve change ends ownership and reports a conflict. A pending write or temporarily offline display can keep restoration active, retaining the baseline and lock until the result can be resolved. During that interval, a new session receives a busy response and the app retries within its startup deadline.

Turning Boost off, sleeping, locking and quitting release the session. Pipe disconnection also triggers restoration if the main process exits unexpectedly.

## ✅ Tests and CI

`./scripts/test-hdr.sh` compiles the standalone test executables with warnings treated as errors. It runs each suite and removes its temporary test directory. Review the suite coverage and measured hardware results. [Validation](VALIDATION.md)

The **Build and test** GitHub Actions workflow runs the tests and release bundle build on `macos-15` for pushes to `main` and pull requests. It uses read-only repository access, compares the bundled license and verifies the app signature. The first hosted run passed at commit `b26d61d`. [CI result](https://github.com/ill-yes/luma-luma/actions/runs/43431125097)

### Manual releases

Open **Actions → Release LumaLuma → Run workflow** and select the ref to build. The default is `main`; the workflow builds the commit fixed at dispatch time. The workflow definition is `.github/workflows/release.yml`.

Workflow runs 1 and 2 use versions `0.1.1` and `0.1.2`. Run 3 uses `1.0.0`. Later runs use `1.0.<github.run_number − 3>`. The build number remains `github.run_number`. A re-run keeps its original version. Failed runs can leave gaps. The shared release concurrency group processes runs one at a time and can queue up to 100 waiting runs.

The build job runs the tests and creates the Universal ZIP and checksum. Only the publishing job receives `contents: write`. It uploads and verifies both files in a draft before publishing the release. A re-run resumes its own draft or verifies its already published release. Version and commit conflicts fail with an error. The highest published version is designated **Latest**.

Intermediate build artifacts are retained for seven days. To retry a failed publication after they expire, choose **Re-run all jobs** to rebuild the download for the same version.

GitHub requires additional workflow permissions when the release commit changes files under `.github/workflows/` relative to the current default branch. The built-in `GITHUB_TOKEN` cannot receive that permission. If such a release write fails with HTTP 403 or 404, start a new release from a ref whose workflow files match the default branch, or have a maintainer complete the release with the required workflow access. [GitHub release permissions](https://docs.github.com/en/rest/releases/releases#create-a-release)

Release checks can be run locally with

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
```

The release notes link to installation instructions and identify the version, source commit and workflow run. Downloads use ad-hoc signing, so macOS may request first-launch approval. [Release downloads](https://github.com/ill-yes/luma-luma/releases/latest)
