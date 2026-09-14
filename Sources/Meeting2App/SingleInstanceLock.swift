import Darwin
import Foundation

/// One kernel-held lock per user, shared by every build and checkout. A running-process lookup
/// alone races simultaneous launches; a PID/existence marker can survive a crash. Keep this
/// descriptor open for the app's lifetime so the kernel releases ownership even on forced exit.
final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { Darwin.close(descriptor) }

    /// Nil means another instance owns the lock. Filesystem/locking errors throw: proceeding
    /// without exclusion would allow two recorders and recovery pipelines to operate together.
    static func acquire(at lockURL: URL? = nil) throws -> SingleInstanceLock? {
        let url = try lockURL ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Meeting2/instance.lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Do not truncate or unlink this file: replacing its inode while another process holds
        // it would create two independent locks. Child executables must not inherit ownership.
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
        return SingleInstanceLock(descriptor: descriptor)
    }
}
