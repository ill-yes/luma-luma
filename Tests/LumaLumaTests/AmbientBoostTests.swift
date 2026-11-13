@main
struct AmbientBoostTests {
    static func main() {
        checkThresholdsAndHysteresis()
        checkBrokenDwell()
        checkMissingSamples()
        checkEligibilityAndPause()
        checkManualSuppression()
        checkNativeBrightnessLowering()
        checkUnavailableNativeBrightness()
        checkSensitivityChanges()
        print("Ambient boost timing, hysteresis, eligibility and manual override checks passed")
    }

    private struct Timeline {
        let start = ContinuousClock.now
        var policy = AmbientBoostPolicy()

        mutating func sample(
            _ lux: Double?, at seconds: Int, eligible: Bool = true,
            nativeBrightness: Double? = 1, sensitivity: AmbientSensitivity = .standard
        ) -> Bool {
            policy.update(
                lux: lux, eligible: eligible, nativeBrightness: nativeBrightness,
                sensitivity: sensitivity, now: start + .seconds(seconds)
            )
        }
    }

    private static func checkThresholdsAndHysteresis() {
        for (sensitivity, on, off): (AmbientSensitivity, Double, Double) in [
            (.standard, 3_000, 2_000), (.high, 1_500, 1_000), (.low, 6_000, 4_000)
        ] {
            var light = Timeline()
            assert(!light.sample(on - 1, at: 0, sensitivity: sensitivity))
            assert(!light.sample(on, at: 2, sensitivity: sensitivity))
            assert(!light.sample(on, at: 4, sensitivity: sensitivity))
            assert(light.sample(on, at: 6, sensitivity: sensitivity))
            assert(light.sample(on, at: 6, sensitivity: sensitivity))
            assert(light.sample(off + 1, at: 8, sensitivity: sensitivity))
            for time in stride(from: 10, through: 16, by: 2) {
                assert(light.sample(off, at: time, sensitivity: sensitivity))
            }
            assert(!light.sample(off, at: 18, sensitivity: sensitivity))
            assert(!light.sample(off + 1, at: 20, sensitivity: sensitivity))
        }
    }

    private static func checkBrokenDwell() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0))
        assert(!light.sample(3_000, at: 2))
        assert(!light.sample(2_500, at: 4))
        assert(!light.sample(3_000, at: 6))
        assert(!light.sample(3_000, at: 8))
        assert(light.sample(3_000, at: 10))
        assert(light.sample(1_900, at: 12))
        assert(light.sample(1_900, at: 14))
        assert(light.sample(2_500, at: 16))
        for time in stride(from: 18, through: 24, by: 2) {
            assert(light.sample(1_900, at: time))
        }
        assert(!light.sample(1_900, at: 26))
    }

    private static func checkMissingSamples() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0))
        assert(!light.sample(3_000, at: 2))
        assert(!light.sample(nil, at: 4))
        assert(!light.sample(3_000, at: 6))
        assert(!light.sample(3_000, at: 8))
        assert(light.sample(3_000, at: 10))
        assert(light.sample(-1, at: 12))
        assert(light.sample(.infinity, at: 14))
        assert(!light.sample(.nan, at: 16))
        assert(!light.sample(3_000, at: 18))
        assert(!light.sample(3_000, at: 20))
        assert(light.sample(3_000, at: 22))
        assert(!light.sample(3_000, at: 28))
    }

    private static func checkEligibilityAndPause() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0, eligible: false))
        assert(!light.sample(3_000, at: 2, eligible: false))
        assert(!light.sample(3_000, at: 4))
        assert(!light.sample(3_000, at: 6))
        assert(light.sample(3_000, at: 8))
        assert(!light.sample(nil, at: 8, eligible: false))
        assert(!light.sample(3_000, at: 10))
        assert(!light.sample(3_000, at: 12))
        assert(light.sample(3_000, at: 14))
        light.policy.pause()
        assert(!light.sample(3_000, at: 16))
        assert(!light.sample(3_000, at: 18))
        assert(light.sample(3_000, at: 20))
    }

    private static func checkManualSuppression() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0))
        assert(!light.sample(3_000, at: 2))
        assert(light.sample(3_000, at: 4))
        light.policy.suppressUntilDark()
        assert(!light.sample(3_000, at: 4))
        assert(!light.sample(3_000, at: 6, eligible: false))
        assert(!light.sample(nil, at: 14))
        light.policy.pause()
        assert(light.policy.isSuppressed)
        assert(!light.sample(3_000, at: 16))
        assert(!light.sample(2_000, at: 18))
        assert(!light.sample(nil, at: 20))
        for time in stride(from: 22, through: 28, by: 2) {
            assert(!light.sample(2_000, at: time, eligible: false))
            assert(light.policy.isSuppressed)
        }
        assert(!light.sample(2_000, at: 30, eligible: false))
        assert(!light.policy.isSuppressed)
        assert(!light.sample(3_000, at: 32))
        assert(!light.sample(3_000, at: 34))
        assert(light.sample(3_000, at: 36))
    }

    private static func checkSensitivityChanges() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0))
        assert(!light.sample(3_000, at: 2))
        assert(!light.sample(3_000, at: 4, sensitivity: .high))
        assert(!light.sample(3_000, at: 6, sensitivity: .high))
        assert(light.sample(3_000, at: 8, sensitivity: .high))
    }

    private static func checkNativeBrightnessLowering() {
        var light = Timeline()
        assert(!light.sample(3_000, at: 0, nativeBrightness: 0.99))
        assert(!light.sample(3_000, at: 2, nativeBrightness: 0.99))
        assert(!light.sample(3_000, at: 4, nativeBrightness: 0.999))
        assert(!light.sample(3_000, at: 6))
        assert(light.sample(3_000, at: 8))
        assert(!light.sample(3_000, at: 10, nativeBrightness: 0.99))
        for time in stride(from: 12, through: 16, by: 2) {
            assert(!light.sample(3_000, at: time))
            assert(light.policy.isSuppressed)
        }
        for time in stride(from: 18, through: 26, by: 2) {
            assert(!light.sample(2_000, at: time, nativeBrightness: 0.99))
        }
        assert(!light.policy.isSuppressed)
        assert(!light.sample(3_000, at: 28))
        assert(!light.sample(3_000, at: 30))
        assert(light.sample(3_000, at: 32))
    }

    private static func checkUnavailableNativeBrightness() {
        for unavailable: Double? in [nil, .nan, .infinity, -0.01, 1.01] {
            var light = Timeline()
            assert(!light.sample(3_000, at: 0))
            assert(!light.sample(3_000, at: 2))
            assert(light.sample(3_000, at: 4))
            assert(!light.sample(3_000, at: 6, nativeBrightness: unavailable))
            assert(!light.policy.isSuppressed)
            assert(!light.sample(3_000, at: 8))
            assert(!light.sample(3_000, at: 10))
            assert(light.sample(3_000, at: 12))
        }
    }
}
