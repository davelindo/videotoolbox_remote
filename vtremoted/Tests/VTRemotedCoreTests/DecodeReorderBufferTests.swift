@testable import VTRemotedCore
import XCTest

final class DecodeReorderBufferTests: XCTestCase {
    func testReordersWithinDepth() {
        let buffer = DecodeReorderBuffer<Int>(depth: 2)
        var emitted: [Int64] = []

        emitted += buffer.enqueue(ptsTicks: 2, durTicks: 1, payload: 2).map { $0.ptsTicks }
        emitted += buffer.enqueue(ptsTicks: 1, durTicks: 1, payload: 1).map { $0.ptsTicks }
        emitted += buffer.enqueue(ptsTicks: 3, durTicks: 1, payload: 3).map { $0.ptsTicks }
        emitted += buffer.flush().map { $0.ptsTicks }

        XCTAssertEqual(emitted, [1, 2, 3])
    }

    func testFlushEmitsAllInOrder() {
        let buffer = DecodeReorderBuffer<Int>(depth: 4)
        var emitted: [Int64] = []

        emitted += buffer.enqueue(ptsTicks: 2, durTicks: 1, payload: 2).map { $0.ptsTicks }
        emitted += buffer.enqueue(ptsTicks: 1, durTicks: 1, payload: 1).map { $0.ptsTicks }
        emitted += buffer.flush().map { $0.ptsTicks }

        XCTAssertEqual(emitted, [1, 2])
    }

    func testClampsLateFrames() {
        let buffer = DecodeReorderBuffer<Int>(depth: 1)
        var emitted: [ReorderedDecodedFrame<Int>] = []

        emitted += buffer.enqueue(ptsTicks: 10, durTicks: 1, payload: 10)
        emitted += buffer.enqueue(ptsTicks: 20, durTicks: 1, payload: 20)
        emitted += buffer.enqueue(ptsTicks: 5, durTicks: 1, payload: 5)
        emitted += buffer.flush()

        XCTAssertEqual(emitted.map { $0.ptsTicks }, [10, 11, 20])
        XCTAssertTrue(emitted[1].clamped)
        XCTAssertEqual(emitted[1].originalPtsTicks, 5)
    }
}
