@testable import VTRemotedCore
import XCTest

final class TimestampTrackerTests: XCTestCase {
    
    func testNormalSequenceMonotonicallyIncreasing() {
        let tracker = TimestampTracker()
        
        // Normal sequence: PTS 0, 1, 2, 3
        for i: Int64 in 0..<4 {
            let result = tracker.process(ptsTicks: i, dtsTicks: i)
            guard case .emit(let dts) = result else {
                XCTFail("Expected emit for PTS \(i)")
                return
            }
            XCTAssertEqual(dts, i, "DTS should equal PTS for normal sequence")
        }
    }
    
    func testDuplicatePTSSkipped() {
        let tracker = TimestampTracker()
        
        // First frame
        let result1 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .emit(let dts1) = result1 else {
            XCTFail("Expected emit for first frame")
            return
        }
        XCTAssertEqual(dts1, 100)
        
        // Duplicate PTS should be skipped
        let result2 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .skip = result2 else {
            XCTFail("Expected skip for duplicate PTS")
            return
        }
        
        // Third duplicate should also be skipped
        let result3 = tracker.process(ptsTicks: 100, dtsTicks: 100)
        guard case .skip = result3 else {
            XCTFail("Expected skip for duplicate PTS")
            return
        }
    }
    
    func testDTSClampedToPTS() {
        let tracker = TimestampTracker()
        
        // DTS > PTS should be clamped
        let result = tracker.process(ptsTicks: 100, dtsTicks: 200)
        guard case .emit(let dts) = result else {
            XCTFail("Expected emit")
            return
        }
        XCTAssertEqual(dts, 100, "DTS should be clamped to PTS")
    }
    
    func testDTSMonotonicityEnforced() {
        let tracker = TimestampTracker()
        
        // First frame with high PTS
        _ = tracker.process(ptsTicks: 100, dtsTicks: 100)
        
        // Second frame with same DTS (should be incremented)
        let result = tracker.process(ptsTicks: 101, dtsTicks: 100)
        guard case .emit(let dts) = result else {
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
        guard case .emit(let dts) = result else {
            XCTFail("Expected emit after reset")
            return
        }
        XCTAssertEqual(dts, 100)
    }
    
    func testMonotonicityWithPTSConstraint() {
        let tracker = TimestampTracker()
        
        // First frame: PTS=10, DTS=10
        _ = tracker.process(ptsTicks: 10, dtsTicks: 10)
        
        // Second frame with lower PTS (edge case)
        // DTS should be max(lastDTS+1, PTS) but clamped to PTS
        let result = tracker.process(ptsTicks: 5, dtsTicks: 5)
        guard case .emit(let dts) = result else {
            XCTFail("Expected emit")
            return
        }
        // Can't maintain monotonicity without exceeding PTS, so DTS = PTS
        XCTAssertEqual(dts, 5)
    }
}
