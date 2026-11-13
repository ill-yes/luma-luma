import AppKit
import SwiftUI

struct StatusView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences

    private var caption: String {
        if controller.paused { return "Paused while the display is inactive" }
        if controller.isRestoringCurve { return "Restoring display…" }
        switch controller.report?.gammaRestorationStatus {
        case .restorationFailed:
            return "Could not restore the display curve"
        case .conflict:
            return "Display curve changed by another app"
        default:
            break
        }
        if controller.controlDisplays.isEmpty {
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
        guard let report = controller.report else { return "Preparing HDR…" }
        let requested = report.displays.values.filter { $0.requestedBoost > 0 }
        guard !requested.isEmpty else {
            return "Standard display brightness"
        }
        if report.activeBoostDisplayCount > 0 {
            if report.activeBoostDisplayCount < requested.count { return "HDR on some displays" }
            if report.currentHeadroom <= 1.01 { return "macOS is limiting HDR headroom" }
            return "HDR display brightness"
        }
        if report.hasPendingBoost { return "Preparing HDR…" }
        if requested.contains(where: { $0.boostStatus == .conflict }) {
            return "Display curve changed by another app"
        }
        if requested.contains(where: { $0.boostStatus == .restorationFailed }) {
            return "Could not restore the display curve"
        }
        if requested.contains(where: { $0.boostStatus == .failed }) {
            return "Could not apply the display curve"
        }
        if requested.contains(where: { $0.boostStatus == .waitingForWindow }) {
            return "Waiting for a frontmost window"
        }
        if requested.allSatisfy({ $0.boostStatus == .unsupported }) {
            return "No HDR display available"
        }
        return "HDR renderer unavailable"
    }

    private var isBusy: Bool {
        if controller.isRestoringCurve { return true }
        guard !controller.paused, controller.mode == .boost else { return false }
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

            if !controller.controlDisplays.isEmpty {
                Picker("Display", selection: Binding(
                    get: { controller.selectedDisplayID },
                    set: { controller.selectDisplay($0) }
                )) {
                    ForEach(controller.controlDisplays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                effectControls.id(controller.selectedDisplayID)
            }

            Divider()
            HStack {
                Button("Settings…", systemImage: "gearshape") {
                    controller.showPreferences()
                }
                .buttonStyle(.bordered)
                Button("Diagnostics…", systemImage: "waveform.path") {
                    controller.showDiagnostics()
                }
                .buttonStyle(.plain)
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

    @ViewBuilder
    private var effectControls: some View {
        switch controller.selectedEffect {
        case .boost:
            if let control = controller.brightnessControl {
                let displayID = controller.selectedDisplayID
                DisplayBrightnessSlider(control: control, value: Binding(
                    get: { controller.brightnessControl?.value ?? control.value },
                    set: {
                        guard controller.selectedDisplayID == displayID,
                              controller.brightnessControl?.mode == control.mode else { return }
                        controller.setBrightnessControl($0)
                    }
                ), isHDRRangeAvailable: {
                    controller.selectedDisplayID == displayID &&
                        controller.brightnessControl?.showsHDRRange == true
                })
                if control.mode != .native {
                    Picker("Area", selection: Binding(
                        get: { controller.controlBoostRegion },
                        set: { controller.setControlBoostRegion($0) }
                    )) {
                        ForEach(BoostRegion.allCases) { region in
                            Text(region.title).tag(region)
                        }
                    }
                }
            } else {
                Text("Brightness control is unavailable for this display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = controller.brightnessControlStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .eclipse:
            slider("Dimming", value: Binding(
                get: { controller.controlDimming },
                set: { controller.setControlDimming($0) }
            ), range: 0...0.95)
        case .ring:
            slider("Light intensity", value: Binding(
                get: { controller.controlRingStrength },
                set: { controller.setControlRingStrength($0) }
            ), range: 0...1)
        }
    }

    private func slider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        let percent = Int((value.wrappedValue * 100).rounded())
        return VStack(alignment: .leading, spacing: 3) {
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
                controller: controller,
                preferences: controller.preferences
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
