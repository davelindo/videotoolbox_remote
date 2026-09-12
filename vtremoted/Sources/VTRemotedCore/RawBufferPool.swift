import Foundation

/// Recycles system-memory storage only after the last wire Data reference dies.
/// In-use buffers belong to their Data values; only idle storage counts toward
/// the retained-memory limit. The existing decode reorder/in-flight limits
/// bound the number of live frames.
final class RawBufferPool: @unchecked Sendable {
    private struct Storage: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let capacity: Int
    }
    private var idle: [Storage] = []
    private var retainedBytes = 0
    private var allocations = 0
    private let limit: Int
    private let lock = NSLock()

    init(retainedByteLimit: Int = 64 * 1024 * 1024) {
        limit = max(0, retainedByteLimit)
    }

    deinit {
        for storage in idle {
            storage.pointer.deallocate()
        }
    }

    private func take(_ capacity: Int) -> Storage {
        lock.lock()
        var best: Int?
        for index in idle.indices where idle[index].capacity >= capacity {
            if best == nil || idle[index].capacity < idle[best!].capacity {
                best = index
            }
        }
        if let index = best {
            let storage = idle.remove(at: index)
            retainedBytes -= storage.capacity
            lock.unlock()
            return storage
        }
        allocations += 1
        lock.unlock()
        return Storage(pointer: .allocate(byteCount: capacity, alignment: 64), capacity: capacity)
    }

    private func recycle(_ storage: Storage) {
        lock.lock()
        if storage.capacity <= limit - retainedBytes {
            idle.append(storage)
            retainedBytes += storage.capacity
            lock.unlock()
        } else {
            lock.unlock()
            storage.pointer.deallocate()
        }
    }

    func withBuffer<T>(capacity: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        precondition(capacity >= 0)
        let storage = take(max(1, capacity))
        defer { recycle(storage) }
        return try body(UnsafeMutableRawBufferPointer(start: storage.pointer, count: capacity))
    }

    func data(capacity: Int, fill: (UnsafeMutableRawBufferPointer) -> Int?) -> Data? {
        guard capacity > 0 else { return Data() }
        let storage = take(capacity)
        guard let count = fill(UnsafeMutableRawBufferPointer(start: storage.pointer, count: capacity)),
              count >= 0, count <= capacity else {
            recycle(storage)
            return nil
        }
        if count == 0 {
            recycle(storage)
            return Data()
        }
        return Data(bytesNoCopy: storage.pointer, count: count, deallocator: .custom { [self] _, _ in
            recycle(storage)
        })
    }

    var snapshot: (allocations: Int, retainedBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (allocations, retainedBytes)
    }
}
