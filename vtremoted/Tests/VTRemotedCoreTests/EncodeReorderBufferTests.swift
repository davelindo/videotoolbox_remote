@testable import VTRemotedCore
import XCTest

final class EncodeReorderBufferTests: XCTestCase {
    func testEmittedPayloadIsReleasedBeforeSlotCompaction() {
        final class Payload { }
        final class Witness { weak var value: Payload? }
        let buffer = EncodeReorderBuffer<Payload>(depth: 2)
        var first: Payload? = Payload()
        let retained = Witness()
        retained.value = first
        _ = buffer.enqueue(dtsTicks: 0, seq: 0, payload: first!)
        first = nil
        XCTAssertNotNil(retained.value)

        _ = buffer.enqueue(dtsTicks: 1, seq: 1, payload: Payload())
        var output = buffer.enqueue(dtsTicks: 2, seq: 2, payload: Payload())
        XCTAssertEqual(output.count, 1)
        XCTAssertNotNil(retained.value)
        output.removeAll()
        XCTAssertNil(retained.value)
    }

    func testOrdersPacketsByDTSThenSequence() {
        let buffer = EncodeReorderBuffer<String>(depth: 3)
        var output: [String] = []
        output += buffer.enqueue(dtsTicks: 20, seq: 2, payload: "later")
        output += buffer.enqueue(dtsTicks: 10, seq: 4, payload: "tie-later")
        output += buffer.enqueue(dtsTicks: 10, seq: 1, payload: "tie-first")
        XCTAssertTrue(output.isEmpty)
        output += buffer.enqueue(dtsTicks: 30, seq: 3, payload: "last")
        XCTAssertEqual(output, ["tie-first"])
        output += buffer.flush()
        XCTAssertEqual(output, ["tie-first", "tie-later", "later", "last"])
        XCTAssertTrue(buffer.flush().isEmpty)
    }

    func testOrderingSurvivesRepeatedCompaction() {
        let buffer = EncodeReorderBuffer<Int>(depth: 3)
        var output: [Int] = []
        for batch in stride(from: 0, to: 200, by: 4) {
            for value in [batch + 2, batch, batch + 3, batch + 1] {
                output += buffer.enqueue(dtsTicks: Int64(value), seq: UInt64(value), payload: value)
            }
        }
        XCTAssertEqual(output, Array(0..<197))
        output += buffer.flush()
        XCTAssertEqual(output, Array(0..<200))
        XCTAssertEqual(buffer.enqueue(dtsTicks: 200, seq: 200, payload: 200), [])
        XCTAssertEqual(buffer.flush(), [200])
    }
}
