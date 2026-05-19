@testable import VTRemotedCore
import Darwin
import Foundation
import XCTest

final class VTRWireConnectionTests: XCTestCase {
    func testConcurrentReadMessageReturnsWholeMessages() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let reader = VTRWireConnection(fd: fds[0])
        let writer = VTRWireConnection(fd: fds[1])
        let bodies = [
            Data("first-message".utf8),
            Data("second-message".utf8)
        ]

        try writer.send(type: .ping, body: bodies[0])
        try writer.send(type: .pong, body: bodies[1])

        let queue = DispatchQueue(label: "VTRWireConnectionTests.readers", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [(UInt16, Data)] = []
        var thrown: [Error] = []

        for _ in 0..<2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let message = try reader.readMessage(timeoutSeconds: 1)
                    lock.lock()
                    results.append((message.header.type, message.body))
                    lock.unlock()
                } catch {
                    lock.lock()
                    thrown.append(error)
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(thrown.isEmpty, "unexpected read errors: \(thrown)")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(
            Set(results.map { $0.0 }),
            Set([VTRMessageType.ping.rawValue, VTRMessageType.pong.rawValue])
        )
        XCTAssertEqual(Set(results.map { $0.1 }), Set(bodies))
    }
}
