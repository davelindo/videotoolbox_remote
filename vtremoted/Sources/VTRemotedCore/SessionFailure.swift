import Foundation

/// The first failure wins, including when codec callbacks overlap with input.
final class SessionFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return error != nil
    }

    @discardableResult
    func record(_ error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.error == nil else { return false }
        self.error = error
        return true
    }

    func check() throws {
        lock.lock()
        let error = error
        lock.unlock()
        if let error { throw error }
    }
}
