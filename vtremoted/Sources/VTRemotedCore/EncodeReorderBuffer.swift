import Foundation

/// Small reordering buffer for encoder output callbacks.
///
/// VideoToolbox can invoke the compression output callback out-of-order. When frame
/// reordering (B-frames) is enabled, the correct emission order is decoding order (DTS).
/// This buffer sorts pending packets by DTS and emits once the pending queue exceeds
/// a configured depth.
final class EncodeReorderBuffer<Payload> {
    private struct Pending {
        let dtsTicks: Int64
        let seq: UInt64
        let payload: Payload
    }

    private let depth: Int
    private let compactionThreshold = 64
    private var pending: [Pending] = []
    private var head: Int = 0

    private var pendingCount: Int {
        pending.count - head
    }

    init(depth: Int) {
        self.depth = max(0, depth)
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        head = 0
    }

    func enqueue(dtsTicks: Int64, seq: UInt64, payload: Payload) -> [Payload] {
        insertPending(Pending(dtsTicks: dtsTicks, seq: seq, payload: payload))
        return drain(force: false)
    }

    func flush() -> [Payload] {
        return drain(force: true)
    }

    private func insertPending(_ pkt: Pending) {
        if pendingCount == 0 {
            if head > 0 {
                pending.removeAll(keepingCapacity: true)
                head = 0
            }
            pending.append(pkt)
            return
        }

        // Insertion sort by (dtsTicks, seq).
        var idx = pending.count
        while idx > head {
            let prev = pending[idx - 1]
            if prev.dtsTicks < pkt.dtsTicks || (prev.dtsTicks == pkt.dtsTicks && prev.seq <= pkt.seq) {
                break
            }
            idx -= 1
        }
        pending.insert(pkt, at: idx)
    }

    private func drain(force: Bool) -> [Payload] {
        let targetCount = force ? 0 : depth
        let drainCount = max(0, pendingCount - targetCount)
        var emitted: [Payload] = []
        emitted.reserveCapacity(drainCount)
        while pendingCount > targetCount {
            emitted.append(pending[head].payload)
            head += 1
        }
        compactIfNeeded()
        return emitted
    }

    private func compactIfNeeded() {
        guard head > 0 else { return }
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
            return
        }
        // Compact only after enough front consumption to keep dequeuing amortized O(1).
        if head >= compactionThreshold && head * 2 >= pending.count {
            pending = Array(pending[head...])
            head = 0
        }
    }
}
