# Luma Luma

Luma Luma is an MIT-licensed macOS menu bar app for HDR brightness, extra dimming and a screen-edge fill light. It provides local controls for selected built-in and external displays.

## Requirements

- macOS 14 or newer.
- Xcode or the Xcode Command Line Tools with Swift 6.0 or newer to build from source.
- An HDR-capable display for Boost. Available brightness depends on the display and the headroom macOS exposes.

## Build and run

From the repository directory, run

```sh
./scripts/build-app.sh
open 'dist/Luma Luma.app'
```

The script creates a release build for the current Mac's architecture and signs the app locally with an ad-hoc signature. Move `Luma Luma.app` to Applications before enabling **Open at login**.

Click the sunrise icon in the menu bar to choose a mode, adjust its strength, open **Settings…** or quit. The sun has a filled center while an effect is active. Right-click the icon to toggle the last effect. Reopening the app from Finder opens its controls.

## Controls

| Control | Behavior |
| --- | --- |
| Boost | Uses HDR brightness on selected displays. Choose **Entire display**, **Half display (compare)** or **Front window**. |
| Eclipse | Adds dimming below the display's normal brightness setting. |
| Ring Light | Adds a screen-edge fill light with adjustable intensity, width and warmth. |
| Display selection | Applies effects to all displays, the built-in display or external displays. |
| Power automation | Enables Boost on external power or above a chosen battery level. |
| Shortcuts | Assigns global toggle, increase and decrease keys, with an optional brightness indicator. |

For **Entire display** on a built-in XDR display, set macOS brightness to maximum and adjust the **Boost** slider. At full strength, Luma Luma requests an RGB transfer-curve gain of up to 1.45, limited by current HDR headroom. The slider represents effect strength. Display presets, power and temperature also affect the brightness macOS makes available.

Close other display-curve utilities before using built-in full-display Boost. Luma Luma reports a conflict if another process changes its curve. Turning the effect off, sleeping, locking or quitting starts restoration of the saved baseline while Luma Luma retains ownership of the curve.

## MacBook brightness keys

In **Settings… → Shortcuts**, enable **Use display brightness keys**. Grant Luma Luma access in **System Settings → Privacy & Security → Accessibility**, then toggle the option off and on.

At maximum macOS brightness, the next **Brighter** press starts HDR Boost on a supported selected display, including from **Off**. Further presses increase the effect. **Darker** reduces Boost and returns to macOS brightness after the baseline curve has been restored. Holding either key repeats the adjustment. Hold **Shift–Option** for finer steps.

The keyboard level lasts for the current session. A manual Boost start uses the saved slider setting. **Settings… → Displays → Sync hardware brightness** optionally synchronizes supported Apple backlights while using brightness keys. It requires at least two selected displays with readable backlight levels and the same Accessibility access.

## macOS Shortcuts

Use the **Open URLs** action with `lumaluma://on`, `lumaluma://off` or `lumaluma://toggle` to control the app from a shortcut.

## Development and license

The developer guide covers the rendering paths, helper process, tests, packaging and hardware acceptance checks. [Development guide](docs/DEVELOPMENT.md)

Luma Luma is distributed under the MIT License. The app bundle includes a copy in `Contents/Resources/LICENSE`. [License](LICENSE)
