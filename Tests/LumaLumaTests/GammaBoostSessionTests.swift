@main
struct GammaBoostSessionTests {
    static func main() {
        testGateWaitsForTwoStableSecondsAfterTrigger()
        testCumulativeDriftResetsStabilityWindow()
        testLowOrInvalidHeadroomResetsStability()
        testDeadlineWinsOverLateHeadroom()
        print("HDR stability gate checks passed.")
    }

    private static func testGateWaitsForTwoStableSecondsAfterTrigger() {
        var gate = HDRStabilityGate()
        expect(gate.sample(headroom: 1.45, triggerReady: false, at: .zero), .waiting)
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .seconds(1)), .waiting)
        expect(gate.sample(headroom: 1.49, triggerReady: true, at: .milliseconds(2_999)), .waiting)
        expect(gate.sample(headroom: 1.50, triggerReady: true, at: .seconds(3)), .ready)
    }

    private static func testCumulativeDriftResetsStabilityWindow() {
        var gate = HDRStabilityGate()
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .zero), .waiting)
        expect(gate.sample(headroom: 1.48, triggerReady: true, at: .seconds(1)), .waiting)
        expect(gate.sample(headroom: 1.51, triggerReady: true, at: .seconds(2)), .waiting)
        expect(gate.sample(headroom: 1.50, triggerReady: true, at: .seconds(4)), .ready)
    }

    private static func testLowOrInvalidHeadroomResetsStability() {
        var gate = HDRStabilityGate()
        expect(gate.sample(headroom: 1.06, triggerReady: true, at: .zero), .waiting)
        expect(gate.sample(headroom: 1.05, triggerReady: true, at: .seconds(1)), .waiting)
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .seconds(2)), .waiting)
        expect(gate.sample(headroom: .infinity, triggerReady: true, at: .seconds(3)), .waiting)
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .seconds(4)), .waiting)
        expect(gate.sample(headroom: 1.44, triggerReady: true, at: .seconds(6)), .ready)
    }

    private static func testDeadlineWinsOverLateHeadroom() {
        var gate = HDRStabilityGate()
        expect(gate.sample(headroom: 1.0, triggerReady: true, at: .zero), .waiting)
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .seconds(6)), .waiting)
        expect(gate.sample(headroom: 1.45, triggerReady: true, at: .seconds(8)), .timedOut)
    }

    private static func expect(
        _ actual: HDRStabilityGate.Result,
        _ expected: HDRStabilityGate.Result,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(actual == expected, "Expected \(expected), received \(actual)", file: file, line: line)
    }
}
