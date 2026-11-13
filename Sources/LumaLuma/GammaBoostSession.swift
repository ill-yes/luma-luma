import CoreGraphics
import Darwin
import Foundation

enum GammaBoostStatus: Equatable {
    case starting
    case active
    case unavailable
    case conflict
    case failed
    case restorationFailed
}

struct HDRStabilityGate {
    enum Result: Equatable {
        case waiting
        case ready
        case timedOut
    }

    private var stableSince: Duration?
    private var low = 0.0
    private var high = 0.0

    mutating func sample(headroom: Double, triggerReady: Bool, at elapsed: Duration) -> Result {
        guard elapsed < .seconds(8) else { return .timedOut }
        guard triggerReady, headroom.isFinite, headroom > 1.05 else {
            stableSince = nil
            return .waiting
        }

        low = min(low, headroom)
        high = max(high, headroom)
        if stableSince == nil || high - low > 0.05 + 1e-9 {
            stableSince = elapsed
            low = headroom
            high = headroom
        }
        guard let stableSince, elapsed - stableSince >= .seconds(2) else { return .waiting }
        return .ready
    }
}

@MainActor
final class GammaBoostSession {
    private struct Attempt {
        let token = UUID()
        let displayID: CGDirectDisplayID
        let started = ContinuousClock.now
        var gate = HDRStabilityGate()
        var status: GammaBoostStatus = .starting
        var acquired = false
        var inFlight = false
        var appliedGain: Double?
        var lastCommand = ContinuousClock.now

        var isOngoing: Bool { status == .starting || status == .active }
    }

    private struct Cleanup {
        let token = UUID()
        var displayID: CGDirectDisplayID?
        var completions: [(GammaEndResult) -> Void] = []
    }

    var onStatusChanged: (() -> Void)?
    var restorationStatus: GammaBoostStatus? { recoveryError?.status }
    var isRestoring: Bool { cleanup != nil }

    var needsTrigger: Bool {
        guard let attempt else { return false }
        return attempt.acquired && attempt.isOngoing
    }

    private let transport: GammaHelperTransport
    private var attempt: Attempt?
    private var cleanup: Cleanup?
    private var restorationResults: [CGDirectDisplayID: GammaEndResult] = [:]
    private var recoveryError: (displayID: CGDirectDisplayID, status: GammaBoostStatus)?
    private var restartAfterRestoration = false

    init(helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LumaLumaGammaHelper")) {
        transport = GammaHelperTransport(helperURL: helperURL)
    }

    func update(
        displayID: CGDirectDisplayID,
        strength: Double,
        currentHeadroom: Double,
        triggerReady: Bool
    ) -> GammaBoostStatus {
        if attempt?.displayID != displayID {
            stop()
            attempt = Attempt(displayID: displayID)
            begin()
        }
        if restartAfterRestoration {
            guard !isRestoring, attempt?.inFlight != true else { return .starting }
            restartAfterRestoration = false
            if let recoveryError, recoveryError.displayID == displayID {
                attempt?.status = recoveryError.status
                return recoveryError.status
            }
            attempt = Attempt(displayID: displayID)
            begin()
        }
        guard var current = attempt else { return .failed }
        guard current.isOngoing else { return current.status }

        if current.status == .starting {
            let decision = current.gate.sample(
                headroom: currentHeadroom,
                triggerReady: triggerReady && current.acquired,
                at: current.started.duration(to: .now)
            )
            attempt = current
            if decision == .timedOut {
                finish(.unavailable, release: current.acquired || current.inFlight)
                return .unavailable
            }
            if !current.acquired, !current.inFlight,
               current.lastCommand.duration(to: .now) >= .milliseconds(250) {
                begin()
            }
            guard decision == .ready else { return .starting }
        } else if !triggerReady || !currentHeadroom.isFinite || currentHeadroom <= 1.05 {
            finish(.unavailable)
            restartAfterRestoration = true
            return .starting
        }

        if !current.inFlight {
            let level = strength.isFinite ? min(1, max(0, strength)) : 0
            let gain = min(1 + 0.45 * level, currentHeadroom)
            if current.appliedGain.map({ $0 > currentHeadroom || abs($0 - gain) > 0.001 }) ?? true {
                send("apply \(gain)", gain: gain)
            } else if current.lastCommand.duration(to: .now) >= .seconds(1) {
                send("check")
            }
        }
        return current.status
    }

    func stop(waitForRestoration: Bool = false) {
        restartAfterRestoration = false
        if let attempt, attempt.isOngoing, attempt.acquired || attempt.inFlight {
            release()
        }
        attempt = nil
        if waitForRestoration { transport.waitForQueuedWork() }
    }

    func appliedGain(on displayID: CGDirectDisplayID) -> Double? {
        guard attempt?.displayID == displayID, attempt?.status == .active else { return nil }
        return attempt?.appliedGain
    }

    func isRestoring(on displayID: CGDirectDisplayID) -> Bool {
        cleanup?.displayID == displayID
    }

    func restorationFailure(on displayID: CGDirectDisplayID) -> GammaBoostStatus? {
        restorationResults[displayID]?.failureStatus
    }

    func restore(on displayID: CGDirectDisplayID, completion: @escaping (GammaEndResult) -> Void) {
        if attempt?.displayID == displayID { stop() }
        if isRestoring(on: displayID) {
            cleanup?.completions.append(completion)
        } else {
            completion(restorationResults[displayID] ?? .notNeeded)
        }
    }

    func forgetDisplay(_ displayID: CGDirectDisplayID) {
        if attempt?.displayID == displayID { stop() }
        if isRestoring(on: displayID) { cleanup?.displayID = nil }
        restorationResults.removeValue(forKey: displayID)
        if recoveryError?.displayID == displayID { recoveryError = nil }
    }

    func reassociateDisplay(from oldID: CGDirectDisplayID, to newID: CGDirectDisplayID) {
        guard oldID != newID else { return }
        forgetDisplay(newID)
        if attempt?.displayID == oldID { stop() }
        if isRestoring(on: oldID) { cleanup?.displayID = newID }
        restorationResults[newID] = restorationResults.removeValue(forKey: oldID)
        if let error = recoveryError, error.displayID == oldID {
            recoveryError = (newID, error.status)
        }
    }

    private func begin() {
        guard let current = attempt, !isRestoring else { return }
        attempt?.inFlight = true
        attempt?.lastCommand = .now
        transport.begin(displayID: current.displayID) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, attempt?.token == current.token, attempt?.status == .starting else { return }
                attempt?.inFlight = false
                switch result {
                case .waiting:
                    // The display poll retries while the other helper holds the lock.
                    return
                case .acquired:
                    attempt?.acquired = true
                    restorationResults.removeValue(forKey: current.displayID)
                    if recoveryError?.displayID == current.displayID { recoveryError = nil }
                case .rejected(let status):
                    finish(status, release: false)
                }
                onStatusChanged?()
            }
        }
    }

    private func send(_ command: String, gain: Double? = nil) {
        guard let token = attempt?.token else { return }
        attempt?.inFlight = true
        attempt?.lastCommand = .now
        transport.send(command) { [weak self] reply in
            Task { @MainActor [weak self] in
                guard let self, attempt?.token == token else { return }
                let recovering = restartAfterRestoration
                guard attempt?.isOngoing == true || recovering else { return }
                attempt?.inFlight = false
                if reply != .ok {
                    finish(reply.boostStatus, release: !recovering)
                    onStatusChanged?()
                } else if recovering {
                    onStatusChanged?()
                } else if let gain {
                    attempt?.appliedGain = gain
                    attempt?.status = .active
                    onStatusChanged?()
                }
            }
        }
    }

    private func finish(_ status: GammaBoostStatus, release shouldRelease: Bool = true) {
        restartAfterRestoration = false
        attempt?.status = status
        if shouldRelease { release() }
    }

    private func release() {
        guard let displayID = attempt?.displayID, cleanup == nil else { return }
        let retirement = Cleanup(displayID: displayID)
        cleanup = retirement
        let token = retirement.token
        transport.end { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, let finished = cleanup, finished.token == token else { return }
                cleanup = nil
                var confirmed = result.confirmed
                if let id = finished.displayID {
                    if let failure = result.recovery.failureStatus {
                        recoveryError = (id, failure)
                    } else if result.recovery != .notNeeded, recoveryError?.displayID == id {
                        recoveryError = nil
                    }
                    if confirmed == .notNeeded, let prior = restorationResults[id] {
                        confirmed = prior
                    }
                    restorationResults[id] = confirmed
                }
                finished.completions.forEach { $0(confirmed) }
                onStatusChanged?()
            }
        }
    }
}

private enum GammaHelperReply: String {
    case ok
    case conflict
    case unsupported
    case error
    case busy

    var boostStatus: GammaBoostStatus {
        switch self {
        case .ok: .active
        case .conflict: .conflict
        case .unsupported: .unavailable
        case .error, .busy: .failed
        }
    }
}

private enum GammaBeginResult {
    case acquired
    case waiting
    case rejected(GammaBoostStatus)
}

enum GammaEndResult: Equatable {
    case notNeeded
    case restored
    case conflict
    case failed

    fileprivate var failureStatus: GammaBoostStatus? {
        switch self {
        case .restored, .notNeeded: nil
        case .conflict: .conflict
        case .failed: .restorationFailed
        }
    }
}

private struct GammaRetirementResult {
    let recovery: GammaEndResult
    let confirmed: GammaEndResult

    init(_ recovery: GammaEndResult, confirmed: GammaEndResult? = nil) {
        self.recovery = recovery
        self.confirmed = confirmed ?? recovery
    }
}

// All Process and pipe I/O stays on this queue. A closed input also requests
// rollback if Luma Luma exits before it can send an explicit end.
private final class GammaHelperTransport: @unchecked Sendable {
    private struct Retirement {
        let process: Process
        let reply: GammaHelperReply?
        var ownershipConflict = false
        var completions: [@Sendable (GammaRetirementResult) -> Void] = []
    }

    private let queue = DispatchQueue(label: "dev.illyes.lumaluma.gamma", qos: .userInitiated)
    private let helperURL: URL
    private var connection: Connection?
    private var retiring: Retirement?

    init(helperURL: URL) {
        self.helperURL = helperURL
    }

    func begin(displayID: CGDirectDisplayID, completion: @escaping @Sendable (GammaBeginResult) -> Void) {
        queue.async { [self] in
            guard self.connection == nil else {
                completion(.rejected(.failed))
                return
            }
            guard self.retiring == nil else {
                completion(.waiting)
                return
            }
            do {
                let connection = try Connection(helperURL: self.helperURL) { [weak self] process in
                    self?.queue.async { [weak self] in self?.finishRetirement(of: process) }
                }
                let reply = connection.request("begin \(displayID)", allowsBusy: true)
                if reply == .ok {
                    self.connection = connection
                    completion(.acquired)
                } else {
                    connection.close()
                    self.retiring = Retirement(process: connection.process, reply: nil)
                    self.finishRetirement(of: connection.process)
                    completion(reply == .busy ? .waiting : .rejected(reply.boostStatus))
                }
            } catch {
                completion(.rejected(.failed))
            }
        }
    }

    func send(_ command: String, completion: @escaping @Sendable (GammaHelperReply) -> Void) {
        queue.async { completion(self.connection?.request(command) ?? .error) }
    }

    func end(completion: @escaping @Sendable (GammaRetirementResult) -> Void) {
        queue.async {
            guard let connection = self.connection else {
                if self.retiring?.reply != nil {
                    self.retiring?.completions.append(completion)
                } else {
                    completion(GammaRetirementResult(.notNeeded))
                }
                return
            }
            self.connection = nil
            let reply = connection.request("end")
            connection.close()
            let process = connection.process
            self.retiring = Retirement(
                process: process, reply: reply, ownershipConflict: connection.ownershipConflict, completions: [completion]
            )
            self.finishRetirement(of: process)
        }
    }

    private func finishRetirement(of process: Process) {
        guard let retirement = retiring, retirement.process === process, !process.isRunning else { return }
        retiring = nil
        let result: GammaRetirementResult
        switch retirement.reply {
        case nil:
            result = GammaRetirementResult(.notNeeded)
        case .ok:
            result = GammaRetirementResult(.restored, confirmed: retirement.ownershipConflict ? .conflict : .restored)
        case .conflict:
            result = GammaRetirementResult(.conflict)
        default:
            // A clean exit after EOF can also mean that the helper lost ownership.
            // Keep existing HDR recovery behavior, but require proof for SDR writes.
            let recovery: GammaEndResult = process.terminationStatus == 0 ? .restored : .failed
            result = GammaRetirementResult(recovery, confirmed: retirement.ownershipConflict ? .conflict : .failed)
        }
        retirement.completions.forEach { $0(result) }
    }

    func waitForQueuedWork() {
        let done = DispatchSemaphore(value: 0)
        end { _ in done.signal() }
        _ = done.wait(timeout: .now() + .milliseconds(1250))
    }

    private final class Connection {
        let process = Process()
        private(set) var ownershipConflict = false
        private let input: FileHandle
        private let output: FileHandle
        private var usable = true

        init(helperURL: URL, onExit: @escaping @Sendable (Process) -> Void) throws {
            let commands = Pipe()
            let replies = Pipe()
            input = commands.fileHandleForWriting
            output = replies.fileHandleForReading
            let inputFD = input.fileDescriptor
            let outputFD = output.fileDescriptor
            guard fcntl(inputFD, F_SETFD, FD_CLOEXEC) != -1,
                  fcntl(outputFD, F_SETFD, FD_CLOEXEC) != -1,
                  fcntl(inputFD, F_SETNOSIGPIPE, 1) != -1
            else { throw POSIXError(.EIO) }

            process.executableURL = helperURL
            process.standardInput = commands
            process.standardOutput = replies
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = onExit
            try process.run()
            try? commands.fileHandleForReading.close()
            try? replies.fileHandleForWriting.close()
        }

        func request(_ command: String, allowsBusy: Bool = false) -> GammaHelperReply {
            guard usable, process.isRunning else { return .error }
            guard let reply = exchange(command), allowsBusy || reply != .busy else {
                // A later reply could belong to the timed-out command. Close this stream
                // instead of mistaking that reply for an acknowledgement of rollback.
                close()
                return .error
            }
            if reply == .conflict { ownershipConflict = true }
            return reply
        }

        private func exchange(_ command: String) -> GammaHelperReply? {
            do {
                try input.write(contentsOf: Data((command + "\n").utf8))
            } catch {
                return nil
            }

            var buffer = [UInt8](repeating: 0, count: 32)
            var response = [UInt8]()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(650))
            let fd = output.fileDescriptor
            while ContinuousClock.now < deadline {
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let millis = max(1, remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000)
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(millis))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { return nil }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return nil }
                response.append(contentsOf: buffer.prefix(count))
                if let newline = response.firstIndex(of: 10) {
                    guard newline == response.count - 1 else { return nil }
                    return GammaHelperReply(rawValue: String(decoding: response[..<newline], as: UTF8.self))
                }
                guard response.count < buffer.count else { return nil }
            }
            return nil
        }

        func close() {
            guard usable else { return }
            usable = false
            try? input.close()
            try? output.close()
        }

        deinit {
            close()
        }
    }
}
