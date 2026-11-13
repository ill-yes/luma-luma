import LumaLumaGammaCore
import Darwin
import Foundation

@main
struct LumaLumaGammaHelper {
    private enum LockResult {
        case acquired(Int32)
        case busy
        case failed
    }

    static func main() {
        guard CommandLine.arguments.count == 1 else { exit(EXIT_FAILURE) }
        signal(SIGPIPE, SIG_IGN)
        let lock: Int32
        switch lockDirectory() {
        case .acquired(let descriptor):
            lock = descriptor
        case .busy:
            if let command = readCommand() {
                let fields = command.split(separator: " ")
                let isBegin = fields.count == 2 && fields[0] == "begin"
                    && UInt32(fields[1]).map { $0 != 0 } == true
                _ = send(isBegin ? .busy : .error)
            }
            return
        case .failed:
            if readCommand() != nil { _ = send(.error) }
            exit(EXIT_FAILURE)
        }
        defer { close(lock) }

        var lease = GammaLease()
        let restored = lease.run(readCommand: readCommand, sendReply: send)
        if !restored { exit(EXIT_FAILURE) }
    }

    private static func lockDirectory() -> LockResult {
        // All instances in this login share one writer. The directory inode stays stable
        // across launches, avoiding a race between unlinking a lock and acquiring it.
        let path = NSTemporaryDirectory().appending("dev.illyes.lumaluma.gamma")
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { return .failed }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .failed }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == geteuid(),
              attributes.st_mode & 0o077 == 0 else {
            close(descriptor)
            return .failed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK || code == EAGAIN ? .busy : .failed
        }
        return .acquired(descriptor)
    }

    private static func send(_ reply: GammaReply) -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((reply.rawValue + "\n").utf8))
            return true
        } catch {
            return false
        }
    }

    private static func readCommand() -> String? {
        var bytes: [UInt8] = []
        var invalid = false
        while true {
            let byte = getchar()
            if byte == EOF { return nil }
            if byte == 10 {
                return invalid ? "" : String(decoding: bytes, as: UTF8.self)
            }
            if (32...126).contains(byte), bytes.count < 128 {
                bytes.append(UInt8(byte))
            } else {
                invalid = true
            }
        }
    }
}
