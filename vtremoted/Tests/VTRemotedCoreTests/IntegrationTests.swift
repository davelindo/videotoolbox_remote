@testable import VTRemotedCore
import XCTest

final class IntegrationTests: XCTestCase {
    private final class FakeIO: VTRMessageIO, @unchecked Sendable {
        var incoming: [(VTRMessageType, Data)]
        var sent: [(VTRMessageType, Data)] = []

        init(incoming: [(VTRMessageType, Data)]) {
            self.incoming = incoming
        }

        func readMessage(timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data) {
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

    func testFullSessionEncode() throws {
        // 1. Prepare Messages
        let helloPayload = makeHello(token: "secret", codec: "h264")

        // Configure for Encode (mode="encode", wire_compression="0")
        let configurePayload = makeConfigure(mode: "encode", wireCompression: "0", width: 100, height: 100)

        // Frame payload (StubCodecSession expects 2 planes)
        var writer = ByteWriter()
        writer.writeBE(UInt64(100)) // pts
        writer.writeBE(UInt64(1)) // dur
        writer.writeBE(UInt32(0)) // flags
        writer.write(UInt8(2)) // planeCount

        // Plane 0
        writer.writeBE(UInt32(100)) // stride
        writer.writeBE(UInt32(100)) // height
        let plane0 = Data(repeating: 0xAA, count: 100 * 100)
        writer.writeBE(UInt32(plane0.count))
        writer.write(plane0)

        // Plane 1
        writer.writeBE(UInt32(100)) // stride
        writer.writeBE(UInt32(50)) // height
        let plane1 = Data(repeating: 0xBB, count: 100 * 50)
        writer.writeBE(UInt32(plane1.count))
        writer.write(plane1)

        let framePayload = writer.data

        let fakeIO = FakeIO(incoming: [
            (.hello, helloPayload),
            (.configure, configurePayload),
            (.frame, framePayload),
            (.flush, Data())
        ])

        // 2. Run Handler with StubCodecSession
        Logger.shared.level = .error
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "secret",
            sessionFactory: { sender in StubCodecSession(sender: sender) }
        )
        handler.run()

        // 3. Verify
        // Expected: HELLO_ACK, CONFIGURE_ACK, PACKET, DONE
        XCTAssertEqual(fakeIO.sent.count, 4)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[1].0, .configureAck)

        XCTAssertEqual(fakeIO.sent[2].0, .packet)
        // StubCodecSession output packet:
        // PTS(8) + DTS(8) + DUR(8) + KEY(4) + LEN(4) + ANNEXB(4 + 16 digest)
        // 8+8+8+4+4+20 = 52 bytes
        XCTAssertEqual(fakeIO.sent[2].1.count, 52)

        XCTAssertEqual(fakeIO.sent[3].0, .done)
    }

    func testFullSessionDecode() throws {
        // 1. Prepare Messages
        let helloPayload = makeHello(token: "secret", codec: "h264")

        // Configure for Decode (mode="decode", wire_compression="0")
        let configurePayload = makeConfigure(mode: "decode", wireCompression: "0", width: 100, height: 100)

        // Packet payload
        var writer = ByteWriter()
        writer.writeBE(UInt64(200)) // pts
        writer.writeBE(UInt64(200)) // dts
        writer.writeBE(UInt64(1)) // dur
        writer.writeBE(UInt32(1)) // isKey
        let packetData = Data([0x01, 0x02, 0x03, 0x04])
        writer.writeBE(UInt32(packetData.count))
        writer.write(packetData)

        let packetPayload = writer.data

        let fakeIO = FakeIO(incoming: [
            (.hello, helloPayload),
            (.configure, configurePayload),
            (.packet, packetPayload),
            (.flush, Data())
        ])

        // 2. Run Handler with StubCodecSession
        Logger.shared.level = .error
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "secret",
            sessionFactory: { sender in StubCodecSession(sender: sender) }
        )
        handler.run()

        // 3. Verify
        // Expected: HELLO_ACK, CONFIGURE_ACK, FRAME, DONE
        XCTAssertEqual(fakeIO.sent.count, 4)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[1].0, .configureAck)

        XCTAssertEqual(fakeIO.sent[2].0, .frame)
        // StubCodecSession output frame for 100x100 NV12:
        // PTS(8) + DUR(8) + FLAGS(4) + PLANES(1) +
        //   Plane0: STRIDE(4) + HEIGHT(4) + LEN(4) + DATA(100*100)
        //   Plane1: STRIDE(4) + HEIGHT(4) + LEN(4) + DATA(100*50)
        // Header: 8+8+4+1 = 21
        // Plane 0 meta: 12
        // Plane 1 meta: 12
        // Data: 10000 + 5000 = 15000
        // Total: 21 + 24 + 15000 = 15045
        XCTAssertEqual(fakeIO.sent[2].1.count, 15045)

        XCTAssertEqual(fakeIO.sent[3].0, .done)
    }

    func testFullSessionEncodeZstd() throws {
        // 1. Prepare Messages
        let helloPayload = makeHello(token: "secret", codec: "h264")

        // Configure for Encode (mode="encode", wire_compression="2" for Zstd)
        let configurePayload = makeConfigure(mode: "encode", wireCompression: "2", width: 64, height: 64)

        // Frame payload (StubCodecSession expects 2 planes)
        var writer = ByteWriter()
        writer.writeBE(UInt64(100)) // pts
        writer.writeBE(UInt64(1)) // dur
        writer.writeBE(UInt32(0)) // flags
        writer.write(UInt8(2)) // planeCount

        // Planes (pre-compress them for Zstd)
        let plane0 = Data(repeating: 0xAA, count: 64 * 64)
        let plane1 = Data(repeating: 0xBB, count: 64 * 32)
        let compPlane0 = ZstdCodec.compress(plane0)!
        let compPlane1 = ZstdCodec.compress(plane1)!

        writer.writeBE(UInt32(64)) // stride
        writer.writeBE(UInt32(64)) // height
        writer.writeBE(UInt32(compPlane0.count))
        writer.write(compPlane0)

        writer.writeBE(UInt32(64)) // stride
        writer.writeBE(UInt32(32)) // height
        writer.writeBE(UInt32(compPlane1.count))
        writer.write(compPlane1)

        let framePayload = writer.data

        let fakeIO = FakeIO(incoming: [
            (.hello, helloPayload),
            (.configure, configurePayload),
            (.frame, framePayload),
            (.flush, Data())
        ])

        // 2. Run Handler
        Logger.shared.level = .error
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "secret",
            sessionFactory: { sender in StubCodecSession(sender: sender) }
        )
        handler.run()

        // 3. Verify
        XCTAssertEqual(fakeIO.sent.count, 4)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[1].0, .configureAck)
        XCTAssertEqual(fakeIO.sent[2].0, .packet)
        XCTAssertEqual(fakeIO.sent[3].0, .done)
    }

    // Helpers
    private func makeHello(token: String, codec: String) -> Data {
        var writer = ByteWriter()
        writer.writeLengthPrefixedUTF8(token)
        writer.writeLengthPrefixedUTF8(codec)
        writer.writeLengthPrefixedUTF8("client")
        writer.writeLengthPrefixedUTF8("build")
        return writer.data
    }

    private func makeConfigure(mode: String, wireCompression: String, width: Int, height: Int) -> Data {
        var writer = ByteWriter()
        writer.writeBE(UInt32(width))
        writer.writeBE(UInt32(height))
        writer.write(UInt8(1)) // pixelFormat NV12
        writer.writeBE(UInt32(1)) // tb num
        writer.writeBE(UInt32(30)) // tb den
        writer.writeBE(UInt32(30)) // fr num
        writer.writeBE(UInt32(1)) // fr den

        writer.writeBE(UInt16(2)) // options count
        writer.writeLengthPrefixedUTF8("mode")
        writer.writeLengthPrefixedUTF8(mode)
        writer.writeLengthPrefixedUTF8("wire_compression")
        writer.writeLengthPrefixedUTF8(wireCompression)

        writer.writeBE(UInt32(0)) // extradata len
        return writer.data
    }
}
