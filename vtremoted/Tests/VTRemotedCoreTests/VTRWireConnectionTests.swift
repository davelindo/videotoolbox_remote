@testable import VTRemotedCore
import Darwin
import Foundation
import XCTest

final class VTRWireConnectionTests: XCTestCase {
    private func withSockets(_ body: (Int32, Int32) throws -> Void) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        try body(descriptors[0], descriptors[1])
    }

    func testPartialHeaderAndBodyExpire() throws {
        let header = VTRMessageHeader(type: VTRMessageType.hello.rawValue, length: 10).encoded()
        for prefix in [Data(header.prefix(1)), header + Data([0])] {
            try withSockets { input, output in
                try POSIXIO.writev(fd: output, parts: [prefix], deadline: SocketDeadline(seconds: 1))
                let start = Date()
                XCTAssertThrowsError(try VTRWireConnection(fd: input).readMessage(timeoutSeconds: 1))
                XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
            }
        }
    }

    func testStreamingReadsShareHeaderDeadline() throws {
        try withSockets { input, output in
            let header = VTRMessageHeader(type: VTRMessageType.frame.rawValue, length: 100).encoded()
            try POSIXIO.writev(fd: output, parts: [header], deadline: SocketDeadline(seconds: 1))
            let connection = try VTRWireConnection(fd: input)
            _ = try connection.readHeader(timeoutSeconds: 1)
            Thread.sleep(forTimeInterval: 0.7)
            let start = Date()
            XCTAssertThrowsError(try connection.skip(length: 100))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        }
    }

    func testBlockedWriterExpiresAndPeerCloseDoesNotSignal() throws {
        try withSockets { input, output in
            var bufferBytes: Int32 = 4096
            XCTAssertEqual(setsockopt(output, SOL_SOCKET, SO_SNDBUF, &bufferBytes, 4), 0)
            let connection = try VTRWireConnection(fd: output, writeTimeoutSeconds: 0.1)
            let start = Date()
            XCTAssertThrowsError(try connection.send(type: .frame, body: Data(count: 1024 * 1024)))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
            _ = shutdown(input, SHUT_RDWR)
            XCTAssertThrowsError(try connection.send(type: .ping))
        }
    }

    func testLargeVectoredMessagePreservesEveryPart() throws {
        try withSockets { input, output in
            let writer = try VTRWireConnection(fd: output, writeTimeoutSeconds: 3)
            let reader = try VTRWireConnection(fd: input)
            let parts = [Data([1, 2, 3]), Data(repeating: 0x35, count: 17 * 1024 * 1024),
                         Data(repeating: 0x96, count: 9 * 1024 * 1024), Data([4, 5])]
            let finished = expectation(description: "large vectored send")
            DispatchQueue.global().async {
                do { try writer.sendMessage(type: .frame, bodyParts: parts) }
                catch { XCTFail("large send failed: \(error)") }
                finished.fulfill()
            }
            let received = try reader.readMessage(timeoutSeconds: 3)
            XCTAssertEqual(received.header.type, VTRMessageType.frame.rawValue)
            XCTAssertEqual(received.body, parts.reduce(into: Data()) { $0.append($1) })
            wait(for: [finished], timeout: 1)
        }
    }

    func testCancellationWakesBlockedReader() throws {
        try withSockets { input, _ in
            let connection = try VTRWireConnection(fd: input)
            let finished = expectation(description: "read cancelled")
            DispatchQueue.global().async {
                do {
                    _ = try connection.readMessage(timeoutSeconds: 60)
                    XCTFail("cancelled read succeeded")
                } catch { }
                finished.fulfill()
            }
            connection.cancelRead()
            wait(for: [finished], timeout: 1)
        }
    }

    func testConcurrentReadMessageReturnsWholeMessages() throws {
        var fds = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer {
            close(fds[0])
            close(fds[1])
        }

        let reader = try VTRWireConnection(fd: fds[0])
        let writer = try VTRWireConnection(fd: fds[1])
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
