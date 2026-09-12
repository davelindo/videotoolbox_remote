@testable import VTRemotedCore
import Darwin
import XCTest

final class ClientHandlerTests: XCTestCase {
    private final class AsyncFailingSession: CodecSession, @unchecked Sendable {
        let sender: MessageSender
        let stage: String
        let callbacks = DispatchGroup()
        init(sender: @escaping MessageSender, stage: String) {
            self.sender = sender
            self.stage = stage
        }
        func configure(_ configuration: SessionConfiguration) throws -> Data { Data() }
        func handlePacketMessage(_ payload: Data) throws { try handleFrameMessage(payload) }
        func handleFrameMessage(_ payload: Data) throws {
            callbacks.enter()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                defer { callbacks.leave() }
                if stage == "output-send" {
                    try? sender(.packet, [Data(count: 4 * 1024 * 1024)])
                } else {
                    try? sender(.error, [ErrorResponse(code: 2, message: "injected \(stage) failure").encode()])
                }
            }
        }
        func flush() throws { callbacks.wait() }
        func shutdown() { callbacks.wait() }
    }

    func testAsynchronousFailureInterruptsIdleInput() throws {
        for stage in ["decode", "encode", "transfer", "output-send"] {
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            defer { close(descriptors[0]); close(descriptors[1]) }
            var bufferBytes: Int32 = 4096
            XCTAssertEqual(setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &bufferBytes, 4), 0)
            let connection = try VTRWireConnection(fd: descriptors[0], writeTimeoutSeconds: 0.1)
            let peer = try VTRWireConnection(fd: descriptors[1])
            let handler = VTRClientHandler(io: connection, expectedToken: "", idleTimeoutSeconds: 60,
                sessionFactory: { AsyncFailingSession(sender: $0, stage: stage) })
            let finished = expectation(description: "\(stage) failure releases idle input")
            DispatchQueue.global().async {
                handler.run()
                finished.fulfill()
            }
            try peer.send(type: .hello, body: makeHello(token: "", codec: "h264"))
            XCTAssertEqual(try peer.readMessage(timeoutSeconds: 1).header.type, VTRMessageType.helloAck.rawValue)
            try peer.send(type: .configure, body: makeConfigure(mode: "encode", wireCompression: "0"))
            XCTAssertEqual(try peer.readMessage(timeoutSeconds: 1).header.type, VTRMessageType.configureAck.rawValue)
            try peer.send(type: .frame, body: Data())
            if stage != "output-send" {
                let response = try peer.readMessage(timeoutSeconds: 1)
                XCTAssertEqual(response.header.type, VTRMessageType.error.rawValue)
                XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains(stage))
            }
            wait(for: [finished], timeout: 1.5)
        }
    }

    private final class FailingSession: CodecSession {
        let sender: MessageSender
        let callbackFailure: Bool
        init(sender: @escaping MessageSender, callbackFailure: Bool) {
            self.sender = sender
            self.callbackFailure = callbackFailure
        }
        func configure(_ configuration: SessionConfiguration) throws -> Data { Data() }
        func handleFrameMessage(_ payload: Data) throws { }
        func handlePacketMessage(_ payload: Data) throws { }
        func shutdown() { }
        func flush() throws {
            if callbackFailure {
                try sender(.error, [ErrorResponse(code: 2, message: "injected callback failure").encode()])
            } else {
                throw VTRemotedError.protocolViolation("injected flush failure")
            }
        }
    }

    func testFailedFlushNeverSendsDone() {
        for callbackFailure in [false, true] {
            let io = FakeIO(incoming: [
                (.hello, makeHello(token: "", codec: "h264")),
                (.configure, makeConfigure(mode: "encode", wireCompression: "0")),
                (.flush, Data())
            ])
            let handler = VTRClientHandler(io: io, expectedToken: "", sessionFactory: {
                FailingSession(sender: $0, callbackFailure: callbackFailure)
            })
            handler.run()
            XCTAssertEqual(io.sent.map(\.0), [.helloAck, .configureAck, .error])
        }
    }

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
