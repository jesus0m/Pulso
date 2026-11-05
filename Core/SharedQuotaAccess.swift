import Darwin
import Foundation

enum SharedQuotaAccess {
    private static let localLock = NSRecursiveLock()
    private static var depth = 0

    private static func openLock(_ name: String) throws -> Int32 {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SnapshotCache.suite) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = directory.appendingPathComponent("\(name).lock")
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: url.path)
        } catch { close(fd); throw error }
        return fd
    }

    static func transaction<T>(_ operation: () throws -> T) throws -> T {
        localLock.lock()
        defer { localLock.unlock() }
        if depth > 0 { return try operation() }
        let fd = try openLock("quota-storage")
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        depth += 1
        defer { depth -= 1 }
        return try operation()
    }

    static func withOAuthLock<T>(wait: TimeInterval = 12, _ operation: () async throws -> T) async throws -> T {
        let fd = try openLock("codex-refresh")
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer { flock(fd, LOCK_UN) }
        try Task.checkCancellation()
        return try await operation()
    }
}
