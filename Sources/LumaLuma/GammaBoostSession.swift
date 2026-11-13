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
    }

    var onStatusChanged: (() -> Void)?
    private(set) var restorationStatus: GammaBoostStatus?
    var isRestoring: Bool { cleanupToken != nil }

    var needsTrigger: Bool {
        guard let attempt, attempt.acquired else { return false }
        return attempt.status == .starting || attempt.status == .active
    }

    private let transport = GammaHelperTransport()
    private var attempt: Attempt?
    private var cleanupToken: UUID?

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
        guard var current = attempt else { return .failed }
        guard current.status == .starting || current.status == .active else { return current.status }

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
            return .unavailable
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
        if let attempt, attempt.status == .starting || attempt.status == .active,
           attempt.acquired || attempt.inFlight {
            release()
        }
        attempt = nil
        if waitForRestoration { transport.waitForQueuedWork() }
    }

    private func begin() {
        guard let current = attempt else { return }
        attempt?.inFlight = true
        attempt?.lastCommand = .now
        transport.begin(displayID: current.displayID) { [weak self] reply in
            Task { @MainActor [weak self] in
                guard let self, attempt?.token == current.token, attempt?.status == .starting else { return }
                attempt?.inFlight = false
                // The existing display poll can try again after the previous
                // helper releases its lock. Busy does not change UI state.
                guard reply != .busy else { return }
                if reply == .ok {
                    attempt?.acquired = true
                    restorationStatus = nil
                } else {
                    finish(reply.boostStatus)
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
                guard let self, attempt?.token == token,
                      attempt?.status == .starting || attempt?.status == .active
                else { return }
                attempt?.inFlight = false
                if reply != .ok {
                    finish(reply.boostStatus)
                    onStatusChanged?()
                } else if let gain {
                    let wasActive = attempt?.status == .active
                    attempt?.appliedGain = gain
                    attempt?.status = .active
                    if !wasActive { onStatusChanged?() }
                }
            }
        }
    }

    private func finish(_ status: GammaBoostStatus, release shouldRelease: Bool = true) {
        attempt?.status = status
        if shouldRelease { release() }
    }

    private func release() {
        let token = UUID()
        cleanupToken = token
        transport.end { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, cleanupToken == token else { return }
                cleanupToken = nil
                let status: GammaBoostStatus?
                switch result {
                case .ok: status = nil
                case .conflict: status = .conflict
                default: status = .restorationFailed
                }
                restorationStatus = status
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

// All Process and pipe I/O stays on this queue. A closed input also requests
// rollback if Luma Luma exits before it can send an explicit end.
private final class GammaHelperTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.illyes.lumaluma.gamma", qos: .userInitiated)
    private var connection: Connection?
    private var retiring: Process?

    func begin(displayID: CGDirectDisplayID, completion: @escaping @Sendable (GammaHelperReply) -> Void) {
        queue.async {
            guard self.connection == nil else {
                completion(.error)
                return
            }
            guard self.retiring?.isRunning != true else {
                completion(.busy)
                return
            }
            self.retiring = nil
            do {
                let connection = try Connection()
                self.connection = connection
                completion(connection.request("begin \(displayID)"))
            } catch {
                completion(.error)
            }
        }
    }

    func send(_ command: String, completion: @escaping @Sendable (GammaHelperReply) -> Void) {
        queue.async { completion(self.connection?.request(command) ?? .error) }
    }

    func end(completion: @escaping @Sendable (GammaHelperReply) -> Void) {
        queue.async {
            guard let connection = self.connection else {
                if let process = self.retiring, process.isRunning || process.terminationStatus != 0 {
                    completion(.error)
                } else {
                    completion(.ok)
                }
                return
            }
            self.connection = nil
            let reply = connection.request("end")
            connection.close()
            let process = connection.process
            self.retiring = process
            let exitWait: Duration = reply == .ok || reply == .conflict ? .milliseconds(250) : .milliseconds(5500)
            self.waitForExit(process, upTo: exitWait)
            if reply == .ok || reply == .conflict {
                completion(reply)
            } else {
                completion(!process.isRunning && process.terminationStatus == 0 ? .ok : .error)
            }
        }
    }

    private func waitForExit(_ process: Process, upTo duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func waitForQueuedWork() {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + .milliseconds(1250))
    }

    private final class Connection {
        let process = Process()
        private let input: FileHandle
        private let output: FileHandle
        private var usable = true

        init() throws {
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

            process.executableURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/LumaLumaGammaHelper")
            process.standardInput = commands
            process.standardOutput = replies
            process.standardError = FileHandle.nullDevice
            try process.run()
            try? commands.fileHandleForReading.close()
            try? replies.fileHandleForWriting.close()
        }

        func request(_ command: String) -> GammaHelperReply {
            guard usable, process.isRunning else { return .error }
            guard let reply = exchange(command) else {
                // A later reply could belong to the timed-out command. Close this stream
                // instead of mistaking that reply for an acknowledgement of rollback.
                close()
                return .error
            }
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
                    guard newline == response.count - 1,
                          let reply = GammaHelperReply(rawValue: String(decoding: response[..<newline], as: UTF8.self)),
                          reply != .busy
                    else { return nil }
                    return reply
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
