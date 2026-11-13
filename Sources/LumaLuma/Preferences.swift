import SwiftUI

enum PowerRule: String, CaseIterable {
    case manual
    case pluggedIn
    case batteryThreshold

    var title: String {
        switch self {
        case .manual: "Manual"
        case .pluggedIn: "On power adapter"
        case .batteryThreshold: "On power or above a battery level"
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var boost: Double { didSet { defaults.set(boost, forKey: "boost") } }
    @Published var dim: Double { didSet { defaults.set(dim, forKey: "dim") } }
    @Published var scope: DisplayScope { didSet { defaults.set(scope.rawValue, forKey: "scope") } }
    @Published var region: BoostRegion { didSet { defaults.set(region.rawValue, forKey: "region") } }
    @Published var ringStrength: Double { didSet { defaults.set(ringStrength, forKey: "ringStrength") } }
    @Published var ringWidth: Double { didSet { defaults.set(ringWidth, forKey: "ringWidth") } }
    @Published var ringWarmth: Double { didSet { defaults.set(ringWarmth, forKey: "ringWarmth") } }
    @Published var startEnabled: Bool { didSet { defaults.set(startEnabled, forKey: "startEnabled") } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon") } }
    @Published var powerRule: PowerRule { didSet { defaults.set(powerRule.rawValue, forKey: "powerRule") } }
    @Published var batteryThreshold: Int { didSet { defaults.set(batteryThreshold, forKey: "batteryThreshold") } }
    @Published var nativeBrightnessKeys: Bool {
        didSet { defaults.set(nativeBrightnessKeys, forKey: "nativeBrightnessKeys") }
    }
    @Published var syncHardwareBrightness: Bool {
        didSet { defaults.set(syncHardwareBrightness, forKey: "syncHardwareBrightness") }
    }
    @Published var shortcuts: [ShortcutAction: KeyBinding] {
        didSet {
            guard let data = try? JSONEncoder().encode(shortcuts) else { return }
            defaults.set(data, forKey: "shortcuts")
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        boost = Self.readLevel(from: defaults, key: "boost", fallback: 0.65, maximum: 1)
        dim = Self.readLevel(from: defaults, key: "dim", fallback: 0.3, maximum: 0.95)
        scope = defaults.string(forKey: "scope").flatMap(DisplayScope.init(rawValue:)) ?? .all
        region = defaults.string(forKey: "region").flatMap(BoostRegion.init(rawValue:)) ?? .full
        ringStrength = Self.readLevel(from: defaults, key: "ringStrength", fallback: 0.55, maximum: 1)
        ringWidth = Self.readLevel(from: defaults, key: "ringWidth", fallback: 0.45, maximum: 1)
        ringWarmth = Self.readLevel(from: defaults, key: "ringWarmth", fallback: 0.25, maximum: 1)
        startEnabled = defaults.bool(forKey: "startEnabled")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        powerRule = defaults.string(forKey: "powerRule").flatMap(PowerRule.init(rawValue:)) ?? .manual
        batteryThreshold = min(100, max(1, defaults.object(forKey: "batteryThreshold") as? Int ?? 40))
        nativeBrightnessKeys = defaults.bool(forKey: "nativeBrightnessKeys")
        syncHardwareBrightness = defaults.bool(forKey: "syncHardwareBrightness")
        shortcuts = defaults.data(forKey: "shortcuts").flatMap {
            try? JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: $0)
        } ?? [:]
    }

    private static func readLevel(
        from defaults: UserDefaults,
        key: String,
        fallback: Double,
        maximum: Double
    ) -> Double {
        guard let level = defaults.object(forKey: key) as? Double, level.isFinite else { return fallback }
        return min(maximum, max(0, level))
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    let loginEnabled: Bool
    let setLoginEnabled: @MainActor (Bool) -> Void
    let shortcutError: String?

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            displays.tabItem { Label("Displays", systemImage: "display") }
            keyboard.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 420)
        .padding(.bottom, 8)
    }

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Open at login", isOn: Binding(
                    get: { loginEnabled },
                    set: { setLoginEnabled($0) }
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
        }
        .formStyle(.grouped)
    }

    private var displays: some View {
        Form {
            Section("Coverage") {
                Picker("Displays", selection: $preferences.scope) {
                    Text("All displays").tag(DisplayScope.all)
                    Text("Built-in display").tag(DisplayScope.builtIn)
                    Text("External displays").tag(DisplayScope.external)
                }
                Picker("Boost area", selection: $preferences.region) {
                    Text("Entire display").tag(BoostRegion.full)
                    Text("Half display (compare)").tag(BoostRegion.split)
                    Text("Front window").tag(BoostRegion.frontWindow)
                }
            }

            Section("Effects") {
                Slider(value: $preferences.boost, in: 0...1) { Text("Boost strength") }
                Slider(value: $preferences.dim, in: 0...0.95) { Text("Eclipse dimming") }
            }

            Section("Ring Light") {
                Slider(value: $preferences.ringStrength, in: 0...1) { Text("Strength") }
                Slider(value: $preferences.ringWidth, in: 0...1) { Text("Width") }
                Slider(value: $preferences.ringWarmth, in: 0...1) { Text("Warmth") }
            }

            Section {
                Toggle("Sync hardware brightness", isOn: $preferences.syncHardwareBrightness)
            } footer: {
                Text("Applies when using brightness keys on supported Apple displays.")
            }
        }
        .formStyle(.grouped)
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
                if let shortcutError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("To adjust an active effect with the display brightness keys, allow Luma Luma in System Settings › Privacy & Security › Accessibility, then turn this option off and back on.")
            }
        }
        .formStyle(.grouped)
    }
}
