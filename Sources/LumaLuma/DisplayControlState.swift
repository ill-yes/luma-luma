import Foundation

enum DisplayScope: String, CaseIterable, Identifiable, Sendable {
    case all, builtIn, external

    var id: Self { self }

    func includes(builtIn: Bool) -> Bool {
        switch self {
        case .all: true
        case .builtIn: builtIn
        case .external: !builtIn
        }
    }
}

enum BoostRegion: String, CaseIterable, Identifiable, Codable, Sendable {
    case full, split, frontWindow

    var id: Self { self }
}

struct DisplayProfile: Codable, Equatable {
    var participates: Bool?
    var boost: Double?
    var dim: Double?
    var region: BoostRegion?
    var ringStrength: Double?
    var ringWidth: Double?
    var ringWarmth: Double?

    var validated: Self {
        var profile = self
        profile.boost = Self.validLevel(boost, maximum: 1)
        profile.dim = Self.validLevel(dim, maximum: 0.95)
        profile.ringStrength = Self.validLevel(ringStrength, maximum: 1)
        profile.ringWidth = Self.validLevel(ringWidth, maximum: 1)
        profile.ringWarmth = Self.validLevel(ringWarmth, maximum: 1)
        return profile
    }

    private static func validLevel(_ value: Double?, maximum: Double) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(maximum, max(0, value))
    }
}

struct DisplayControlChoice: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

struct BrightnessControl {
    enum Mode {
        case native, combined, boost
    }

    let mode: Mode
    let value: Double
    let canAdjust: Bool
    let nativeLevel: Double?
    let showsHDRRange: Bool

    static func isNativeMaximum(_ level: Double) -> Bool {
        level >= 0.999
    }

    var valueLabel: String {
        let format = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))
        if mode == .boost { return value.formatted(format) }
        if mode == .combined, value > 1 {
            return "HDR Boost \((value - 1).formatted(format))"
        }
        let level = nativeLevel ?? value
        // Keep the displayed maximum tied to the same readback as the HDR range.
        let percent = Self.isNativeMaximum(level) ? 1 : min(0.99, level)
        return "macOS \(percent.formatted(format))"
    }

    func adjustedValue(increasing: Bool) -> Double {
        let step = increasing ? 0.01 : -0.01
        let upperLimit = showsHDRRange ? 2.0 : 1.0
        if increasing, value < 1 { return min(1, value + step) }
        if !increasing, value > 1 { return max(1, value + step) }
        return min(upperLimit, max(0, value + step))
    }
}

struct BrightnessSliderDrag {
    private var accepted: Bool?
    private var position: Double?
    private var lastValue: Double?

    mutating func update(position: Double, startPosition: Double, showsHDRRange: Bool) -> Double? {
        if accepted == nil { accepted = showsHDRRange || startPosition <= 1 }
        guard accepted == true else { return nil }
        self.position = position
        return changedValue(min(showsHDRRange ? 2 : 1, max(0, position)))
    }

    mutating func revealHDRRange() -> Double? {
        guard let position, position > 1 else { return nil }
        return changedValue(min(2, position))
    }

    mutating func end() {
        self = Self()
    }

    private mutating func changedValue(_ value: Double) -> Double? {
        guard value != lastValue else { return nil }
        lastValue = value
        return value
    }
}

struct DisplayDiagnosticRow: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let nativeBrightness: Double?
    let requestedBoost: Double?
    let appliedGain: Double?
    let currentHeadroom: Double?
    let potentialHeadroom: Double?
    let path: String?
    let status: String
}

struct DisplayBoostSession {
    var singleDisplay: UInt32?
    var levels: [UInt32: Double] = [:]

    func strength(for display: UInt32, saved: @autoclosure () -> Double) -> Double {
        guard singleDisplay == nil || singleDisplay == display else { return 0 }
        return levels[display] ?? saved()
    }

    mutating func include(_ display: UInt32, among participating: [UInt32]) {
        guard let singleDisplay, singleDisplay != display else { return }
        for other in participating where other != singleDisplay {
            levels[other] = 0
        }
        self.singleDisplay = nil
    }
}

enum BrightnessDestination: Equatable {
    case native(Double)
    case boost(Double)

    init?(value: Double, mode: BrightnessControl.Mode) {
        guard value.isFinite else { return nil }
        if mode == .boost {
            self = .boost(min(1, max(0, value)))
        } else if mode == .combined, value > 1 {
            self = .boost(min(1, value - 1))
        } else {
            self = .native(min(1, max(0, value)))
        }
    }
}

struct BrightnessTransition {
    struct Request: Equatable {
        let displayID: UInt32
        let destination: BrightnessDestination
    }

    private(set) var request: Request?
    private(set) var restoration: UUID?

    mutating func submit(_ destination: BrightnessDestination, for displayID: UInt32) {
        if request?.displayID != displayID { cancel() }
        request = Request(displayID: displayID, destination: destination)
    }

    mutating func awaitRestoration() -> UUID {
        let token = UUID()
        restoration = token
        return token
    }

    mutating func finishRestoration(_ token: UUID) -> Request? {
        guard restoration == token else { return nil }
        restoration = nil
        return request
    }

    mutating func cancel() {
        request = nil
        restoration = nil
    }
}
