import Foundation

enum LightingEffect: String, CaseIterable, Codable {
    case boost, eclipse, ring

    var mode: LightingMode {
        switch self {
        case .boost: .boost
        case .eclipse: .eclipse
        case .ring: .ring
        }
    }

    var title: String { mode.title }
    var symbol: String { mode.symbol }
}

enum LightingMode: String {
    case off, boost, eclipse, ring

    var effect: LightingEffect? {
        switch self {
        case .off: nil
        case .boost: .boost
        case .eclipse: .eclipse
        case .ring: .ring
        }
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .boost: "Boost"
        case .eclipse: "Eclipse"
        case .ring: "Ring Light"
        }
    }

    var symbol: String {
        switch self {
        case .off: "sun.max"
        case .boost: "sun.max.fill"
        case .eclipse: "moon.fill"
        case .ring: "circle.circle"
        }
    }
}

struct LightingState: Equatable {
    private(set) var selectedEffect: LightingEffect = .boost
    private(set) var isEnabled = false
    private(set) var keyboardBoost: Double?

    var mode: LightingMode { isEnabled ? selectedEffect.mode : .off }

    mutating func selectEffect(_ effect: LightingEffect) -> Bool {
        guard selectedEffect != effect else { return false }
        selectedEffect = effect
        keyboardBoost = nil
        return true
    }

    mutating func setEnabled(_ enabled: Bool) -> Bool {
        guard isEnabled != enabled else { return false }
        isEnabled = enabled
        keyboardBoost = nil
        return true
    }

    mutating func activate(_ effect: LightingEffect, keyboardBoost: Double? = nil) -> Bool {
        guard selectedEffect != effect || !isEnabled || self.keyboardBoost != keyboardBoost else { return false }
        selectedEffect = effect
        isEnabled = true
        self.keyboardBoost = keyboardBoost
        return true
    }

    mutating func useManualBoost() -> Bool {
        guard keyboardBoost != nil else { return false }
        keyboardBoost = nil
        return true
    }
}

struct StoredManualLighting: Codable, Equatable {
    private static let defaultsKey = "manualLightingState"
    private let selectedEffect: LightingEffect
    private let isEnabled: Bool
    private let keyboardBoost: Double?
    private let target: UUID?
    private let levels: [UUID: Double]

    init(lighting: LightingState, displayBoost: DisplayBoostSession) {
        let canRestoreTarget = displayBoost.singleDisplay == nil || displayBoost.singleDisplay?.identity != nil
        selectedEffect = lighting.selectedEffect
        isEnabled = lighting.isEnabled && (lighting.mode != .boost || canRestoreTarget)
        if isEnabled, selectedEffect == .boost {
            keyboardBoost = lighting.keyboardBoost.flatMap(Self.validLevel)
            target = displayBoost.singleDisplay?.identity
            levels = Dictionary(uniqueKeysWithValues: displayBoost.levels.compactMap { key, value in
                guard let identity = key.identity, let level = Self.validLevel(value) else { return nil }
                return (identity, level)
            })
        } else {
            keyboardBoost = nil
            target = nil
            levels = [:]
        }
    }

    var lighting: LightingState {
        var state = LightingState()
        if isEnabled {
            let boost = selectedEffect == .boost ? keyboardBoost.flatMap(Self.validLevel) : nil
            _ = state.activate(selectedEffect, keyboardBoost: boost)
        } else {
            _ = state.selectEffect(selectedEffect)
        }
        return state
    }

    var displayBoost: DisplayBoostSession {
        guard isEnabled, selectedEffect == .boost else { return DisplayBoostSession() }
        let overrides = Dictionary(uniqueKeysWithValues: levels.compactMap { identity, value in
            Self.validLevel(value).map { (DisplayBoostKey.persistent(identity), $0) }
        })
        return DisplayBoostSession(singleDisplay: target.map(DisplayBoostKey.persistent), levels: overrides)
    }

    static func load(from defaults: UserDefaults) -> Self {
        if let record = defaults.object(forKey: defaultsKey) {
            if let data = record as? Data, let stored = try? JSONDecoder().decode(Self.self, from: data) {
                return Self(lighting: stored.lighting, displayBoost: stored.displayBoost)
            }
            return Self(lighting: LightingState(), displayBoost: DisplayBoostSession())
        }

        var lighting = LightingState()
        _ = lighting.setEnabled(defaults.bool(forKey: "startEnabled"))
        let migrated = Self(lighting: lighting, displayBoost: DisplayBoostSession())
        migrated.save(to: defaults)
        return migrated
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func validLevel(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(1, max(0, value))
    }
}
