import Foundation

@main
struct GammaLeaseTests {
    static func main() {
        testBoostUsesImmutableBaselineAndRestoresPerDisplay()
        testRejectsAnExistingBoostAndUntrustedCommands()
        testExternalChangeBetweenCaptureAndApplyIsNotOverwritten()
        testDetectsAnyChangedChannelBeforeRestoring()
        testCheckFindsDriftAndAbandonsLease()
        testFailedWriteIsNotReportedAsActiveAndLeavesUnchangedBaseline()
        testFailedWriteWithMutationIsRestored()
        testClampedWriteIsNotReportedAsActiveAndIsRestored()
        testCompactUploadAndFullResolutionRestore()
        testDelayedWriteStaysOwnedUntilReadbackAndRestoration()
        testUnchangedCurveCannotConfirmAClampedAttempt()
        testDisconnectWaitsForAcceptedWriteBeyondRetryDeadline()
        testUnavailableReadbackDoesNotAcknowledgeWriteButCanRecoverOwnership()
        testUnavailableDisplayCanReconnectUnderNewIDBeforeRestoration()
        testDisconnectKeepsOfflineBaselineBeyondInitialDeadline()
        testDisconnectStopsRetryingPermanentOnlineWriteFailure()
        testReusedIDWithAnotherIdentityIsNeverWritten()
        testEOFRestoresAndBrokenReplyAlsoRestores()
        print("Passed 18 gamma lease tests")
    }

    private static func testBoostUsesImmutableBaselineAndRestoresPerDisplay() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)

        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1") == .ok)
        expect(backend.writes.isEmpty)
        expect(lease.handle("apply 1.45") == .ok)
        expect(backend.curve == backend.baseline.scaled(by: 1.45))
        expect(backend.curve.red.last == 1.45)
        expect(lease.handle("apply 1.25") == .ok)
        expect(backend.curve == backend.baseline.scaled(by: 1.25))
        expect(lease.handle("check") == .ok)
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
        expect(backend.writes.map(\.display) == [1, 1, 1])
        expect(lease.handle("end") == .ok)
    }

    private static func testRejectsAnExistingBoostAndUntrustedCommands() {
        let backend = FakeGammaBackend()
        backend.curve = backend.baseline.scaled(by: 1.45)
        var lease = GammaLease(backend: backend)

        expect(lease.handle("begin 1") == .conflict)
        expect(lease.handle("begin 2") == .unsupported)
        for command in ["", "apply NaN", "apply 1.450001", "apply inf", "begin 0", "end extra", "bégin 1"] {
            expect(lease.handle(command) == .error)
        }
        expect(lease.handle("end") == .ok)
        expect(backend.writes.isEmpty)
    }

    private static func testExternalChangeBetweenCaptureAndApplyIsNotOverwritten() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        let changed = backend.baseline.scaled(by: 0.85)
        backend.curve = changed

        expect(lease.handle("apply 1.45") == .conflict)
        expect(lease.handle("end") == .ok)
        expect(backend.writes.isEmpty)
        expect(backend.curve == changed)
    }

    private static func testDetectsAnyChangedChannelBeforeRestoring() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        let changed = GammaCurve(
            red: backend.curve.red,
            green: backend.curve.green,
            blue: [backend.curve.blue[0], 0.7, backend.curve.blue[2]]
        )
        backend.curve = changed

        expect(lease.handle("end") == .conflict)
        expect(backend.curve == changed)
        expect(backend.writes.count == 1)
    }

    private static func testCheckFindsDriftAndAbandonsLease() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        backend.curve = backend.baseline

        expect(lease.handle("check") == .conflict)
        expect(lease.handle("end") == .ok)
        expect(backend.writes.count == 1)
    }

    private static func testFailedWriteIsNotReportedAsActiveAndLeavesUnchangedBaseline() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .failedWithoutMutation

        expect(lease.handle("apply 1.45") == .error)
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
        expect(backend.writes.count == 1)
    }

    private static func testFailedWriteWithMutationIsRestored() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .failedAfterMutation

        expect(lease.handle("apply 1.45") == .error)
        expect(backend.curve.red.last == 1.45)
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
    }

    private static func testClampedWriteIsNotReportedAsActiveAndIsRestored() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .clamped

        expect(lease.handle("apply 1.45") == .error)
        expect(backend.curve == backend.baseline.scaled(by: 1.45).clamped())
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
    }

    private static func testCompactUploadAndFullResolutionRestore() {
        let sampleCount = 1024
        let linear = (0..<sampleCount).map { Float($0) / Float(sampleCount - 1) }
        let baseline = GammaCurve(red: linear, green: linear.map { $0 * $0 }, blue: linear.map { $0 * 0.95 })
        let backend = FakeGammaBackend(baseline: baseline)
        var lease = GammaLease(backend: backend)

        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        expect(backend.writes[0].curve.count == 256)
        expect(backend.writes[0].curve.red[85] == baseline.red[341] * 1.45)
        expect(backend.curve.count == sampleCount)
        expect(backend.curve.red.last == 1.45)
        expect(lease.handle("check") == .ok)
        expect(lease.handle("end") == .ok)
        expect(backend.writes[1].curve == baseline)
        expect(backend.curve == baseline)
    }

    private static func testDelayedWriteStaysOwnedUntilReadbackAndRestoration() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .delayed
        expect(lease.handle("apply 1.45") == .error)
        expect(backend.curve == backend.baseline)
        expect(lease.handle("end") == .error)
        expect(lease.handle("check") == .error)
        backend.completeDelayedWrite()
        expect(backend.curve.red.last == 1.45)
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
    }

    private static func testDisconnectWaitsForAcceptedWriteBeyondRetryDeadline() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .delayed
        expect(lease.handle("apply 1.45") == .error)
        // Leave the prior curve readable beyond the former 250 ms uncertainty window.
        Thread.sleep(forTimeInterval: 0.3)
        expect(lease.handle("check") == .error)
        let start = ContinuousClock.now
        var time = start
        var delays: [TimeInterval] = []

        let restored = lease.restoreAfterDisconnect(now: { time }) { delay in
            delays.append(delay)
            time += .seconds(delay)
            if time >= start.advanced(by: .seconds(7)) {
                backend.completeDelayedWrite()
            }
        }

        expect(restored)
        expect(delays.last == 2)
        expect(backend.curve == backend.baseline)
        expect(backend.writes.map(\.curve) == [backend.baseline.scaled(by: 1.45), backend.baseline])
    }

    private static func testUnchangedCurveCannotConfirmAClampedAttempt() {
        let baseline = GammaCurve(red: [0, 1, 1], green: [0, 1, 1], blue: [0, 1, 1])
        let backend = FakeGammaBackend(baseline: baseline)
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .delayed
        expect(lease.handle("apply 1.45") == .error)
        expect(lease.handle("check") == .error)
        expect(lease.handle("end") == .error)
        backend.completeDelayedWrite()
        expect(lease.handle("end") == .ok)
        expect(backend.curve == baseline)
    }

    private static func testUnavailableReadbackDoesNotAcknowledgeWriteButCanRecoverOwnership() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        backend.nextWrite = .muteReadback

        expect(lease.handle("apply 1.45") == .error)
        backend.blockReads = false
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
    }

    private static func testUnavailableDisplayCanReconnectUnderNewIDBeforeRestoration() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        backend.availableDisplay = nil

        expect(lease.handle("end") == .error)
        expect(backend.writes.count == 1)
        backend.availableDisplay = 2
        expect(lease.handle("end") == .ok)
        expect(backend.curve == backend.baseline)
        expect(backend.writes.map(\.display) == [1, 2])
    }

    private static func testDisconnectKeepsOfflineBaselineBeyondInitialDeadline() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        backend.availableDisplay = nil
        let start = ContinuousClock.now
        var time = start

        let restored = lease.restoreAfterDisconnect(now: { time }) { delay in
            time += .seconds(delay)
            if time >= start.advanced(by: .seconds(7)) {
                backend.availableDisplay = 2
            }
        }

        expect(restored)
        expect(backend.curve == backend.baseline)
        expect(backend.writes.map(\.display) == [1, 2])
    }

    private static func testDisconnectStopsRetryingPermanentOnlineWriteFailure() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        backend.nextWrite = .failedWithoutMutation
        let start = ContinuousClock.now
        var time = start

        let restored = lease.restoreAfterDisconnect(now: { time }) { delay in
            time += .seconds(delay)
            backend.nextWrite = .failedWithoutMutation
        }

        expect(!restored)
        expect(time == start.advanced(by: .seconds(5)))
        expect(backend.curve.red.last == 1.45)
    }

    private static func testReusedIDWithAnotherIdentityIsNeverWritten() {
        let backend = FakeGammaBackend()
        var lease = GammaLease(backend: backend)
        expect(lease.handle("begin 1") == .ok)
        expect(lease.handle("apply 1.45") == .ok)
        let expected = backend.currentIdentity
        backend.currentIdentity = UUID()

        expect(lease.handle("end") == .error)
        expect(backend.writes.count == 1)
        backend.currentIdentity = expected
        expect(lease.handle("end") == .ok)
    }

    private static func testEOFRestoresAndBrokenReplyAlsoRestores() {
        for breakAfterApply in [false, true] {
            let backend = FakeGammaBackend()
            var lease = GammaLease(backend: backend)
            var commands = ["begin 1", "apply 1.45"].makeIterator()
            var replies: [GammaReply] = []

            let restored = lease.run(readCommand: { commands.next() }) { reply in
                replies.append(reply)
                return !breakAfterApply || replies.count < 2
            }

            expect(restored)
            expect(replies == [.ok, .ok])
            expect(backend.curve == backend.baseline)
            expect(backend.writes.count == 2)
        }
    }
}

private final class FakeGammaBackend: GammaBackend {
    enum WriteOutcome {
        case success
        case failedWithoutMutation
        case failedAfterMutation
        case clamped
        case delayed
        case muteReadback
    }

    let baseline: GammaCurve
    var curve: GammaCurve
    var currentIdentity = UUID()
    var availableDisplay: UInt32? = 1
    var nextWrite = WriteOutcome.success
    var blockReads = false
    private var delayedCurve: GammaCurve?
    private(set) var writes: [(display: UInt32, curve: GammaCurve)] = []

    init(baseline: GammaCurve = GammaCurve(red: [0, 0.3, 1], green: [0, 0.4, 0.98], blue: [0, 0.5, 0.96])) {
        self.baseline = baseline
        curve = baseline
    }

    func completeDelayedWrite() {
        if let delayedCurve {
            curve = delayedCurve
            self.delayedCurve = nil
        }
    }

    func identity(of display: UInt32) -> UUID? {
        display == availableDisplay ? currentIdentity : nil
    }

    func display(for identity: UUID) -> UInt32? {
        identity == currentIdentity ? availableDisplay : nil
    }

    func read(from display: UInt32, identity: UUID) -> GammaCurve? {
        !blockReads && self.identity(of: display) == identity ? curve : nil
    }

    func write(_ requested: GammaCurve, to display: UInt32, identity: UUID) -> Bool {
        guard self.identity(of: display) == identity else { return false }
        writes.append((display, requested))
        let result = requested.resampled(to: baseline.count)
        let outcome = nextWrite
        nextWrite = .success
        switch outcome {
        case .success:
            curve = result
            return true
        case .failedWithoutMutation:
            return false
        case .failedAfterMutation:
            curve = result
            return false
        case .clamped:
            curve = result.clamped()
            return true
        case .delayed:
            delayedCurve = result
            return true
        case .muteReadback:
            curve = result
            blockReads = true
            return true
        }
    }
}

private func expect(
    _ result: @autoclosure () -> Bool,
    file: StaticString = #file,
    line: UInt = #line
) {
    precondition(result(), "Gamma lease assertion failed", file: file, line: line)
}
