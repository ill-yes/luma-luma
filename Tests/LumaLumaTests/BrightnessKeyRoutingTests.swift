@main
struct BrightnessKeyRoutingTests {
    private typealias Routing = BrightnessKeyRouting

    static func main() {
        assert(route(up: true, hardware: 0.98) == .system)
        assert(route(up: true, hardware: 1) == .setBoost(1.0 / 16))
        assert(route(up: true, hardware: 1, fine: true) == .setBoost(1.0 / 64))
        assert(route(up: true, hardware: nil) == .system)
        assert(route(up: true, hardware: 1, strength: 1, state: .active) == .setBoost(1))
        assert(route(up: false, strength: 0.125, state: .active) == .setBoost(0.0625))
        assert(route(up: false, strength: 0.0625, state: .active) == .setBoost(0))
        assert(route(up: false, strength: 0.015625, state: .starting, fine: true) == .setBoost(0))
        assert(route(up: false, restoring: true) == .waitForRestoration)
        assert(route(up: false) == .system)
        assert(route(up: true, hardware: 1, state: .unavailable) == .system)
        assert(route(up: false, strength: 0.65, state: .unavailable) == .system)
        checkHardwareSynchronization()
        print("Brightness routing and hardware synchronization checks passed")
    }

    private static func route(
        up: Bool,
        hardware: Double? = 1,
        strength: Double = 0,
        state: Routing.BoostState = .ready,
        fine: Bool = false,
        restoring: Bool = false
    ) -> Routing.Decision {
        Routing.decide(
            increase: up, fine: fine, hardwareLevel: hardware, strength: strength,
            boostState: state, restoring: restoring
        )
    }

    private static func checkHardwareSynchronization() {
        var writes: [UInt32] = []
        let failure = BacklightSyncResult.apply(reference: 1, followers: [2, 3]) {
            writes.append($0)
            return false
        }
        assert(failure == .referenceFailed && writes == [1])

        writes.removeAll()
        let partial = BacklightSyncResult.apply(reference: 1, followers: [2, 3]) {
            writes.append($0)
            return $0 != 2
        }
        assert(partial.referenceSucceeded && partial.failedFollowers == [2] && writes == [1, 2, 3])
    }
}
