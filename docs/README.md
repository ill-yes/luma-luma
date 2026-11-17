# 📚 Luma Luma documentation

Find the instructions for what you want to do with Luma Luma.

[Project overview](../README.md) · [User guide](USAGE.md) · [Development](DEVELOPMENT.md) · [Validation](VALIDATION.md)

## 🚀 Install and get started

| I want to… | Start here |
| --- | --- |
| Download, install or update Luma Luma | [Installation and updates](USAGE.md#-installation-and-updates) |
| Choose an effect and adjust its strength | [Menu bar controls](USAGE.md#-menu-bar-controls) · [Effects](USAGE.md#-effects) |
| Check whether Boost supports my display | [Display compatibility](USAGE.md#-display-compatibility) |

Boost uses the HDR headroom available from macOS. Eclipse and Ring Light also
work on SDR displays. Releases use ad-hoc signing; the installation guide covers
macOS first-launch approval and checksum verification.

## 🎛️ Make it work for your setup

| I want to… | Start here |
| --- | --- |
| Customize individual monitors or Boost areas | [Display profiles](USAGE.md#display-profiles) · [Boost areas](USAGE.md#boost-areas) |
| Use the MacBook brightness keys | [Permission setup and key behavior](USAGE.md#-macbook-brightness-keys) |
| Restore my manual effect or start at login | [Startup and automation](USAGE.md#-startup-and-automation) |
| Automate Boost with light or power | [Startup and automation](USAGE.md#-startup-and-automation) · [Auto-Boost](USAGE.md#auto-boost-in-bright-surroundings) |
| Use global shortcuts or macOS Shortcuts | [Startup and automation](USAGE.md#-startup-and-automation) · [macOS Shortcuts](USAGE.md#macos-shortcuts) |

## 🧭 Find help and understand status

- **A display or permission message needs attention:**
  [Status and troubleshooting](USAGE.md#-status-and-troubleshooting).
- **I want to inspect display values or copy a diagnostic report:**
  [Diagnostics and report contents](USAGE.md#-status-and-troubleshooting).
- **I want to know what has actually been tested:**
  [Recorded validation](VALIDATION.md) and
  [remaining hardware coverage](VALIDATION.md#-remaining-coverage).
- **I want to report a problem:**
  [Useful information for an issue](../CONTRIBUTING.md#-report-a-problem).

Automated tests and observed device behavior are separate evidence. A successful
build does not confirm every display, macOS preset or physical-key combination.

## 🛠️ Develop and contribute

| I want to… | Start here |
| --- | --- |
| Set up the toolchain and run locally | [Local setup](DEVELOPMENT.md#-local-setup) |
| Build an app or architecture-specific disk image | [Build and packaging](DEVELOPMENT.md#-build-and-packaging) |
| Understand the rendering and helper lifecycle | [Developer guide](DEVELOPMENT.md) |
| Run tests or download a CI snapshot | [Tests and CI](DEVELOPMENT.md#-tests-and-ci) |
| Publish a release | [Manual release workflow](DEVELOPMENT.md#manual-releases) |
| Propose a change | [Contributing](../CONTRIBUTING.md) |

Source builds require Swift 6.0 or newer on macOS 14 or newer. Downloads do not
require a Swift toolchain.

[MIT License](../LICENSE) · [☕ Support Luma Luma](https://buymeacoffee.com/ill_yes)
