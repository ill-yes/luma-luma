import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, displays, shortcuts, diagnostics
}

struct DisplayBrightnessSlider: View {
    let control: BrightnessControl
    @Binding var value: Double
    let isHDRRangeAvailable: () -> Bool
    private var drag = State(wrappedValue: BrightnessSliderDrag())
    @GestureState private var isDragging = false
    @FocusState private var isFocused: Bool

    init(
        control: BrightnessControl,
        value: Binding<Double>,
        isHDRRangeAvailable: @escaping () -> Bool
    ) {
        self.control = control
        self._value = value
        self.isHDRRangeAvailable = isHDRRangeAvailable
    }

    private var label: String {
        control.mode == .boost ? "Boost" : "Brightness"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(control.valueLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if control.mode == .combined {
                combinedSlider
            } else {
                Slider(value: $value, in: 0...1) { Text(label) }
                    .labelsHidden()
                    .accessibilityValue(control.valueLabel)
            }
        }
        .disabled(!control.canAdjust)
    }

    private var combinedSlider: some View {
        GeometryReader { proxy in
            let track = Track(width: proxy.size.width)
            VStack(spacing: 0) {
                sliderTrack(track)
                ZStack(alignment: .trailing) {
                    Text("100%")
                        .monospacedDigit()
                        .position(x: track.boundary, y: 8)
                    if control.showsHDRRange {
                        Text("HDR Boost")
                    }
                }
                .frame(height: 16)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(control.valueLabel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(increasing: true)
            case .decrement: adjust(increasing: false)
            @unknown default: break
            }
        }
        .focusable(control.canAdjust, interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            adjust(increasing: press.key == .rightArrow || press.key == .upArrow)
            return .handled
        }
        .onChange(of: control.showsHDRRange) {
            if isDragging, control.showsHDRRange {
                submit(drag.wrappedValue.revealHDRRange())
            }
        }
        .onChange(of: isDragging) {
            if !isDragging { drag.wrappedValue.end() }
        }
        .onChange(of: control.canAdjust) {
            if !control.canAdjust { drag.wrappedValue.end() }
        }
    }

    private func sliderTrack(_ track: Track) -> some View {
        let thumb = track.x(for: control.value, showsHDRRange: control.showsHDRRange)
        let end = control.showsHDRRange ? track.end : track.boundary
        return ZStack {
            trackLine(from: track.start, to: end, color: .primary.opacity(0.16))
            trackLine(from: track.start, to: thumb, color: .accentColor)
            Rectangle()
                .fill(.secondary)
                .frame(width: 1, height: 4)
                .position(x: track.boundary, y: 23)
            Circle()
                .fill(Color(nsColor: .controlColor))
                .overlay { Circle().strokeBorder(.primary.opacity(0.24), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                .frame(width: 18, height: 18)
                .overlay {
                    if isFocused {
                        Circle()
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                }
                .position(x: thumb, y: 12)
        }
        .frame(width: track.width, height: 26)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, active, _ in active = true }
                .onChanged { event in updateDrag(event, on: track) }
                .onEnded { event in
                    updateDrag(event, on: track)
                    drag.wrappedValue.end()
                }
        )
        .opacity(control.canAdjust ? 1 : 0.5)
    }

    private func trackLine(from start: CGFloat, to end: CGFloat, color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0, end - start), height: 4)
            .position(x: (start + end) / 2, y: 12)
    }

    private func updateDrag(_ event: DragGesture.Value, on track: Track) {
        guard control.canAdjust else { return }
        let showsHDRRange = isHDRRangeAvailable()
        if let next = drag.wrappedValue.update(
            position: track.position(at: event.location.x),
            startPosition: track.position(at: event.startLocation.x),
            showsHDRRange: showsHDRRange
        ) {
            isFocused = true
            submit(next)
            if !showsHDRRange, isHDRRangeAvailable() {
                submit(drag.wrappedValue.revealHDRRange())
            }
        }
    }

    private func adjust(increasing: Bool) {
        submit(control.adjustedValue(increasing: increasing))
    }

    private func submit(_ next: Double?) {
        if control.canAdjust, let next {
            value = next
        }
    }

    private struct Track {
        let width: CGFloat
        let start: CGFloat = 12
        var end: CGFloat { max(start + 3, width - start) }
        var boundary: CGFloat { start + (end - start) * 2 / 3 }

        func x(for value: Double, showsHDRRange: Bool) -> CGFloat {
            let position = min(showsHDRRange ? 2 : 1, max(0, value))
            if position <= 1 {
                return start + position * (boundary - start)
            }
            return boundary + (position - 1) * (end - boundary)
        }

        func position(at x: CGFloat) -> Double {
            if abs(x - boundary) <= 0.5 { return 1 }
            if x < boundary { return (x - start) / (boundary - start) }
            return 1 + (x - boundary) / (end - boundary)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    // Use the property wrapper directly so Command Line Tools builds do not need SwiftUIMacros.
    private var profileDisplayID = State<UInt32?>(wrappedValue: nil)

    init(controller: AppController, preferences: Preferences) {
        self.controller = controller
        self.preferences = preferences
    }

    private var editedDisplayID: UInt32? {
        controller.profileDisplays.first { $0.id == profileDisplayID.wrappedValue }?.id
    }

    var body: some View {
        TabView(selection: $controller.settingsTab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            displays
                .tabItem { Label("Displays", systemImage: "display") }
                .tag(SettingsTab.displays)
            keyboard
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            DisplayDiagnosticsView(controller: controller)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path") }
                .tag(SettingsTab.diagnostics)
        }
        .frame(width: 500, height: 420)
        .padding(.bottom, 8)
        .onChange(of: controller.profileDisplays) {
            if editedDisplayID == nil { profileDisplayID.wrappedValue = nil }
        }
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { controller.loginEnabled },
                    set: { controller.setLoginEnabled($0) }
                ))
                Toggle("Turn on boost when Luma Luma opens", isOn: $preferences.startEnabled)
                Toggle("Show icon in Dock", isOn: $preferences.showDockIcon)
            }

            Section("Power automation") {
                Picker("Enable boost", selection: $preferences.powerRule) {
                    ForEach(PowerRule.allCases, id: \.self) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                if preferences.powerRule == .batteryThreshold {
                    Stepper(value: $preferences.batteryThreshold, in: 1...100) {
                        Text("Minimum battery level: \(preferences.batteryThreshold)%")
                    }
                }
            }

            Section {
                Toggle("Boost in bright surroundings", isOn: $preferences.ambientBoostEnabled)
                if preferences.ambientBoostEnabled {
                    Picker("Sensitivity", selection: $preferences.ambientSensitivity) {
                        ForEach(AmbientSensitivity.allCases, id: \.self) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                }
                LabeledContent("Light sensor", value: controller.ambientStatus)
            } header: {
                Text("Auto-Boost")
            } footer: {
                Text("Adds Boost in bright surroundings at 100% macOS brightness on the built-in HDR display. The power rule also applies.")
            }
        }
        .formStyle(.grouped)
    }

    private var displays: some View {
        Form {
            Section("Coverage") {
                Picker("Displays", selection: $preferences.scope) {
                    ForEach(DisplayScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Picker("Settings for", selection: Binding(
                    get: { editedDisplayID },
                    set: { profileDisplayID.wrappedValue = $0 }
                )) {
                    Text("Defaults").tag(nil as UInt32?)
                    ForEach(controller.profileDisplays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
            }

            if let id = editedDisplayID {
                displayProfile(id)
            }
            effectSettings

            Section {
                Toggle("Sync hardware brightness", isOn: $preferences.syncHardwareBrightness)
            } footer: {
                Text("Applies when using brightness keys on supported Apple displays.")
            }
        }
        .formStyle(.grouped)
    }

    private func displayProfile(_ id: UInt32) -> some View {
        let profile = controller.displayProfile(for: id)
        let participation = profileBinding(id, \.participates)
        return Section {
            Picker("Participation", selection: Binding(
                get: { participation.wrappedValue != false },
                set: { participation.wrappedValue = $0 ? nil : false }
            )) {
                Text("Follow display group").tag(true)
                Text("Exclude").tag(false)
            }
            Button("Use default effect values") {
                var reset = DisplayProfile()
                reset.participates = profile.participates
                controller.setDisplayProfile(reset, for: id)
            }
            .disabled(profile.boost == nil && profile.dim == nil && profile.region == nil
                      && profile.ringStrength == nil && profile.ringWidth == nil && profile.ringWarmth == nil)
        } footer: {
            if controller.isDisplayProfilePersistent(id) {
                Text("Adjust an effect value to save an override for this display.")
            } else {
                Text("Adjust an effect value to override it for this connection.")
            }
        }
    }

    @ViewBuilder
    private var effectSettings: some View {
        Section("Boost") {
            Slider(value: effectValue(\.boost, default: $preferences.boost), in: 0...1) {
                Text("Boost strength")
            }
            Picker("Boost area", selection: effectValue(\.region, default: $preferences.region)) {
                ForEach(BoostRegion.allCases) { region in
                    Text(region.title).tag(region)
                }
            }
        }
        Section("Eclipse") {
            Slider(value: effectValue(\.dim, default: $preferences.dim), in: 0...0.95) {
                Text("Dimming")
            }
        }
        Section("Ring Light") {
            Slider(value: effectValue(\.ringStrength, default: $preferences.ringStrength), in: 0...1) {
                Text("Strength")
            }
            Slider(value: effectValue(\.ringWidth, default: $preferences.ringWidth), in: 0...1) {
                Text("Width")
            }
            Slider(value: effectValue(\.ringWarmth, default: $preferences.ringWarmth), in: 0...1) {
                Text("Warmth")
            }
        }
    }

    private func effectValue<Value>(
        _ field: WritableKeyPath<DisplayProfile, Value?>,
        default inherited: Binding<Value>
    ) -> Binding<Value> {
        guard let id = editedDisplayID else { return inherited }
        let value = profileBinding(id, field)
        return Binding(
            get: { value.wrappedValue ?? inherited.wrappedValue },
            set: { value.wrappedValue = $0 }
        )
    }

    private func profileBinding<Value>(
        _ id: UInt32,
        _ field: WritableKeyPath<DisplayProfile, Value>
    ) -> Binding<Value> {
        Binding(
            get: { controller.displayProfile(for: id)[keyPath: field] },
            set: { value in
                var profile = controller.displayProfile(for: id)
                profile[keyPath: field] = value
                controller.setDisplayProfile(profile, for: id)
            }
        )
    }

    private var keyboard: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(binding: Binding(
                            get: { preferences.shortcuts[action] },
                            set: { preferences.shortcuts[action] = $0 }
                        ))
                    }
                }
            }

            Section {
                Toggle("Use display brightness keys", isOn: $preferences.nativeBrightnessKeys)
                if let shortcutError = controller.shortcutError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Keep pressing the brightness-up key at maximum brightness to start HDR on a supported display. Allow Luma Luma in System Settings › Privacy & Security › Accessibility, then turn this option off and back on.")
            }

            Section {
                Toggle("Show brightness indicator", isOn: $preferences.showBrightnessIndicator)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DisplayDiagnosticsView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if controller.diagnosticRows.isEmpty {
                    Text("No active displays detected")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.diagnosticRows) { row in
                    Section(row.name) {
                        LabeledContent("Status", value: row.status)
                        LabeledContent("macOS brightness", value: percentage(row.nativeBrightness))
                        LabeledContent("Requested Boost", value: percentage(row.requestedBoost))
                        if let path = row.path {
                            LabeledContent("Render path", value: path)
                        }
                        LabeledContent("Applied gain", value: factor(row.appliedGain))
                        LabeledContent("Current HDR headroom", value: factor(row.currentHeadroom))
                        LabeledContent("Potential HDR headroom", value: factor(row.potentialHeadroom))
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                    controller.copyDiagnostics()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func factor(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0...3))) + "×"
    }
}
