import Foundation

@main
struct GammaBoostSessionTests {
    @MainActor
    static func main() async throws {
        testGateWaitsForTwoStableSecondsAfterTrigger()
        testCumulativeDriftResetsStabilityWindow()
        testLowOrInvalidHeadroomResetsStability()
        testDeadlineWinsOverLateHeadroom()
        print("HDR stability gate checks passed.")
        try await testBusyHelperCanBeRetried()
        try await testRejectedHelperDoesNotReportRestoreFailure()
        try await testRestoreRemainsPendingUntilHelperExits()
        print("HDR helper protocol checks passed.")
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

    @MainActor
    private static func testBusyHelperCanBeRetried() async throws {
        let helper = try makeHelper("""
        directory="$(dirname "$0")"
        IFS= read -r command || exit 1
        printf '%s\\n' "$command" >> "$directory/commands"
        if [ ! -f "$directory/attempted" ]; then
            touch "$directory/attempted"
            printf 'busy\\n'
            sleep 0.4
            exit 0
        fi
        printf 'ok\\n'
        while IFS= read -r command; do
            printf '%s\\n' "$command" >> "$directory/commands"
            printf 'ok\\n'
        done
        """)
        let directory = helper.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = GammaBoostSession(helperURL: helper)
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        var status: GammaBoostStatus = .starting
        while status == .starting, ContinuousClock.now < deadline {
            status = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
            if status == .starting { try await Task.sleep(for: .milliseconds(50)) }
        }
        precondition(status == .active)
        precondition(session.restorationStatus == nil)
        session.stop(waitForRestoration: true)
        let commands = try String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        precondition(commands == "begin 42\nbegin 42\napply 1.45\nend\n", "Unexpected helper commands \(commands)")
    }

    @MainActor
    private static func testRejectedHelperDoesNotReportRestoreFailure() async throws {
        let helper = try makeHelper("""
        IFS= read -r command || exit 1
        printf 'error\\n'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let session = GammaBoostSession(helperURL: helper)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var status: GammaBoostStatus = .starting
        while status == .starting, ContinuousClock.now < deadline {
            status = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
            if status == .starting { try await Task.sleep(for: .milliseconds(50)) }
        }
        precondition(status == .failed)
        precondition(!session.isRestoring)
        precondition(session.restorationStatus == nil)
    }

    @MainActor
    private static func testRestoreRemainsPendingUntilHelperExits() async throws {
        let helper = try makeHelper("""
        directory="$(dirname "$0")"
        IFS= read -r command || exit 1
        printf '%s\\n' "$command" >> "$directory/commands"
        printf 'ok\\n'
        while IFS= read -r command; do
            printf '%s\\n' "$command" >> "$directory/commands"
            if [ "$command" = end ]; then
                printf 'error\\n'
                attempts=0
                while [ ! -f "$directory/allow-exit" ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.02
                    attempts=$((attempts + 1))
                done
                [ -f "$directory/allow-exit" ] && exit 0
                exit 1
            fi
            printf 'ok\\n'
        done
        """)
        let directory = helper.deletingLastPathComponent()
        let allowExit = directory.appendingPathComponent("allow-exit")
        defer {
            if !FileManager.default.fileExists(atPath: allowExit.path) {
                try? Data().write(to: allowExit)
            }
        }

        let session = GammaBoostSession(helperURL: helper)
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !session.needsTrigger, ContinuousClock.now < startDeadline {
            _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: false)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(session.needsTrigger)
        session.stop(waitForRestoration: true)
        precondition(session.isRestoring)
        precondition(session.restorationStatus == nil)

        let log = directory.appendingPathComponent("commands")
        let commands = try String(contentsOf: log, encoding: .utf8)
        precondition(commands == "begin 42\nend\n")
        // Keep the helper alive past the old 5.5-second forced completion.
        let busyUntil = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < busyUntil {
            let status = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: false)
            precondition(status == .starting && !session.needsTrigger && session.isRestoring)
            try await Task.sleep(for: .milliseconds(25))
        }
        let waitingCommands = try String(contentsOf: log, encoding: .utf8)
        precondition(waitingCommands == commands)
        session.stop()

        try Data().write(to: allowExit)
        let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.isRestoring, ContinuousClock.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(!session.isRestoring)
        precondition(session.restorationStatus == nil)
        try FileManager.default.removeItem(at: directory)
    }

    private static func makeHelper(_ commands: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luma-luma-helper-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let helper = directory.appendingPathComponent("helper")
        try ("#!/bin/sh\n" + commands + "\n").write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
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
