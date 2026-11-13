enum LightingEffect: String, CaseIterable {
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
