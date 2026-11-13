# 🎛️ User guide

Configure Luma Luma's effects, brightness keys and automation.

[Project overview](../README.md) · [Development](DEVELOPMENT.md) · [Validation](VALIDATION.md)

## 📥 Installation and updates

1. Open the release page and download `LumaLuma-<version>-macos-universal.zip` and its matching `.sha256` file. [Latest release](https://github.com/ill-yes/luma-luma/releases/latest)
2. In the download directory, verify the ZIP with `shasum -a 256 -c LumaLuma-<version>-macos-universal.zip.sha256`, substituting the downloaded version.
3. Expand the ZIP and move **Luma Luma.app** to **Applications**.
4. Open the app and configure the optional brightness-key permission below.

The Universal app contains native code for Apple Silicon and Intel Macs and requires macOS 14 or newer. Releases use ad-hoc signing. If macOS requests approval for the downloaded app, follow Apple's instructions for opening trusted software. [Apple's first-launch guidance](https://support.apple.com/en-us/102445)

To update, quit Luma Luma, replace the app in **Applications** with the newly downloaded version and reopen it. macOS may require you to re-add the updated app to its Accessibility permission list.

## 🌅 Menu bar controls

Click the sunrise icon in the menu bar to open the controls. Choose **Boost**, **Eclipse** or **Ring Light**, then use the switch to turn the selected effect on or off.

The **Display** menu chooses the monitor you adjust. The switch and effect selector apply to the participating display group. Changing effects with the switch on applies the new selection. Opening settings or switching between settings tabs preserves the current activation state. The icon's filled sun indicates an active effect.

Right-click the menu bar icon to toggle the selected effect. **Settings…** opens the settings window. Reopening the app from Finder opens its controls.

The footer in both the menu bar controls and settings shows the installed app version.

### Brightness slider

In the **Boost** tab, drag the brightness slider to **macOS 100%**. When the display confirms maximum native brightness, **HDR Boost** appears on the right. Keep dragging the same thumb to start Boost on the selected display, including from Off. The percentage next to **HDR Boost** shows the requested effect strength. With the slider focused, use the arrow keys to adjust it in one-percentage-point steps.

When you drag back into the macOS range, Luma Luma releases Boost on that display and waits for any RGB curve restoration before writing the latest native brightness you selected. The HDR section disappears once the display confirms a lower native level. If restoration fails, the status shows the problem.

The native section is available on displays that support Apple brightness control. An HDR display without native control shows a **Boost** slider and uses the switch to apply it. For an SDR display with native control, the slider ends at 100%. Eclipse and Ring Light have their own controls.

## ✨ Effects

| Effect | What it does | Settings |
| --- | --- | --- |
| ☀️ Boost | Uses the extra brightness available from an HDR display. | Strength, display selection and boost area. |
| 🌙 Eclipse | Adds dimming below the display's normal brightness setting. | Dimming strength and display selection. |
| 💡 Ring Light | Adds screen-edge lighting for video calls. | Intensity, width, warmth and display selection. |

Select **All displays**, **Built-in display** or **External displays** in **Settings… → Displays**.

### Display profiles

In **Settings… → Displays**, use **Settings for → Defaults** to set values for the display group. Choose a connected monitor to customize its Boost strength and area, Eclipse dimming or Ring Light settings. Each field follows the defaults until you adjust it for that monitor.

Use **Participation → Exclude** to remove the monitor from the effect. **Follow display group** makes it eligible when the selected group includes it. **Use default effect values** restores inherited effect values for that monitor.

Profiles with a unique display identity are available when you reconnect the monitor. The brightness slider reads its current macOS brightness. Luma Luma applies connection-specific overrides while a monitor without a unique identity is connected.

### Boost areas

| Area | Coverage |
| --- | --- |
| **Entire display** | The selected screen. Built-in XDR displays use a verified RGB transfer curve. |
| **Half display (compare)** | The right half of each selected screen for a direct comparison. |
| **Front window** | The frontmost application's standard on-screen window. |

For full-display Boost on a built-in XDR display, drag across the slider's 100% mark or set macOS brightness to maximum before switching on the effect. At full strength, Luma Luma requests an RGB transfer-curve gain of up to 1.45, limited by current HDR headroom. The available brightness also depends on the display, macOS preset, power and temperature.

**Preparing HDR…** appears while HDR headroom stabilizes. The requested strength is applied automatically once preparation completes. A brief loss of headroom during active Boost starts recovery after the previous curve is restored.

## 🖥️ Display compatibility

Boost requires an HDR-capable display and available HDR headroom. Select a display group with **All displays**, **Built-in display** or **External displays**. Eclipse and Ring Light also work on SDR displays.

Built-in full-display Boost uses a different rendering path from external displays and partial-screen areas. Display capabilities, macOS presets, power and temperature affect the available result. The built-in transfer-curve limit of 1.45 describes the requested RGB gain for that path. The slider reports effect strength, and measured brightness varies by display.

## ⌨️ MacBook brightness keys

1. Open **Settings… → Shortcuts** and enable **Use display brightness keys**.
2. Grant Luma Luma access in **System Settings → Privacy & Security → Accessibility**. On German-language macOS 27, the pane is named **Gerätesteuerung und Datenzugriff**.
3. Turn **Use display brightness keys** off and on to reconnect the event tap.

When moving to the renamed app, grant access to **Luma Luma** again and update existing URL-based shortcuts to the `lumaluma://` scheme.

At maximum native brightness, the next **Brighter** press starts HDR Boost on a supported selected display, including while Luma Luma is off. Further presses increase Boost. **Darker** reduces Boost and returns to native brightness after the baseline curve is restored. Holding either key repeats the adjustment.

| Keys | Boost adjustment |
| --- | --- |
| **Brighter / Darker** | `1/16` of the Boost range per step. |
| **Shift–Option + Brighter / Darker** | `1/64` of the Boost range per step. |

The brightness keys use the built-in display if it participates in the group, otherwise the first participating display. The keyboard level lasts for the current session. Switching Boost on again uses the saved effect values.

### Hardware brightness synchronization

Enable **Settings… → Displays → Sync hardware brightness** to synchronize supported Apple backlights while using the brightness keys. It needs at least two selected displays with readable backlight levels and the same macOS permission. The reference display is adjusted first. Availability depends on the connected hardware and macOS.

## ⚙️ Startup and automation

The **General** tab provides startup and power controls.

| Setting | Behavior |
| --- | --- |
| **Open at login** | Starts Luma Luma when you sign in. Move the app to Applications before enabling it. |
| **Turn on boost when Luma Luma opens** | Starts Boost when the power rule is set to Manual and Auto-Boost is off. |
| **Show icon in Dock** | Adds a Dock icon alongside the menu bar controls. |
| **Enable boost → Manual** | Uses your manual selection and switch. |
| **Enable boost → On power adapter** | Enables Boost on external power and disables Boost on battery when the power condition changes. |
| **Enable boost → On power or above a battery level** | Enables Boost on external power or above the selected battery threshold when the power condition changes. |

Power automation changes Off and Boost states. An active Eclipse or Ring Light effect keeps its selection.

In **Shortcuts**, assign global keys for toggling, increasing or decreasing the effect. **Show brightness indicator** controls the temporary on-screen indicator for keyboard adjustments.

### Auto-Boost in bright surroundings

Enable **Settings… → General → Boost in bright surroundings**. The feature starts off by default. It checks the built-in light sensor every two seconds while the display is active. The participating built-in HDR display must be at 100% macOS brightness and the power rule must allow Boost.

| Sensitivity | Start after 4 seconds at or above | Stop after 8 seconds at or below |
| --- | ---: | ---: |
| **High** | 1,500 lx | 1,000 lx |
| **Standard** | 3,000 lx | 2,000 lx |
| **Low** | 6,000 lx | 4,000 lx |

The automatically started effect uses that display's saved Boost settings and holds its state between the thresholds. If you switch it off or lower the brightness manually, Auto-Boost waits until the surroundings have darkened before it can start again. It leaves an active manual effect in your control.

An automatic session ends after six seconds without a valid sensor reading or when its display or power conditions cease to apply. Sleep, lock and closing the lid release the automatic effect. Luma Luma takes fresh readings when the internal display is active again. Check the **Light sensor** status in **General** for availability and current conditions.

### macOS Shortcuts

Use the **Open URLs** action in the Shortcuts app with one of these commands.

| URL | Action |
| --- | --- |
| `lumaluma://on` | Select and enable Boost. |
| `lumaluma://off` | Turn the current effect off. |
| `lumaluma://toggle` | Toggle the selected effect. |

## 🧭 Status and troubleshooting

Open **Diagnostics…** from the menu bar or choose **Settings… → Diagnostics**. Each display shows its macOS brightness, requested Boost, render path, applied gain and current and potential HDR headroom. The gain describes the confirmed RGB curve or presented overlay. The status explains preparation, restoration and known limitations.

**Copy Diagnostics** copies the app and macOS versions, sensor status and per-display values to the clipboard. The report identifies displays by number and built-in or external type, omitting display names, UUIDs, serial numbers, window titles and local paths.

| Status | What to check |
| --- | --- |
| **Preparing HDR…** | Allow time for the display's HDR headroom to stabilize. |
| **Restoring display…** | Wait for the previous curve to be released before further native brightness adjustments. |
| **No displays match your selection** | Check the display selection and connected screens. |
| **No HDR display available** | Select an HDR-capable display. Eclipse and Ring Light can still be used on other screens. |
| **Waiting for a frontmost window** | Focus a standard application window inside a selected display. |
| **macOS is limiting HDR headroom** | Check the display preset, native brightness, power state and temperature. |
| **Display curve changed by another app** | Close other display-curve utilities, then turn Boost off and on. |
| **HDR renderer unavailable** or **Could not apply the display curve** | Check the selected display and native brightness, then turn Boost off and on to start a fresh attempt. |
| **Could not confirm display curve restoration** | Keep the display connected and allow the helper to finish. Use **Copy Diagnostics** to include display status in a bug report if the problem persists. |

If a replaced local build still reports missing access while its macOS permission switch is on, quit Luma Luma. Remove its entry from the privacy pane, add the current app bundle again and relaunch it.

Display sleep, session lock and quitting release the effect. The bundled helper also starts restoration if the main app exits unexpectedly. Review the current automated coverage and device checks. [Validation](VALIDATION.md)
