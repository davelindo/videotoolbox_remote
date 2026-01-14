@testable import VTRemotedCore
import XCTest

final class TimebaseAndLatencyTests: XCTestCase {
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
