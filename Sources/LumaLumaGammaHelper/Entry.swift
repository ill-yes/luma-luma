import LumaLumaGammaCore
import Darwin
import Foundation

@main
struct LumaLumaGammaHelper {
    static func main() {
        guard CommandLine.arguments.count == 1 else { exit(EXIT_FAILURE) }
        signal(SIGPIPE, SIG_IGN)
        guard let lock = lockDirectory() else {
            if readCommand() != nil { _ = send(.error) }
            exit(EXIT_FAILURE)
        }
        defer { close(lock) }

        var lease = GammaLease()
        let restored = lease.run(readCommand: readCommand, sendReply: send)
        if !restored { exit(EXIT_FAILURE) }
    }

    private static func lockDirectory() -> Int32? {
        // All instances in this login share one writer. The directory inode stays stable
        // across launches, avoiding a race between unlinking a lock and acquiring it.
        let path = NSTemporaryDirectory().appending("dev.illyes.lumaluma.gamma")
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else { return nil }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == geteuid(),
              attributes.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
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
