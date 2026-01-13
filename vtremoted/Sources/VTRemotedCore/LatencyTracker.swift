import Foundation

public struct LatencyTracker: Sendable {
    private var times: [UInt64]
    private var head = 0
    private var count = 0

    public private(set) var sumNanoseconds: UInt64 = 0
    public private(set) var maxNanoseconds: UInt64 = 0
    public private(set) var sampleCount: UInt64 = 0

    public init(initialCapacity: Int = 64) {
        self.times = Array(repeating: 0, count: max(1, initialCapacity))
    }

    public mutating func submit(at nowNanoseconds: UInt64) {
        if count == times.count {
            times.append(contentsOf: Array(repeating: 0, count: times.count))
        }
        let index = (head + count) % times.count
        times[index] = nowNanoseconds
        count += 1
    }

    public mutating func output(at nowNanoseconds: UInt64) {
        guard count > 0 else { return }
        let start = times[head]
        head = (head + 1) % times.count
        count -= 1

        let delta = nowNanoseconds &- start
        sumNanoseconds &+= delta
        sampleCount &+= 1
        if delta > maxNanoseconds { maxNanoseconds = delta }
    }

    public mutating func discardOne() {
        guard count > 0 else { return }
        head = (head + 1) % times.count
        count -= 1
    }

    public var averageMilliseconds: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(sumNanoseconds) / Double(sampleCount) / 1_000_000.0
    }

    public var maxMilliseconds: Double {
        Double(maxNanoseconds) / 1_000_000.0
    }
}
