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
    private var pending: [PendingFrame] = []
    private var seq: Int64 = 0
    private var lastEmittedPts: Int64 = Int64.min

    init(depth: Int) {
        self.depth = max(0, depth)
    }

    func reset() {
        pending.removeAll(keepingCapacity: true)
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
        if pending.isEmpty {
            pending.append(frame)
            return
        }
        var idx = pending.count
        while idx > 0 {
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
        while pending.count > targetCount {
            let frame = pending.removeFirst()
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
        return emitted
    }
}
