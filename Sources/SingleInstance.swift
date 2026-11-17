import Foundation
import Darwin

/// Keep the lock file in place: unlinking it would allow two processes to lock different inodes.
final class SingleInstance {
    let isPrimary: Bool
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("instance.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            isPrimary = true
        } else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            descriptor = -1
            isPrimary = false
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}
