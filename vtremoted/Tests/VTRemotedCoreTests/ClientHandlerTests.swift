import XCTest
@testable import VTRemotedCore

final class ClientHandlerTests: XCTestCase {
    private final class FakeIO: VTRMessageIO, @unchecked Sendable {
        var incoming: [(VTRMessageType, Data)]
        var sent: [(VTRMessageType, Data)] = []

        init(incoming: [(VTRMessageType, Data)]) {
            self.incoming = incoming
        }

        func readMessage(timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data) {
            XCTAssertGreaterThan(timeoutSeconds, 0)
            guard !incoming.isEmpty else {
                throw VTRemotedError.protocolViolation("no more messages")
            }
            let (type, body) = incoming.removeFirst()
            return (VTRMessageHeader(type: type.rawValue, length: UInt32(body.count)), body)
        }

        func send(type: VTRMessageType, body: Data) throws {
            sent.append((type, body))
        }
    }

    func testHappyPathEncodeHandshakeAndFlush() {
        let helloPayload = makeHello(token: "", codec: "h264")
        let configurePayload = makeConfigure(mode: "encode", wireCompression: "0")
        let io = FakeIO(incoming: [
            (.hello, helloPayload),
            (.configure, configurePayload),
            (.flush, Data()),
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(io: io, expectedToken: "")
        handler.run()

        XCTAssertEqual(io.sent.count, 3)
        XCTAssertEqual(io.sent[0].0, .helloAck)
        XCTAssertEqual(io.sent[1].0, .configureAck)
        XCTAssertEqual(io.sent[2].0, .done)
        XCTAssertEqual(io.sent[0].1.first, 0)
    }

    func testAuthFailStopsAfterHelloAck() {
        let helloPayload = makeHello(token: "bad", codec: "h264")
        let io = FakeIO(incoming: [
            (.hello, helloPayload),
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(io: io, expectedToken: "good")
        handler.run()

        XCTAssertEqual(io.sent.count, 1)
        XCTAssertEqual(io.sent[0].0, .helloAck)
        XCTAssertEqual(io.sent[0].1.first, 2)
    }
}

private func makeHello(token: String, codec: String) -> Data {
    var w = ByteWriter()
    w.writeLengthPrefixedUTF8(token)
    w.writeLengthPrefixedUTF8(codec)
    w.writeLengthPrefixedUTF8("client")
    w.writeLengthPrefixedUTF8("build")
    return w.data
}

private func makeConfigure(mode: String, wireCompression: String) -> Data {
    var w = ByteWriter()
    w.writeBE(UInt32(64))
    w.writeBE(UInt32(64))
    w.write(UInt8(1))
    w.writeBE(UInt32(1))
    w.writeBE(UInt32(30))
    w.writeBE(UInt32(30))
    w.writeBE(UInt32(1))

    w.writeBE(UInt16(2))
    w.writeLengthPrefixedUTF8("mode")
    w.writeLengthPrefixedUTF8(mode)
    w.writeLengthPrefixedUTF8("wire_compression")
    w.writeLengthPrefixedUTF8(wireCompression)

    w.writeBE(UInt32(0))
    return w.data
}
