enum BrightnessKeyRouting {
    enum BoostState {
        case ready
        case starting
        case active
        case unavailable
    }

    enum Decision: Equatable {
        case system
        case waitForRestoration
        case setBoost(Double)
    }

    static func step(fine: Bool) -> Double {
        fine ? 1.0 / 64 : 1.0 / 16
    }

    static func decide(
        increase: Bool,
        fine: Bool,
        hardwareLevel: Double?,
        strength: Double,
        boostState: BoostState,
        restoring: Bool
    ) -> Decision {
        if restoring {
            return increase ? .system : .waitForRestoration
        }
        guard boostState != .unavailable else { return .system }
        let amount = step(fine: fine)
        if increase {
            guard let hardwareLevel, hardwareLevel >= 0.999 else { return .system }
            return .setBoost(min(1, strength + amount))
        }
        guard strength > 0, boostState == .active || boostState == .starting else { return .system }
        return .setBoost(max(0, strength - amount))
    }
}

struct BacklightSyncResult: Equatable {
    let referenceSucceeded: Bool
    let failedFollowers: [UInt32]

    static let referenceFailed = Self(referenceSucceeded: false, failedFollowers: [])

    static func apply(
        reference: UInt32,
        followers: [UInt32],
        write: (UInt32) -> Bool
    ) -> Self {
        guard write(reference) else { return .referenceFailed }
        return Self(referenceSucceeded: true, failedFollowers: followers.filter { !write($0) })
    }
}
