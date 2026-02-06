import Foundation

public final class BufferPool: @unchecked Sendable {
    private struct Item {
        var data: Data
        /// Best-effort capacity approximation (Swift `Data` doesn't expose capacity publicly).
        /// We record the last-used `count` before resetting to 0; actual capacity is >= this.
        var capacityHint: Int
    }

    private var buffers: [Item] = []
    private var pooledBytes: Int = 0
    private let lock = NSLock()

    private let maxItems: Int
    private let maxPooledBytes: Int

    public init(maxItems: Int = 32, maxPooledBytes: Int = 64 * 1024 * 1024) {
        self.maxItems = max(0, maxItems)
        self.maxPooledBytes = max(0, maxPooledBytes)
    }

    public func get(capacity: Int) -> Data {
        let want = max(0, capacity)
        lock.lock()
        defer { lock.unlock() }
        if !buffers.isEmpty {
            // Best-fit to reduce realloc churn and avoid handing out huge buffers for small reads.
            var bestIdx: Int?
            var bestCap = Int.max
            for i in buffers.indices {
                let cap = buffers[i].capacityHint
                if cap >= want, cap < bestCap {
                    bestIdx = i
                    bestCap = cap
                }
            }
            if let idx = bestIdx {
                let item = buffers.remove(at: idx)
                pooledBytes = max(0, pooledBytes - item.capacityHint)
                var buf = item.data
                buf.count = 0
                if want > 0 { buf.reserveCapacity(want) }
                return buf
            }

            // Fallback: pop last.
            let item = buffers.removeLast()
            pooledBytes = max(0, pooledBytes - item.capacityHint)
            var buf = item.data
            buf.count = 0
            if want > 0 { buf.reserveCapacity(want) }
            return buf
        }

        var buf = Data()
        if want > 0 { buf.reserveCapacity(want) }
        return buf
    }

    public func `return`(_ buffer: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard maxItems > 0, maxPooledBytes > 0 else { return }
        guard buffers.count < maxItems else { return }

        var buf = buffer
        let hint = max(0, buf.count)
        guard hint <= maxPooledBytes else { return }
        guard pooledBytes + hint <= maxPooledBytes else { return }

        // Keep capacity but drop logical size.
        buf.count = 0
        buffers.append(Item(data: buf, capacityHint: hint))
        pooledBytes += hint
    }
}
