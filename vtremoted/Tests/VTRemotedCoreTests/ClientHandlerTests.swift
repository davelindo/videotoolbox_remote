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
            if let pool {
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
            for part in bodyParts {
                body.append(part)
            }
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
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "",
            sessionFactory: { sender in StubCodecSession(sender: sender) }
        )
        handler.run()

        XCTAssertEqual(fakeIO.sent.count, 3)
        XCTAssertEqual(fakeIO.sent[0].0, .helloAck)
        XCTAssertEqual(fakeIO.sent[1].0, .configureAck)
        XCTAssertEqual(fakeIO.sent[2].0, .done)
        XCTAssertEqual(fakeIO.sent[0].1.first, 0)
    }

    func testHelloCodecSelectionFlowsIntoConfigure() {
        for codecName in ["h264", "hevc"] {
            let helloPayload = makeHello(token: "", codec: codecName)
            let configurePayload = makeConfigure(mode: "encode", wireCompression: "0")
            var configured: SessionConfiguration?
            let fakeIO = FakeIO(incoming: [
                (.hello, helloPayload),
                (.configure, configurePayload),
                (.done, Data())
            ])

            Logger.shared.level = .error
            let handler = VTRClientHandler(
                io: fakeIO,
                expectedToken: "",
                sessionFactory: { sender in
                    StubCodecSession(sender: sender, onConfigure: { configured = $0 })
                }
            )
            handler.run()

            XCTAssertEqual(configured?.codec.rawValue, codecName,
                           "codec \(codecName) should flow from HELLO into CONFIGURE")
        }
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

    func testTranscodePacketSendsPacketAckWhenNegotiated() {
        let fakeIO = FakeIO(incoming: [
            (.hello, makeHello(token: "", codec: "h264")),
            (.configure, makeConfigure(mode: "transcode", wireCompression: "0", packetAck: true)),
            (.packet, makePacket()),
            (.flush, Data())
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "",
            serverCapabilities: VTRCapability.defaultServer,
            sessionFactory: { sender in StubCodecSession(sender: sender) }
        )
        handler.run()

        XCTAssertEqual(fakeIO.sent.map(\.0), [.helloAck, .configureAck, .packet, .packetAck, .done])
        XCTAssertEqual(fakeIO.sent[3].1.count, 0)
    }

    func testPacketAckRequiresCapabilityModeAndClientRequest() {
        struct Case {
            let mode: String
            let caps: [String]
            let packetAck: Bool
        }

        let cases: [Case] = [
            Case(mode: "transcode", caps: VTRCapability.baseline, packetAck: true),
            Case(mode: "transcode", caps: VTRCapability.defaultServer, packetAck: false),
            Case(mode: "encode", caps: VTRCapability.defaultServer, packetAck: true),
            Case(mode: "decode", caps: VTRCapability.defaultServer, packetAck: true)
        ]

        for testCase in cases {
            let fakeIO = FakeIO(incoming: [
                (.hello, makeHello(token: "", codec: "h264")),
                (.configure, makeConfigure(mode: testCase.mode, wireCompression: "0", packetAck: testCase.packetAck)),
                (.packet, makePacket()),
                (.flush, Data())
            ])

            Logger.shared.level = .error
            let handler = VTRClientHandler(
                io: fakeIO,
                expectedToken: "",
                serverCapabilities: testCase.caps,
                sessionFactory: { sender in StubCodecSession(sender: sender) }
            )
            handler.run()

            XCTAssertFalse(fakeIO.sent.map(\.0).contains(.packetAck), "unexpected PACKET_ACK for \(testCase)")
        }
    }

    func testUnavailableLZ4ConfigureSendsErrorAndStops() throws {
        let fakeIO = FakeIO(incoming: [
            (.hello, makeHello(token: "", codec: "h264")),
            (.configure, makeConfigure(mode: "encode", wireCompression: "1")),
            (.flush, Data())
        ])

        Logger.shared.level = .error
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "",
            codecAvailability: CodecAvailability(
                lz4Available: false,
                zstdAvailable: true,
                lz4Diagnostics: "tried=[liblz4.dylib]; last dlerror=missing",
                zstdDiagnostics: "loaded=libzstd.dylib"
            ),
            sessionFactory: { _ in
                XCTFail("session should not be created when requested wire compression is unavailable")
                return StubCodecSession(sender: { _, _ in })
            }
        )
        handler.run()

        XCTAssertEqual(fakeIO.sent.map(\.0), [.helloAck, .error])
        let error = try decodeError(fakeIO.sent[1].1)
        XCTAssertEqual(error.code, 1)
        XCTAssertEqual(error.message, "configure failed: Unsupported: wire_compression=lz4")
        XCTAssertEqual(fakeIO.incoming.map(\.0), [.flush])
    }

    func testInvalidModeSendsOneErrorWithoutCreatingSession() throws {
        let fakeIO = FakeIO(incoming: [
            (.hello, makeHello(token: "", codec: "h264")),
            (.configure, makeConfigure(mode: "invalid", wireCompression: "0")),
            (.flush, Data())
        ])

        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "",
            sessionFactory: { _ in
                XCTFail("session should not be created for an invalid mode")
                return StubCodecSession(sender: { _, _ in })
            }
        )
        handler.run()

        XCTAssertEqual(fakeIO.sent.map(\.0), [.helloAck, .error])
        let error = try decodeError(fakeIO.sent[1].1)
        XCTAssertEqual(error.message, "configure failed: Unsupported: mode=invalid")
        XCTAssertEqual(fakeIO.incoming.map(\.0), [.flush])
    }

    func testOversizedConfigureSendsExactlyOneError() throws {
        let fakeIO = FakeIO(incoming: [
            (.hello, makeHello(token: "", codec: "h264")),
            (.configure, makeConfigure(mode: "encode", wireCompression: "0"))
        ])
        let handler = VTRClientHandler(
            io: fakeIO,
            expectedToken: "",
            maxMessageBytes: 32,
            sessionFactory: { _ in
                XCTFail("session should not be created for an oversized CONFIGURE")
                return StubCodecSession(sender: { _, _ in })
            }
        )
        handler.run()

        XCTAssertEqual(fakeIO.sent.map(\.0), [.helloAck, .error])
        let error = try decodeError(fakeIO.sent[1].1)
        XCTAssertEqual(error.message, "configure failed: Protocol violation: message too large")
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

private func makeConfigure(mode: String, wireCompression: String, packetAck: Bool = false) -> Data {
    var writer = ByteWriter()
    writer.writeBE(UInt32(64))
    writer.writeBE(UInt32(64))
    writer.write(UInt8(1))
    writer.writeBE(UInt32(1))
    writer.writeBE(UInt32(30))
    writer.writeBE(UInt32(30))
    writer.writeBE(UInt32(1))

    var options = [
        ("mode", mode),
        ("wire_compression", wireCompression)
    ]
    if packetAck {
        options.append(("packet_ack.v1", "1"))
    }

    writer.writeBE(UInt16(options.count))
    for (key, value) in options {
        writer.writeLengthPrefixedUTF8(key)
        writer.writeLengthPrefixedUTF8(value)
    }

    writer.writeBE(UInt32(0))
    return writer.data
}

private func makePacket() -> Data {
    let annexB = Data([0x00, 0x00, 0x00, 0x01])
    var writer = ByteWriter()
    writer.writeBE(UInt64(1))
    writer.writeBE(UInt64(1))
    writer.writeBE(UInt64(1))
    writer.writeBE(UInt32(1))
    writer.writeBE(UInt32(annexB.count))
    writer.write(annexB)
    return writer.data
}

private func decodeError(_ payload: Data) throws -> ErrorResponse {
    var reader = ByteReader(payload)
    let code = try reader.readBEUInt32()
    let message = try reader.readLengthPrefixedUTF8()
    return ErrorResponse(code: code, message: message)
}
