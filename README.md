# Luma Luma

Luma Luma is an MIT-licensed macOS menu bar app for using the extra HDR brightness of XDR displays. All controls work locally and are available without an account or license key.

## Build and run

Use macOS 14 or newer and the Xcode Command Line Tools with Swift 5.9 or newer.

```sh
./scripts/build-app.sh
open 'dist/Luma Luma.app'
```

The build produces a locally ad-hoc-signed app for the Mac it was built on. Move it to Applications before enabling **Open at login**. Click the sunrise icon in the menu bar for the controls and **Settings…**, or right-click to toggle the last effect. You can also reopen the app from Finder to reach its controls.

## Controls

| Control | Behavior |
| --- | --- |
| Boost | Adds brightness on selected HDR displays. Choose the full display, a half-screen comparison or the frontmost window. |
| Eclipse | Dims selected displays below their normal settings. |
| Ring Light | Adds a screen-edge fill light for video calls, with adjustable intensity, width and warmth. |
| Power automation | Enable boost on external power or while the battery is above a chosen level. |
| Shortcuts | Assign global toggle, increase and decrease keys. Native display brightness keys and Apple backlight sync are optional. |

For **Entire display** on a built-in XDR display, set macOS display brightness to maximum and then adjust the **Boost** slider. At 100%, Luma Luma requests a 1.45 RGB transfer-curve factor. macOS controls available HDR headroom based on the display, brightness preset, power and temperature. The slider does not report nits.

Quit other apps that modify display curves before using built-in full-display Boost. If the curve changes after Luma Luma starts, it reports a conflict. Turning Boost off, sleeping, locking or quitting ends the effect and restores the baseline curve if Luma Luma still owns it.

Custom keyboard shortcuts use Carbon global hotkeys. The brightness indicator can be switched off in **Settings → Shortcuts**. Enable **Use display brightness keys** there and grant Luma Luma Accessibility access in System Settings. At maximum macOS brightness, the next **Brighter** press starts HDR boost, including from **Off**. **Darker** steps through HDR and returns to macOS brightness at zero. Hold Shift and Option for smaller steps. The keyboard level is temporary. Manual Boost uses the saved slider setting. Hardware sync uses DisplayServices when at least two selected Apple displays report backlight control.

In macOS Shortcuts, use the built-in **Open URLs** action with `lumaluma://on`, `lumaluma://off`, or `lumaluma://toggle`. The app bundle registers these three commands with macOS.

## Implementation

Luma Luma is an independent Swift/AppKit and SwiftUI implementation. Built-in full-display Boost presents a small EDR Metal trigger and waits for the current HDR headroom to stabilize. A bundled helper applies and verifies the per-display RGB transfer curve. It restores the saved curve when the app releases it or closes its private pipe, including when the app process exits unexpectedly. External, half-display and front-window boost use a Metal compositing overlay. Eclipse and Ring Light use click-through windows. Focus mode uses WindowServer metadata and requires no screen recording.

The built-in path uploads 256 RGB samples and checks the result against the display's full table. It uses extended values accepted by the tested macOS version. Luma Luma reports a failure if macOS declines the write or the curve does not read back as expected. If the system accepts a write whose result remains uncertain, the helper retains the saved baseline and keeps checking at low frequency before another session can start. Use `./scripts/test-hdr.sh` for the state and restoration tests.
