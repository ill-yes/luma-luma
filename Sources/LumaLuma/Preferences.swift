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

extension DisplayScope {
    var title: String {
        switch self {
        case .all: "All displays"
        case .builtIn: "Built-in display"
        case .external: "External displays"
        }
    }
}

extension BoostRegion {
    var title: String {
        switch self {
        case .full: "Entire display"
        case .split: "Half display (compare)"
        case .frontWindow: "Front window"
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
    @Published var ambientBoostEnabled: Bool {
        didSet { defaults.set(ambientBoostEnabled, forKey: "ambientBoostEnabled") }
    }
    @Published var ambientSensitivity: AmbientSensitivity {
        didSet { defaults.set(ambientSensitivity.rawValue, forKey: "ambientSensitivity") }
    }
    @Published private(set) var displayProfiles: [UUID: DisplayProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(displayProfiles) {
                defaults.set(data, forKey: "displayProfiles")
            }
        }
    }
    @Published var nativeBrightnessKeys: Bool {
        didSet { defaults.set(nativeBrightnessKeys, forKey: "nativeBrightnessKeys") }
    }
    @Published var showBrightnessIndicator: Bool {
        didSet { defaults.set(showBrightnessIndicator, forKey: "showBrightnessIndicator") }
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
        ambientBoostEnabled = defaults.bool(forKey: "ambientBoostEnabled")
        ambientSensitivity = defaults.string(forKey: "ambientSensitivity")
            .flatMap(AmbientSensitivity.init(rawValue:)) ?? .standard
        displayProfiles = defaults.data(forKey: "displayProfiles").flatMap {
            try? JSONDecoder().decode([UUID: DisplayProfile].self, from: $0)
        }?.mapValues(\.validated) ?? [:]
        nativeBrightnessKeys = defaults.bool(forKey: "nativeBrightnessKeys")
        showBrightnessIndicator = defaults.object(forKey: "showBrightnessIndicator") as? Bool ?? true
        syncHardwareBrightness = defaults.bool(forKey: "syncHardwareBrightness")
        shortcuts = defaults.data(forKey: "shortcuts").flatMap {
            try? JSONDecoder().decode([ShortcutAction: KeyBinding].self, from: $0)
        } ?? [:]
    }

    func setDisplayProfile(_ profile: DisplayProfile, for identity: UUID) {
        let value: DisplayProfile? = profile == DisplayProfile() ? nil : profile
        if displayProfiles[identity] != value { displayProfiles[identity] = value }
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
