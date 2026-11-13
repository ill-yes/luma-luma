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
        try await testExplicitRestorationKeepsTheDisplayAndOutcome()
        try await testRestoreRemainsPendingUntilHelperExits()
        try await testPreparationAndInFlightChangesUseLatestStrength()
        try await testHeadroomRecoveryWaitsForRestoration()
        try await testInFlightFailureCancelsRecovery()
        try await testNewAttemptIgnoresLateFailure()
        try await testRecoveryPreservesRestorationFailures()
        try await testRecoveryTimeoutIsTerminal()
        try await testStopCancelsPendingRecovery()
        try await testLateBeginReplyCannotReactivateStoppedSession()
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
    private static func testExplicitRestorationKeepsTheDisplayAndOutcome() async throws {
        let outcomes: [(String, GammaEndResult)] = [("ok", .restored), ("conflict", .conflict), ("error", .failed)]
        for (reply, expected) in outcomes {
            let helper = try makeRecordingHelper(beforeReply: """
            if [ "$command" = end ]; then
                printf '\(reply)\\n'
                sleep 0.25
                exit 0
            fi
            """)
            let directory = helper.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GammaBoostSession(helperURL: helper)
            let beginDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !session.needsTrigger, ContinuousClock.now < beginDeadline {
                _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: false)
                try await Task.sleep(for: .milliseconds(25))
            }
            precondition(session.needsTrigger)

            session.stop()
            session.reassociateDisplay(from: 42, to: 43)
            var completions: [GammaEndResult] = []
            session.restore(on: 42) { precondition($0 == .notNeeded) }
            session.restore(on: 43) { completions.append($0) }
            session.restore(on: 43) { completions.append($0) }
            precondition(session.isRestoring(on: 43) && !session.isRestoring(on: 42))
            precondition(completions.isEmpty)

            let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.isRestoring, ContinuousClock.now < restoreDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            precondition(completions == [expected, expected])
            session.restore(on: 43) { precondition($0 == expected) }
            precondition(readCommands(in: directory) == ["begin 42", "end"])
            session.forgetDisplay(43)
            session.restore(on: 43) { precondition($0 == .notNeeded) }
        }
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

    @MainActor
    private static func testPreparationAndInFlightChangesUseLatestStrength() async throws {
        let helper = try makeRecordingHelper(beforeReply: """
        case "$command" in
            apply*) sleep 0.15 ;;
        esac
        """)
        let directory = helper.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = GammaBoostSession(helperURL: helper)
        var confirmedGains: [Double] = []
        session.onStatusChanged = { [weak session] in
            if let gain = session?.appliedGain(on: 42) { confirmedGains.append(gain) }
        }
        _ = session.update(displayID: 42, strength: 0.1, currentHeadroom: 1.5, triggerReady: true)
        try await Task.sleep(for: .milliseconds(100))

        let preparingUntil = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < preparingUntil {
            let status = session.update(displayID: 42, strength: 0.4, currentHeadroom: 1.5, triggerReady: true)
            precondition(status == .starting)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(!readCommands(in: directory).contains(where: { $0.hasPrefix("apply ") }))

        let firstApplyDeadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !readCommands(in: directory).contains("apply 1.18"), ContinuousClock.now < firstApplyDeadline {
            _ = session.update(displayID: 42, strength: 0.4, currentHeadroom: 1.5, triggerReady: true)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(readCommands(in: directory).contains("apply 1.18"))
        _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
        let latestApplyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !readCommands(in: directory).contains("apply 1.45"), ContinuousClock.now < latestApplyDeadline {
            _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(readCommands(in: directory).contains("apply 1.45"))
        while confirmedGains.last != 1.45, ContinuousClock.now < latestApplyDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(confirmedGains == [1.18, 1.45])
        precondition(session.appliedGain(on: 43) == nil)
        session.stop(waitForRestoration: true)
        precondition(session.appliedGain(on: 42) == nil)
    }

    @MainActor
    private static func testHeadroomRecoveryWaitsForRestoration() async throws {
        let helper = try makeRecordingHelper(beforeReply: delayedRestoration)
        let directory = helper.deletingLastPathComponent()
        let allowExit = directory.appendingPathComponent("allow-exit")
        defer { try? Data().write(to: allowExit) }
        let session = GammaBoostSession(helperURL: helper)
        try await waitUntilActive(session, strength: 0.25)

        let status = session.update(displayID: 42, strength: 1, currentHeadroom: 1, triggerReady: true)
        precondition(status == .starting && session.isRestoring)
        let pendingUntil = ContinuousClock.now.advanced(by: .milliseconds(300))
        while ContinuousClock.now < pendingUntil {
            let pending = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
            precondition(pending == .starting && session.isRestoring)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(readCommands(in: directory).filter { $0 == "begin 42" }.count == 1)
        precondition(!readCommands(in: directory).contains("apply 1.45"))

        try Data().write(to: allowExit)
        try await waitUntilActive(session, strength: 1)
        let commands = readCommands(in: directory)
        precondition(commands.filter { $0 == "begin 42" }.count == 2)
        precondition(commands.contains("apply 1.1125") && commands.contains("apply 1.45"))
        precondition(session.restorationStatus == nil)
        session.stop(waitForRestoration: true)
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private static func testStopCancelsPendingRecovery() async throws {
        let helper = try makeRecordingHelper(beforeReply: delayedRestoration)
        let directory = helper.deletingLastPathComponent()
        let allowExit = directory.appendingPathComponent("allow-exit")
        defer { try? Data().write(to: allowExit) }
        let session = GammaBoostSession(helperURL: helper)
        try await waitUntilActive(session, strength: 1)
        precondition(session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: false) == .starting)
        session.stop()
        try Data().write(to: allowExit)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while session.isRestoring, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(!session.isRestoring && !session.needsTrigger)
        try await Task.sleep(for: .milliseconds(300))
        precondition(readCommands(in: directory).filter { $0 == "begin 42" }.count == 1)
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private static func testRecoveryPreservesRestorationFailures() async throws {
        let failures: [(String, Int, GammaBoostStatus)] = [
            ("conflict", 0, .conflict),
            ("error", 1, .restorationFailed),
        ]
        for (reply, exitCode, expectedStatus) in failures {
            let helper = try makeRecordingHelper(beforeReply: """
            if [ "$command" = end ]; then
                printf '\(reply)\\n'
                exit \(exitCode)
            fi
            """)
            let directory = helper.deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GammaBoostSession(helperURL: helper)
            try await waitUntilActive(session, strength: 1)
            precondition(session.update(displayID: 42, strength: 1, currentHeadroom: 1, triggerReady: true) == .starting)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.isRestoring, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            precondition(!session.isRestoring)
            for _ in 0..<3 {
                let status = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
                precondition(status == expectedStatus)
                try await Task.sleep(for: .milliseconds(25))
            }
            precondition(readCommands(in: directory).filter { $0 == "begin 42" }.count == 1)
            session.stop()
        }
    }

    @MainActor
    private static func testInFlightFailureCancelsRecovery() async throws {
        let commands = ["check", "apply 1.45"]
        let failures: [(String, GammaBoostStatus)] = [("conflict", .conflict), ("error", .failed)]
        for command in commands {
            for (reply, expectedStatus) in failures {
                let helper = try makeRecordingHelper(beforeReply: """
                if [ "$command" = "\(command)" ]; then
                    touch "$directory/reply-waiting"
                    while [ ! -f "$directory/allow-reply" ]; do sleep 0.02; done
                    printf '\(reply)\\n'
                    continue
                fi
                """)
                let directory = helper.deletingLastPathComponent()
                let allowReply = directory.appendingPathComponent("allow-reply")
                defer { try? Data().write(to: allowReply) }
                let session = GammaBoostSession(helperURL: helper)
                try await waitUntilActive(session, strength: 0.25)
                let desiredStrength = command == "check" ? 0.25 : 1.0
                let commandDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-waiting").path),
                      ContinuousClock.now < commandDeadline {
                    _ = session.update(displayID: 42, strength: desiredStrength, currentHeadroom: 1.5, triggerReady: true)
                    try await Task.sleep(for: .milliseconds(25))
                }
                precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-waiting").path))
                precondition(session.update(displayID: 42, strength: desiredStrength, currentHeadroom: 1, triggerReady: true) == .starting)
                try Data().write(to: allowReply)

                let responseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                var status = GammaBoostStatus.starting
                while status == .starting, ContinuousClock.now < responseDeadline {
                    status = session.update(displayID: 42, strength: desiredStrength, currentHeadroom: 1.5, triggerReady: true)
                    try await Task.sleep(for: .milliseconds(25))
                }
                precondition(status == expectedStatus)
                while session.isRestoring, ContinuousClock.now < responseDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                precondition(!session.isRestoring && session.restorationStatus == nil)
                precondition(session.update(displayID: 42, strength: desiredStrength, currentHeadroom: 1.5, triggerReady: true) == expectedStatus)
                precondition(readCommands(in: directory).filter { $0 == "begin 42" }.count == 1)
                precondition(readCommands(in: directory).last == "end")
                session.stop()
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    @MainActor
    private static func testRecoveryTimeoutIsTerminal() async throws {
        let helper = try makeRecordingHelper()
        let directory = helper.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = GammaBoostSession(helperURL: helper)
        try await waitUntilActive(session, strength: 1)
        precondition(session.update(displayID: 42, strength: 1, currentHeadroom: 1, triggerReady: true) == .starting)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = GammaBoostStatus.starting
        while status == .starting, ContinuousClock.now < deadline {
            status = session.update(displayID: 42, strength: 1, currentHeadroom: 1, triggerReady: true)
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(status == .unavailable)
        for _ in 0..<3 {
            precondition(session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true) == .unavailable)
        }
        precondition(readCommands(in: directory).filter { $0 == "begin 42" }.count == 2)
        session.stop(waitForRestoration: true)
    }

    @MainActor
    private static func testNewAttemptIgnoresLateFailure() async throws {
        let helper = try makeRecordingHelper(beforeReply: """
        if [ "$command" = 'apply 1.45' ]; then
            touch "$directory/reply-waiting"
            while [ ! -f "$directory/allow-reply" ]; do sleep 0.02; done
            printf 'conflict\\n'
            continue
        fi
        """)
        let directory = helper.deletingLastPathComponent()
        let allowReply = directory.appendingPathComponent("allow-reply")
        defer { try? Data().write(to: allowReply) }
        let session = GammaBoostSession(helperURL: helper)
        try await waitUntilActive(session, strength: 0.25)
        _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
        let commandDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-waiting").path),
              ContinuousClock.now < commandDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-waiting").path))
        session.stop()
        var explicitRestoration: GammaEndResult?
        session.restore(on: 42) { explicitRestoration = $0 }
        _ = session.update(displayID: 43, strength: 0.25, currentHeadroom: 1.5, triggerReady: true)
        try Data().write(to: allowReply)
        try await waitUntilActive(session, displayID: 43, strength: 0.25)
        precondition(explicitRestoration == .conflict)
        precondition(readCommands(in: directory).contains("begin 43"))
        session.stop(waitForRestoration: true)
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private static func testLateBeginReplyCannotReactivateStoppedSession() async throws {
        let helper = try makeRecordingHelper(beforeReply: """
        case "$command" in
            begin*) sleep 0.15 ;;
        esac
        """)
        let directory = helper.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = GammaBoostSession(helperURL: helper)
        _ = session.update(displayID: 42, strength: 1, currentHeadroom: 1.5, triggerReady: true)
        session.stop()
        try await Task.sleep(for: .milliseconds(400))
        precondition(!session.needsTrigger && !session.isRestoring)
        precondition(readCommands(in: directory) == ["begin 42", "end"])

        try await waitUntilActive(session, displayID: 43, strength: 1)
        precondition(readCommands(in: directory).contains("begin 43"))
        precondition(readCommands(in: directory).filter { $0.hasPrefix("apply ") } == ["apply 1.45"])
        session.stop(waitForRestoration: true)
    }

    @MainActor
    private static func waitUntilActive(
        _ session: GammaBoostSession,
        displayID: UInt32 = 42,
        strength: Double
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            let status = session.update(displayID: displayID, strength: strength, currentHeadroom: 1.5, triggerReady: true)
            if status == .active { return }
            precondition(status == .starting, "Unexpected terminal status \(status)")
            try await Task.sleep(for: .milliseconds(25))
        }
        preconditionFailure("HDR session did not become active")
    }

    private static let delayedRestoration = """
    if [ "$command" = end ]; then
        printf 'error\\n'
        while [ ! -f "$directory/allow-exit" ]; do sleep 0.02; done
        exit 0
    fi
    """

    private static func makeRecordingHelper(beforeReply: String = "") throws -> URL {
        try makeHelper("""
        directory="$(dirname "$0")"
        while IFS= read -r command; do
            printf '%s\\n' "$command" >> "$directory/commands"
            \(beforeReply)
            printf 'ok\\n'
            [ "$command" = end ] && exit 0
        done
        """)
    }

    private static func readCommands(in directory: URL) -> [String] {
        let contents = try? String(contentsOf: directory.appendingPathComponent("commands"), encoding: .utf8)
        return contents?.split(separator: "\n").map(String.init) ?? []
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
