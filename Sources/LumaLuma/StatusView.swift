import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences

    private var percent: Int {
        switch controller.selectedEffect {
        case .boost: Int((controller.boostStrength * 100).rounded())
        case .eclipse: Int((preferences.dim * 100).rounded())
        case .ring: Int((preferences.ringStrength * 100).rounded())
        }
    }

    private var caption: String {
        if controller.paused { return "Paused while the display is inactive" }
        if controller.isRestoringCurve { return "Restoring display…" }
        if controller.report?.gammaRestorationStatus == .restorationFailed {
            return "Could not restore the display curve"
        }
        if controller.mode != .off, controller.report?.displayCount == 0 {
            return "No displays match your selection"
        }
        switch controller.mode {
        case .off: return "Standard display brightness"
        case .eclipse: return "Extra dimming"
        case .ring: return "Camera fill light"
        case .boost: return boostCaption
        }
    }

    private var boostCaption: String {
        guard controller.boostStrength > 0 else { return "Boost set to zero" }
        guard let report = controller.report else { return "Preparing HDR…" }
        switch report.gammaStatus {
        case .starting: return "Preparing HDR…"
        case .unavailable: return "Built-in display HDR unavailable"
        case .conflict: return "Display curve changed by another app"
        case .failed: return "Could not apply the display curve"
        case .restorationFailed: return "Could not restore the display curve"
        case .active, nil: break
        }
        if report.edrDisplayCount == 0 { return "No HDR display available" }
        if report.targetBoostDisplayCount == 0 { return "Waiting for a frontmost window" }
        if report.hasPendingBoost && report.activeBoostDisplayCount == 0 { return "Preparing HDR…" }
        if report.activeBoostDisplayCount == 0 { return "HDR renderer unavailable" }
        if report.currentHeadroom <= 1.01 { return "macOS is limiting HDR headroom" }
        if report.activeBoostDisplayCount < report.targetBoostDisplayCount {
            return "HDR boost on some selected displays"
        }
        return "HDR display brightness"
    }

    private var isBusy: Bool {
        if controller.isRestoringCurve { return true }
        guard !controller.paused, controller.mode == .boost, controller.boostStrength > 0 else { return false }
        guard let report = controller.report else { return true }
        return report.hasPendingBoost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Luma Luma")
                        .font(.headline)
                    HStack(spacing: 6) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel("Updating display")
                        }
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Lighting", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { controller.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Turn the selected effect on or off")
            }

            Picker("Lighting effect", selection: Binding(
                get: { controller.selectedEffect },
                set: { controller.selectEffect($0) }
            )) {
                ForEach(LightingEffect.allCases, id: \.self) { effect in
                    Text(effect.title).tag(effect)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch controller.selectedEffect {
            case .boost:
                slider("Boost", value: Binding(
                    get: { controller.boostStrength },
                    set: { controller.setManualBoost($0) }
                ), range: 0...1)
                Picker("Area", selection: $preferences.region) {
                    ForEach(BoostRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
            case .eclipse:
                slider("Dimming", value: $preferences.dim, range: 0...0.95)
            case .ring:
                slider("Light intensity", value: $preferences.ringStrength, range: 0...1)
            }

            Divider()
            HStack {
                Button("Settings…", systemImage: "gearshape") {
                    controller.showPreferences()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Quit") { controller.quit() }
                    .buttonStyle(.plain)
            }
            .controlSize(.small)

            Text(AppVersion.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(15)
        .frame(width: 326)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(percent)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range) { Text(label) }
                .labelsHidden()
                .accessibilityValue("\(percent)%")
        }
    }
}

struct PreferencesHost: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            PreferencesView(
                preferences: controller.preferences,
                boost: Binding(
                    get: { controller.boostStrength },
                    set: { controller.setManualBoost($0) }
                ),
                loginEnabled: controller.loginEnabled,
                setLoginEnabled: controller.setLoginEnabled,
                shortcutError: controller.shortcutError
            )
            if let loginMessage = controller.loginMessage {
                Text(loginMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 15)
            }
            Text(AppVersion.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .toolbar {
            Button("Show Controls", systemImage: "sun.max") { controller.showControls() }
        }
    }
}

private enum AppVersion {
    static let label: String = {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "Development build"
        }
        return "Version \(version)"
    }()
}
