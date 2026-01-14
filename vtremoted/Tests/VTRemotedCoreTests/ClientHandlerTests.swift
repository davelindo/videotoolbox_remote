@testable import VTRemotedCore
import XCTest

final class ClientHandlerTests: XCTestCase {
    private final class FakeIO: VTRMessageIO, @unchecked Sendable {
        var incoming: [(VTRMessageType, Data)]
        var sent: [(VTRMessageType, Data)] = []

        init(incoming: [(VTRMessageType, Data)]) {
            self.incoming = incoming
        }

        func readMessage(pool: BufferPool?, timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data) {
            XCTAssertGreaterThan(timeoutSeconds, 0)
            guard !incoming.isEmpty else {
                throw VTRemotedError.protocolViolation("no more messages")
            }
            let (type, body) = incoming.removeFirst()
            
            // If internal implementation wants to verify pool usage, we could.
            // For now, just return data.
            // If pool is provided, we *could* copy body into it, but FakeIO is for logic testing.
            if let pool = pool {
                var buf = pool.get(capacity: body.count)
                buf.append(body)
                return (VTRMessageHeader(type: type.rawValue, length: UInt32(body.count)), buf)
            }
            
            return (VTRMessageHeader(type: type.rawValue, length: UInt32(body.count)), body)
        }

        func send(type: VTRMessageType, body: Data) throws {
            sent.append((type, body))
        }

        func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws {
            var body = Data()
            for part in bodyParts { body.append(part) }
            try send(type: type, body: body)
        }
    }

    func testHappyPathEncodeHandshakeAndFlush() {
        let helloPayload = makeHello(token: "", codec: "h264")
        let configurePayload = makeConfigure(mode: "encode", wireCompression: "0")
        let fakeIO = FakeIO(incoming: [
            (.hello, helloPayload),
            (.configure, configurePayload),
            (.flush, Data())
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(io: fakeIO, expectedToken: "")
        handler.run()

        XCTAssertEqual(fakeIO.sent.count, 3)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[1].0, .configureAck)
        XCTAssertEqual(fakeIO.sent[2].0, .done)
        XCTAssertEqual(fakeIO.sent[0].1.first, 0)
    }

    func testAuthFailStopsAfterHelloAck() {
        let helloPayload = makeHello(token: "bad", codec: "h264")
        let fakeIO = FakeIO(incoming: [
            (.hello, helloPayload)
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(io: fakeIO, expectedToken: "good")
        handler.run()

        XCTAssertEqual(fakeIO.sent.count, 1)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[0].1.first, 2)
    }
}

private func makeHello(token: String, codec: String) -> Data {
    var writer = ByteWriter()
    writer.writeLengthPrefixedUTF8(token)
    writer.writeLengthPrefixedUTF8(codec)
    writer.writeLengthPrefixedUTF8("client")
    writer.writeLengthPrefixedUTF8("build")
    return writer.data
}

private func makeConfigure(mode: String, wireCompression: String) -> Data {
    var writer = ByteWriter()
    writer.writeBE(UInt32(64))
    writer.writeBE(UInt32(64))
    writer.write(UInt8(1))
    writer.writeBE(UInt32(1))
    writer.writeBE(UInt32(30))
    writer.writeBE(UInt32(30))
    writer.writeBE(UInt32(1))

    writer.writeBE(UInt16(2))
    writer.writeLengthPrefixedUTF8("mode")
    writer.writeLengthPrefixedUTF8(mode)
    writer.writeLengthPrefixedUTF8("wire_compression")
    writer.writeLengthPrefixedUTF8(wireCompression)

    writer.writeBE(UInt32(0))
    return writer.data
}
