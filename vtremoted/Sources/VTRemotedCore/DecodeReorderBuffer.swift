import Foundation

struct ReorderedDecodedFrame<Payload> {
    let originalPtsTicks: Int64
    let ptsTicks: Int64
    let durTicks: Int64
    let payload: Payload
    let clamped: Bool
}

final class DecodeReorderBuffer<Payload> {
    private struct PendingFrame {
        let ptsTicks: Int64
        let durTicks: Int64
        let payload: Payload
        let seq: Int64
    }

    private let depth: Int
    private let compactionThreshold = 64
    private var pending: [PendingFrame] = []
    private var head: Int = 0
    private var seq: Int64 = 0
    private var lastEmittedPts: Int64 = Int64.min

    private var pendingCount: Int {
        pending.count - head
    }

    init(depth: Int) {
        self.depth = max(0, depth)
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
        head = 0
        seq = 0
        lastEmittedPts = Int64.min
    }

    func enqueue(ptsTicks: Int64, durTicks: Int64, payload: Payload) -> [ReorderedDecodedFrame<Payload>] {
        seq += 1
        let frame = PendingFrame(ptsTicks: ptsTicks, durTicks: durTicks, payload: payload, seq: seq)
        insertPending(frame)
        return drain(force: false)
    }

    func flush() -> [ReorderedDecodedFrame<Payload>] {
        return drain(force: true)
    }

    private func insertPending(_ frame: PendingFrame) {
        if pendingCount == 0 {
            if head > 0 {
                pending.removeAll(keepingCapacity: true)
                head = 0
            }
            pending.append(frame)
            return
        }
        var idx = pending.count
        while idx > head {
            let prev = pending[idx - 1]
            if prev.ptsTicks < frame.ptsTicks || (prev.ptsTicks == frame.ptsTicks && prev.seq <= frame.seq) {
                break
            }
            idx -= 1
        }
        pending.insert(frame, at: idx)
    }

    private func drain(force: Bool) -> [ReorderedDecodedFrame<Payload>] {
        let targetCount = force ? 0 : depth
        var emitted: [ReorderedDecodedFrame<Payload>] = []
        let drainCount = max(0, pendingCount - targetCount)
        emitted.reserveCapacity(drainCount)
        while pendingCount > targetCount {
            let frame = pending[head]
            head += 1
            var pts = frame.ptsTicks
            var clamped = false
            if lastEmittedPts != Int64.min && pts <= lastEmittedPts {
                pts = lastEmittedPts + 1
                clamped = true
            }
            if lastEmittedPts == Int64.min || pts > lastEmittedPts {
                lastEmittedPts = pts
            }
            emitted.append(ReorderedDecodedFrame(originalPtsTicks: frame.ptsTicks,
                                                 ptsTicks: pts,
                                                 durTicks: frame.durTicks,
                                                 payload: frame.payload,
                                                 clamped: clamped))
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
