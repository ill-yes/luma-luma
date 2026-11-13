# ✅ Validation

Automated coverage and observed device behavior for Luma Luma.

[Project overview](../README.md) · [User guide](USAGE.md) · [Development](DEVELOPMENT.md)

## 🧪 Automated checks

Run the complete test script from the repository root.

```sh
./scripts/test-hdr.sh
```

The script builds five standalone test executables with `-warnings-as-errors`.

| Suite | Coverage |
| --- | --- |
| `LightingStateTests` | Disabled effect selection, enabled effect changes, idempotent requests, temporary keyboard strength and rapid off/on transitions. |
| `GammaBoostSessionTests` | HDR stability, helper protocol, busy retries, latest requested strength, recovery, delayed replies and terminal errors. |
| `BrightnessEventTests` | Native press/release routing, held-key handoff, replacement events and event-state reset. |
| `BrightnessKeyRoutingTests` | SDR-to-HDR decisions, standard and fine steps, unavailable hardware values and partial brightness synchronization. |
| `GammaLeaseTests` | Curve ownership, verified writes, conflicts, full-resolution restoration and disconnect cleanup. |

These tests use controlled helper and display fixtures. The full script, local release build, bundled-license comparison and strict app-signature verification passed for the validated local revision.

## 🖥️ Native UI and display checks

The local validation environment used macOS 27.2.1, Swift 6.4.2 and an Apple silicon MacBook with its built-in display.

The observations in this section were recorded before the app's bundle identity changed to `dev.illyes.lumaluma`.

| Check | Observed result |
| --- | --- |
| Select effects while disabled | Selection and controls changed while the effect stayed off. |
| Change effects while enabled | The selected effect was applied. |
| Repeat the current selection | The activation state was preserved. |
| Open settings and change tabs | Activation and the requested Boost level were preserved. |
| Rapid off/on and full/half-display changes | The controls returned to the requested effect. |
| Start with saved Boost at 100% | The built-in RGB curve reached a gain of 1.45 automatically. |
| Disable Boost | All 1,024 samples per RGB channel exactly matched the initial curve. Native brightness was preserved. |
| Controlled busy and missing helpers | Separate test bundles displayed preparation, timeout and helper-error states. |

## ⌨️ Physical MacBook keys

The physical brightness keys were tested on November 13, 2026, before the bundle identity changed, with macOS Accessibility permission enabled for that build.

| Check | Observed result |
| --- | --- |
| **Brighter** at maximum native brightness | Started Boost from Off with an RGB gain of 1.028125. |
| **Shift–Option + Brighter** | Increased the gain to 1.03515625. |
| **Shift–Option + Darker** | Returned the gain to 1.028125. |
| Held **Brighter** | Applied successive HDR steps. |
| Held **Darker** | Restored the baseline, then continued lowering native brightness. |
| Individual boundary presses | Crossed back from Boost into native brightness. |
| End of test | Native brightness returned to 1. All 1,024 samples in each RGB channel exactly matched the starting curve. |

The tested app bundle was re-added to the macOS privacy pane after an older permission entry failed to authorize it. On German-language macOS 27, this pane is **Datenschutz & Sicherheit → Gerätesteuerung und Datenzugriff**.

## 🌅 Luma Luma identity checks

After the identity change on November 13, 2026, all five automated suites passed. The release app and helper passed strict signature verification, the bundled license matched the repository copy, and the helper completed its shutdown protocol. Scans of all bundle files found no previous app names or local build paths. A secret scan of the rewritten Git history found no findings.

The rebuilt app opened as **Luma Luma**. Its controls and settings showed the new name, the saved Boost level remained at 100%, and the brightness-key preference was preserved. Opening settings and returning to the controls kept the effect off.

### Installed version 0.1.2

The installed `/Applications/Luma Luma.app` received macOS Accessibility permission for the `dev.illyes.lumaluma` identity. Manual Boost at 100% reached an RGB gain of `1.4500000476837158`. Turning Boost off restored all 1,024 samples per RGB channel exactly to the baseline.

The user confirmed brightness-key operation with this installed app. The exact fine-step sequence was not fully captured. The detailed physical-key measurements above remain evidence from the earlier bundle identity.

## 📦 Hosted CI and releases

The first **Build and test** GitHub Actions run passed at commit `b26d61d`. It ran the existing tests, built the release app and verified its signature and bundled license. [CI result](https://github.com/ill-yes/luma-luma/actions/runs/43431125097)

The manual **Release LumaLuma** workflow published **0.1.2** from commit `164d6ba`. The run passed all 39 release-publication tests and the existing display suites. The downloaded ZIP passed its SHA-256 check, and the extracted app and helper both contained `arm64` and `x86_64` code with a macOS 14 minimum. Their signatures, version fields, license, icon and private-path scans passed. [Release](https://github.com/ill-yes/luma-luma/releases/tag/v0.1.2) · [Workflow run](https://github.com/ill-yes/luma-luma/actions/runs/43434486527)

Re-running all jobs of that workflow succeeded and recognized the published release. The release ID and both asset IDs, sizes, hashes and timestamps were preserved. The release tests also cover draft recovery, conflicts, incomplete uploads and publication failures.

## 🔎 Remaining coverage

- Record the complete physical brightness-key sequence, including fine-step measurements, with the current bundle identity.
- Synchronized external displays and partial hardware synchronization still need device testing.
- Restoration after sleep, session lock and quitting still needs explicit device testing.
- Menu bar appearance should be checked in both light and dark appearances.

For hardware changes, repeat the relevant device checks and record the macOS version, display selection, display preset and observed status. Keep fixture-test results and device observations explicit when reporting an issue or pull request.
