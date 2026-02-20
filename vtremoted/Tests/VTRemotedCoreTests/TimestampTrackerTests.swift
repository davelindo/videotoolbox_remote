@testable import VTRemotedCore
import XCTest

final class TimestampTrackerTests: XCTestCase {
    
    func testNormalSequenceMonotonicallyIncreasing() {
        let tracker = TimestampTracker()
        
        // Normal sequence: PTS 0, 1, 2, 3
        for tick: Int64 in 0..<4 {
            let result = tracker.process(ptsTicks: tick, dtsTicks: tick)
            guard case .emit(let pts, let dts, let adjusted) = result else {
                XCTFail("Expected emit for PTS \(tick)")
                return
            }
            XCTAssertEqual(pts, tick)
            XCTAssertFalse(adjusted)
            XCTAssertEqual(dts, tick, "DTS should equal PTS for normal sequence")
        }
    }
    
    func testDuplicatePTSAdjusted() {
        let tracker = TimestampTracker()
        
        // First frame
        let result1 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .emit(let pts1, let dts1, let adjusted1) = result1 else {
            XCTFail("Expected emit for first frame")
            return
        }
        XCTAssertEqual(pts1, 100)
        XCTAssertFalse(adjusted1)
        XCTAssertEqual(dts1, 100)
        
        // Duplicate PTS should be adjusted upward to keep monotonicity
        let result2 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .emit(let pts2, let dts2, let adjusted2) = result2 else {
            XCTFail("Expected emit for duplicate PTS")
            return
        }
        XCTAssertEqual(pts2, 101)
        XCTAssertTrue(adjusted2)
        XCTAssertEqual(dts2, 101)
        
        // Third duplicate should also be adjusted
        let result3 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .emit(let pts3, let dts3, let adjusted3) = result3 else {
            XCTFail("Expected emit for duplicate PTS")
            return
        }
        XCTAssertEqual(pts3, 102)
        XCTAssertTrue(adjusted3)
        XCTAssertEqual(dts3, 102)
    }
    
    func testDTSCanLeadPTSWithoutForcedPTSAdjustment() {
        let tracker = TimestampTracker()
        
        // DTS > PTS should not force PTS adjustment on first frame.
        // We preserve PTS semantics unless monotonic-by-history requires a bump.
        let result = tracker.process(ptsTicks: 100, dtsTicks: 200)
        guard case .emit(let pts, let dts, let adjusted) = result else {
            XCTFail("Expected emit")
            return
        }
        XCTAssertEqual(dts, 200)
        XCTAssertEqual(pts, 100)
        XCTAssertFalse(adjusted)
    }
    
    func testDTSMonotonicityEnforced() {
        let tracker = TimestampTracker()
        
        // First frame with high PTS
        _ = tracker.process(ptsTicks: 100, dtsTicks: 100)
        
        // Second frame with same DTS (should be incremented)
        let result = tracker.process(ptsTicks: 101, dtsTicks: 100)
        guard case .emit(_, let dts, _) = result else {
            XCTFail("Expected emit")
            return
        }
        XCTAssertEqual(dts, 101, "DTS should be incremented to maintain monotonicity")
    }
    
    func testResetClearsState() {
        let tracker = TimestampTracker()
        
        // Set some state
        _ = tracker.process(ptsTicks: 100, dtsTicks: 100)
        
        // Reset
        tracker.reset()
        
        // After reset, same PTS should not be skipped
        let result = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .emit(let pts, let dts, let adjusted) = result else {
            XCTFail("Expected emit after reset")
            return
        }
        XCTAssertEqual(pts, 100)
        XCTAssertFalse(adjusted)
        XCTAssertEqual(dts, 100)
    }
    
    func testMonotonicityWithPTSConstraint() {
        let tracker = TimestampTracker()
        
        // First frame: PTS=10, DTS=10
        _ = tracker.process(ptsTicks: 10, dtsTicks: 10)
        
        // Second frame with lower PTS (edge case)
        // DTS should advance; PTS should be adjusted upward.
        let result = tracker.process(ptsTicks: 5, dtsTicks: 5)
        guard case .emit(let pts, let dts, let adjusted) = result else {
            XCTFail("Expected emit")
            return
        }
        XCTAssertEqual(pts, 11, "PTS should be adjusted to maintain monotonicity")
        XCTAssertEqual(dts, 11)
        XCTAssertTrue(adjusted)
    }

    func testAllowsPTSRegressionWhenDisabled() {
        let tracker = TimestampTracker()
        tracker.reset(enforceMonotonicPts: false)

        _ = tracker.process(ptsTicks: 10, dtsTicks: 10)
        let result = tracker.process(ptsTicks: 5, dtsTicks: 5)
        guard case .emit(let pts, let dts, let adjusted) = result else {
            XCTFail("Expected emit")
            return
        }
        XCTAssertEqual(pts, 5)
        XCTAssertFalse(adjusted)
        XCTAssertEqual(dts, 11)
    }
}
