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
    private var pending: [Pending] = []

    init(depth: Int) {
        self.depth = max(0, depth)
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    func enqueue(dtsTicks: Int64, seq: UInt64, payload: Payload) -> [Payload] {
        insertPending(Pending(dtsTicks: dtsTicks, seq: seq, payload: payload))
        return drain(force: false)
    }

    func flush() -> [Payload] {
        return drain(force: true)
    }

    private func insertPending(_ pkt: Pending) {
        if pending.isEmpty {
            pending.append(pkt)
            return
        }

        // Insertion sort by (dtsTicks, seq).
        var idx = pending.count
        while idx > 0 {
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
        var emitted: [Payload] = []
        while pending.count > targetCount {
            emitted.append(pending.removeFirst().payload)
        }
        return emitted
    }
}
