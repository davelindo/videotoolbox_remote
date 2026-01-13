import XCTest
@testable import VTRemotedCore

final class TimebaseAndLatencyTests: XCTestCase {
    func testTimebaseTicksRoundTrip() {
        let tb = Timebase(num: 1, den: 30)
        let ticks: Int64 = 123
        let time = tb.time(fromTicks: ticks)
        XCTAssertEqual(time.timescale, 30)
        XCTAssertEqual(tb.ticks(from: time), ticks)
    }

    func testLatencyTrackerAverageAndMax() {
        var t = LatencyTracker(initialCapacity: 2)
        t.submit(at: 100)
        t.submit(at: 200)
        t.output(at: 110)
        t.output(at: 260)
        XCTAssertEqual(t.sampleCount, 2)
        XCTAssertEqual(t.maxNanoseconds, 60)
        XCTAssertGreaterThan(t.averageMilliseconds, 0)
    }
}
