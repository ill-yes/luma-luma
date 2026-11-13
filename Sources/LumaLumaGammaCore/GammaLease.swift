import Foundation

public enum GammaReply: String {
    case ok
    case busy
    case conflict
    case unsupported
    case error
}

struct GammaCurve: Equatable {
    static let tolerance: Float = 1.0 / 4096.0

    let red: [Float]
    let green: [Float]
    let blue: [Float]

    var count: Int { red.count }

    var isValidBaseline: Bool {
        guard (2...4096).contains(count), green.count == count, blue.count == count else { return false }
        return [red, green, blue].allSatisfy { samples in
            samples.last.map { $0 > 0 } == true
                && samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
                && zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 + Self.tolerance }
        }
    }

    func scaled(by gain: Float) -> Self {
        Self(red: red.map { $0 * gain }, green: green.map { $0 * gain }, blue: blue.map { $0 * gain })
    }

    func clamped() -> Self {
        Self(red: red.map { min($0, 1) }, green: green.map { min($0, 1) }, blue: blue.map { min($0, 1) })
    }

    func resampled(to sampleCount: Int) -> Self {
        guard sampleCount != count else { return self }
        func interpolate(_ channel: [Float]) -> [Float] {
            (0..<sampleCount).map { index in
                let position = Double(index) * Double(count - 1) / Double(sampleCount - 1)
                let lower = Int(position)
                let upper = min(lower + 1, count - 1)
                let fraction = Float(position - Double(lower))
                return channel[lower] + (channel[upper] - channel[lower]) * fraction
            }
        }
        return Self(red: interpolate(red), green: interpolate(green), blue: interpolate(blue))
    }

    func matches(_ other: Self) -> Bool {
        func matchesChannel(_ lhs: [Float], _ rhs: [Float]) -> Bool {
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= Self.tolerance }
        }
        return matchesChannel(red, other.red)
            && matchesChannel(green, other.green)
            && matchesChannel(blue, other.blue)
    }
}

protocol GammaBackend {
    func identity(of display: UInt32) -> UUID?
    func display(for identity: UUID) -> UInt32?
    func read(from display: UInt32, identity: UUID) -> GammaCurve?
    func write(_ curve: GammaCurve, to display: UInt32, identity: UUID) -> Bool
}

public struct GammaLease {
    private struct Attempt {
        let expected: GammaCurve
        let clamped: GammaCurve?
        let deadline: ContinuousClock.Instant?

        init(expected: GammaCurve, clamped: GammaCurve?, accepted: Bool) {
            self.expected = expected
            self.clamped = clamped
            deadline = accepted ? nil : ContinuousClock.now.advanced(by: .milliseconds(250))
        }

        func matches(_ curve: GammaCurve) -> Bool {
            curve.matches(expected) || clamped.map { curve.matches($0) } == true
        }

        var awaitsAcceptedWrite: Bool { deadline == nil }
    }

    private struct Ownership {
        let identity: UUID
        let baseline: GammaCurve
        var applied: GammaCurve
        var attempted: Attempt?

        mutating func verify(_ current: GammaCurve) -> GammaReply {
            let matchesPrevious = current.matches(applied)
            if let attempted, !matchesPrevious, attempted.matches(current) {
                applied = current
                self.attempted = nil
                return .ok
            }
            guard matchesPrevious else { return .conflict }
            if let attempted, attempted.deadline.map({ ContinuousClock.now < $0 }) ?? true { return .error }
            attempted = nil
            return .ok
        }
    }

    private let backend: any GammaBackend
    private var ownership: Ownership?

    public init() {
        self.init(backend: CoreGraphicsGammaBackend())
    }

    init(backend: any GammaBackend) {
        self.backend = backend
    }

    public mutating func run(readCommand: () -> String?, sendReply: (GammaReply) -> Bool) -> Bool {
        while let command = readCommand() {
            if !sendReply(handle(command)) { break }
        }
        return restoreAfterDisconnect(now: { ContinuousClock.now }, wait: Thread.sleep(forTimeInterval:))
    }

    mutating func restoreAfterDisconnect(
        now: () -> ContinuousClock.Instant,
        wait: (TimeInterval) -> Void
    ) -> Bool {
        let initialDeadline = now().advanced(by: .seconds(5))
        var onlineDeadline: ContinuousClock.Instant?
        while end() == .error {
            guard let lease = ownership else { return false }
            let currentTime = now()
            if backend.display(for: lease.identity) == nil || lease.attempted?.awaitsAcceptedWrite == true {
                // A display can remain offline, and a successful write can remain
                // queued. Keep the baseline and lock until ownership can be resolved.
                onlineDeadline = nil
                wait(currentTime < initialDeadline ? 0.25 : 2)
            } else {
                let deadline = onlineDeadline ?? currentTime.advanced(by: .seconds(5))
                guard currentTime < deadline else { return false }
                onlineDeadline = deadline
                wait(0.25)
            }
        }
        return true
    }

    public mutating func handle(_ line: String) -> GammaReply {
        guard line.utf8.count <= 128, line.utf8.allSatisfy({ (32...126).contains($0) }) else { return .error }
        let words = line.split(separator: " ")
        switch (words.first, words.count) {
        case ("begin", 2):
            guard let id = UInt32(words[1]), id != 0 else { return .error }
            return begin(display: id)
        case ("apply", 2):
            guard let gain = Double(words[1]), (1...1.45).contains(gain) else { return .error }
            return apply(gain: Float(gain))
        case ("check", 1):
            return check()
        case ("end", 1):
            return end()
        default:
            return .error
        }
    }

    mutating func begin(display: UInt32) -> GammaReply {
        guard ownership == nil else { return .error }
        guard let identity = backend.identity(of: display),
              let baseline = backend.read(from: display, identity: identity) else { return .unsupported }
        guard baseline.isValidBaseline else { return .conflict }
        ownership = Ownership(identity: identity, baseline: baseline, applied: baseline)
        return .ok
    }

    mutating func check() -> GammaReply {
        guard var lease = ownership,
              let display = backend.display(for: lease.identity),
              let current = backend.read(from: display, identity: lease.identity) else { return .error }
        return verify(current, lease: &lease)
    }

    mutating func apply(gain: Float) -> GammaReply {
        guard (1...1.45).contains(gain), var lease = ownership,
              let display = backend.display(for: lease.identity),
              let current = backend.read(from: display, identity: lease.identity) else { return .error }
        let verification = verify(current, lease: &lease)
        guard verification == .ok else { return verification }

        // This macOS path accepts extended values in a 256-entry upload. The display
        // expands the upload to its table capacity. Keep the full baseline for rollback.
        let sampleCount = min(256, lease.baseline.count)
        let requested = gain == 1 ? lease.baseline : lease.baseline.resampled(to: sampleCount).scaled(by: gain)
        return write(requested, to: display, lease: &lease)
    }

    public mutating func end() -> GammaReply {
        guard var lease = ownership else { return .ok }
        if lease.applied == lease.baseline, lease.attempted == nil {
            ownership = nil
            return .ok
        }
        guard let display = backend.display(for: lease.identity),
              let current = backend.read(from: display, identity: lease.identity) else { return .error }
        let verification = verify(current, lease: &lease)
        guard verification == .ok else { return verification }
        let reply = write(lease.baseline, to: display, lease: &lease)
        if reply == .ok || (reply == .error && lease.applied.matches(lease.baseline) && lease.attempted == nil) {
            ownership = nil
            return .ok
        }
        return reply
    }

    private mutating func verify(_ current: GammaCurve, lease: inout Ownership) -> GammaReply {
        let reply = lease.verify(current)
        ownership = reply == .conflict ? nil : lease
        return reply
    }

    private mutating func write(_ requested: GammaCurve, to display: UInt32, lease: inout Ownership) -> GammaReply {
        let expected = requested.resampled(to: lease.baseline.count)
        if expected.matches(lease.applied) { return .ok }
        let succeeded = backend.write(requested, to: display, identity: lease.identity)
        // Some implementations clamp a successful upload. Track that deterministic
        // candidate for rollback, but only an extended readback confirms the boost.
        let clamped = succeeded ? expected.clamped() : nil
        let readback = readback(display: display, lease: lease, waitForChange: succeeded)
        if let readback, readback.matches(expected) {
            lease.applied = readback
            ownership = lease
            return succeeded ? .ok : .error
        }
        if let readback, let clamped, readback.matches(clamped), !readback.matches(lease.applied) {
            lease.applied = readback
            ownership = lease
            return .error
        }
        if readback == nil || readback?.matches(lease.applied) == true {
            if succeeded || readback == nil {
                // A successful write can become observable after the short readback
                // loop. Keep ownership pending while Off or EOF checks for that result.
                lease.attempted = Attempt(expected: expected, clamped: clamped, accepted: succeeded)
                ownership = lease
            }
            return .error
        }
        ownership = nil
        return .conflict
    }

    private func readback(display: UInt32, lease: Ownership, waitForChange: Bool) -> GammaCurve? {
        var current = backend.read(from: display, identity: lease.identity)
        if waitForChange {
            for _ in 0..<3 where current == nil || current?.matches(lease.applied) == true {
                Thread.sleep(forTimeInterval: 0.02)
                current = backend.read(from: display, identity: lease.identity)
            }
        }
        return current
    }
}
