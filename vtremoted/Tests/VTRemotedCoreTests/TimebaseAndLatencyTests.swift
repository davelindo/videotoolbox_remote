@testable import VTRemotedCore
import XCTest

final class TimebaseAndLatencyTests: XCTestCase {
    func testConcurrentStatsUpdatesAndSnapshots() {
        let stats = LockedClientStats()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            stats.update { $0.framesIn += 1; $0.recordSubmit() }
            _ = stats.snapshot()
            stats.update { $0.packetsOut += 1; $0.recordOutput() }
        }
        let result = stats.snapshot()
        XCTAssertEqual(result.framesIn, 1000)
        XCTAssertEqual(result.packetsOut, 1000)
        XCTAssertEqual(result.latency.sampleCount, 1000)
        XCTAssertTrue(result.latency.isEmpty)
    }

    func testWrappedLatencyQueueGrowsInFIFOOrder() {
        var tracker = LatencyTracker(initialCapacity: 2)
        tracker.submit(at: 100)
        tracker.submit(at: 200)
        tracker.output(at: 300)
        tracker.submit(at: 400)
        tracker.submit(at: 500)
        tracker.output(at: 600)
        tracker.output(at: 700)
        tracker.output(at: 800)
        XCTAssertEqual(tracker.sampleCount, 4)
        XCTAssertEqual(tracker.sumNanoseconds, 1200)
        XCTAssertEqual(tracker.maxNanoseconds, 400)
        XCTAssertTrue(tracker.isEmpty)
        for index in 0..<100 { tracker.submit(at: UInt64(index + 1000)) }
        for _ in 0..<50 { tracker.discardOne() }
        for index in 0..<50 { tracker.output(at: UInt64(index + 2050)) }
        XCTAssertEqual(tracker.sumNanoseconds, 51200)
        XCTAssertTrue(tracker.isEmpty)
    }

    func testTimebaseTicksRoundTrip() {
        let timebase = Timebase(num: 1, den: 30)
        let ticks = timebase.ticks(from: RationalTime(value: 1, timescale: 30))
        XCTAssertEqual(ticks, 1)
    }

    func testLatencyTrackerAverageAndMax() {
        var tracker = LatencyTracker()
        tracker.submit(at: 1000)
        tracker.output(at: 2000)
        XCTAssertEqual(tracker.averageMilliseconds, 0.001)
        XCTAssertEqual(tracker.maxMilliseconds, 0.001)
    }
}
