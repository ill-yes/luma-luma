# 🤝 Contributing to Luma Luma

Contributions that improve display compatibility, reliability, accessibility and
the native macOS experience are welcome.

## 🧭 Get oriented

Start with the user guide to understand effect selection, display groups and
keyboard behavior. The developer guide explains the rendering paths and the
gamma helper. [User guide](docs/USAGE.md) · [Developer guide](docs/DEVELOPMENT.md)

## 🐛 Report a problem

Include the steps to reproduce the problem, what you expected and what happened.
For display or keyboard issues, also include

- Your Mac model and macOS version.
- The display model, connection type and display preset.
- The selected effect, display group and Boost area.
- Whether **Use display brightness keys** is enabled and macOS access is granted.
- Whether the problem occurs with single presses, held keys or Shift–Option.

A focused screenshot of Luma Luma's controls or error message can help. Remove
personal information from screenshots and logs before sharing them.

## 🧑‍💻 Make a change

Use macOS 14 or newer with Swift 6.0 or newer. Keep changes focused and follow the
existing Swift style. Add regression coverage when existing tests do not cover
the changed behavior, especially for state transitions, key-event routing and
gamma restoration.

Run these checks from the repository directory

```sh
./scripts/test-hdr.sh
./scripts/build-app.sh
codesign --verify --deep --strict 'dist/Luma Luma.app'
git diff --check
```

For a UI change, inspect the affected native views. For display or keyboard
changes, describe which hardware paths you exercised and the results. Keep
generated app bundles, local preferences and diagnostic recordings out of the
source changes. [Validation coverage](docs/VALIDATION.md)

## 📬 Describe the contribution

Explain the problem and the resulting behavior. Include the checks you ran and
the hardware used for native testing. Link the related issue when one exists.

## 📄 License

Contributions are covered by the project's MIT License. Preserve relevant
copyright and attribution notices when adding third-party material. [License](LICENSE)
