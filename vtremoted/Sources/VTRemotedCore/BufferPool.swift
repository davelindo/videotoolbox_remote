import Foundation

public final class BufferPool: @unchecked Sendable {
    private var buffers: [Data] = []
    private let lock = NSLock()

    public init() {}

    public func get(capacity: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if var buf = buffers.popLast() {
            buf.count = 0
            // reserveCapacity might trigger realloc if capacity > existing capacity
            // but Data implementation usually handles this.
            return buf
        }
        return Data(capacity: capacity)
    }

    public func `return`(_ buffer: Data) {
        lock.lock()
        defer { lock.unlock() }
        if buffers.count < 20 { // Simple cap to prevent infinite growth
             buffers.append(buffer)
        }
    }
}
