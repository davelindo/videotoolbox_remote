import Foundation

public final class VTRClientHandler: @unchecked Sendable {
    private let messageIO: VTRMessageIO
    private let expectedToken: String
    private let logger: Logger
    public typealias SessionFactory = (@escaping MessageSender) -> CodecSession
    private let sessionFactory: SessionFactory

    private let serverName: String
    private let serverVersion: String
    private let serverCapabilities: [String]
    private let serverSessionSnapshot: () -> (maxSessions: Int, activeSessions: Int)

    private let handshakeTimeoutSeconds: Int
    private let idleTimeoutSeconds: Int
    private let maxMessageBytes: Int

    private static let maxHelloBytes: Int = 64 * 1024
    private static let maxConfigureBytes: Int = 4 * 1024 * 1024

    private var codec: VideoCodec = .h264
    private var clientName: String = "unknown"
    private var stats = ClientStats()
    private var configuration: SessionConfiguration?
    private var codecSession: (any CodecSession)?
    private let inputBufferPool = BufferPool()

    public init(
        io messageIO: VTRMessageIO,
        expectedToken: String,
        logger: Logger = .shared,
        handshakeTimeoutSeconds: Int = 10,
        idleTimeoutSeconds: Int = 60,
        maxMessageBytes: Int = 256 * 1024 * 1024,
        serverName: String = "vtremoted",
        serverVersion: String = "unknown",
        serverCapabilities: [String] = VTRCapability.baseline,
        serverSessionSnapshot: @escaping () -> (maxSessions: Int, activeSessions: Int) = { (0, 0) },
        sessionFactory: @escaping SessionFactory = CodecSessionFactory.make
    ) {
        self.messageIO = messageIO
        self.expectedToken = expectedToken
        self.logger = logger
        self.handshakeTimeoutSeconds = max(1, handshakeTimeoutSeconds)
        self.idleTimeoutSeconds = max(1, idleTimeoutSeconds)
        self.maxMessageBytes = max(1, maxMessageBytes)
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.serverCapabilities = serverCapabilities
        self.serverSessionSnapshot = serverSessionSnapshot
        self.sessionFactory = sessionFactory
    }

    public func run() {
        defer {
            if let configuration {
                logger.info(stats.summary(mode: configuration.mode))
            }
            codecSession?.shutdown()
        }

        do {
            try handshake()
            try configure()
            try mainLoop()
        } catch {
            logger.error("ERROR session=\(clientName) err=\(error)")
        }
    }

    private func sendError(code: UInt32, message: String) {
        let body = makeErrorBody(code: code, message: message)
        // Best-effort: if the socket is already dead, we'll just log on our side.
        try? messageIO.send(type: .error, body: body)
    }

    private func sendErrorThrowing(code: UInt32, message: String) throws {
        let body = makeErrorBody(code: code, message: message)
        try messageIO.send(type: .error, body: body)
    }

    private func makeErrorBody(code: UInt32, message: String) -> Data {
        let err = ErrorResponse(code: code, message: message)
        let body = err.encode()
        stats.bytesOut += Int64(VTRProtocol.headerSize + body.count)
        return body
    }

    private func validateMessageLength(_ length: Int, type: UInt16, cap: Int) throws {
        if length > cap {
            sendError(code: 4, message: "message too large type=\(type) len=\(length) cap=\(cap)")
            throw VTRemotedError.protocolViolation("message too large")
        }
    }

    private func totalBodyByteCount(_ bodyParts: [Data]) -> Int {
        switch bodyParts.count {
        case 0:
            return 0
        case 1:
            return bodyParts[0].count
        case 2:
            return bodyParts[0].count + bodyParts[1].count
        default:
            var runningTotal = 0
            for part in bodyParts {
                runningTotal += part.count
            }
            return runningTotal
        }
    }

    private func transcodeLogSuffix(for config: SessionConfiguration) -> String {
        guard config.mode == .transcode else { return "" }
        return " out=\(config.outputWidth)x\(config.outputHeight) " +
            "scale=\(config.scaleMode.rawValue) out_codec=\(config.outputCodec.rawValue)"
    }

    private func readMessageCapped(
        timeoutSeconds: Int,
        maxBodyBytes: Int
    ) throws -> (header: VTRMessageHeader, body: Data) {
        let cap = min(max(1, maxBodyBytes), maxMessageBytes)

        if let streamIO = messageIO as? VTRStreamIO {
            return try streamIO.readMessageAtomically(
                pool: inputBufferPool,
                timeoutSeconds: timeoutSeconds,
                validateHeader: { header in
                    try validateMessageLength(Int(header.length), type: header.type, cap: cap)
                }
            )
        }

        let (header, body) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: timeoutSeconds)
        try validateMessageLength(body.count, type: header.type, cap: cap)
        return (header, body)
    }

    private func handshake() throws {
        let (header, payload) = try readMessageCapped(
            timeoutSeconds: handshakeTimeoutSeconds,
            maxBodyBytes: Self.maxHelloBytes
        )
        defer { inputBufferPool.return(payload) }
        stats.bytesIn += Int64(VTRProtocol.headerSize + payload.count)
        guard header.type == VTRMessageType.hello.rawValue else {
            throw VTRemotedError.protocolViolation("expected HELLO")
        }
        let hello = try HelloRequest.decode(payload)
        clientName = hello.clientName
        codec = VideoCodec(rawValue: hello.codec) ?? .h264

        let requireToken = !expectedToken.isEmpty
        let authed = !requireToken || (hello.token == expectedToken)
        let status: UInt8 = authed ? 0 : 2

        let snapshot = serverSessionSnapshot()
        let ack = HelloAckResponse(
            status: status,
            serverName: serverName,
            serverVersion: serverVersion,
            capabilities: serverCapabilities,
            maxSessions: UInt16(clamping: snapshot.maxSessions),
            activeSessions: UInt16(clamping: snapshot.activeSessions)
        )
        let ackBody = ack.encode()
        stats.bytesOut += Int64(VTRProtocol.headerSize + ackBody.count)
        try messageIO.send(type: .helloAck, body: ackBody)

        if !authed {
            logger.info("HELLO authfail from \(hello.clientName) codec=\(hello.codec)")
            throw VTRemotedError.protocolViolation("unauthorized")
        }
        logger.info("HELLO ok client=\(hello.clientName) build=\(hello.build) codec=\(hello.codec)")
    }

    private func configure() throws {
        let (header, payload) = try readMessageCapped(
            timeoutSeconds: handshakeTimeoutSeconds,
            maxBodyBytes: Self.maxConfigureBytes
        )
        defer { inputBufferPool.return(payload) }
        stats.bytesIn += Int64(VTRProtocol.headerSize + payload.count)
        guard header.type == VTRMessageType.configure.rawValue else {
            throw VTRemotedError.protocolViolation("expected CONFIGURE")
        }
        let request = try ConfigureRequest.decode(payload)
        let config = try SessionConfiguration(codec: codec, request: request)

        let wireComp = config.options.wireCompression
        if wireComp != 0, wireComp != 1, wireComp != 2 {
            try sendErrorThrowing(code: 1, message: "unsupported wire_compression=\(wireComp)")
            throw VTRemotedError.unsupported("wire_compression")
        }

        logger.info(
            "CONFIGURE req mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) " +
                "\(config.width)x\(config.height) " +
                "pix=\(config.pixelFormat)(\(VTRPixelFormat.name(config.pixelFormat))) " +
                "tb=\(config.timebase.num)/\(config.timebase.den) " +
                "fr=\(config.frameRate.num)/\(config.frameRate.den) br=\(config.options.bitrate) " +
                "gop=\(config.options.gop) wc=\(config.options.wireCompression)" +
                transcodeLogSuffix(for: config)
        )

        let mode = config.mode
        let session = sessionFactory { [weak self] type, bodyParts in
            guard let self else { return }
            let totalCount = totalBodyByteCount(bodyParts)
            stats.bytesOut += Int64(VTRProtocol.headerSize + totalCount)
            if type == .packet { stats.packetsOut += 1; stats.recordOutput() }
            if type == .frame { stats.framesOut += 1 }
            stats.maybeReport(mode: mode, logger: logger, intervalSeconds: 0.25)
            try messageIO.sendMessage(type: type, bodyParts: bodyParts)
        }
        codecSession = session
        configuration = config

        do {
            let extradata = try session.configure(config)
            let resp = ConfigureAckResponse(
                status: 0,
                extradata: extradata,
                pixelFormat: config.pixelFormat,
                warnings: 0
            )
            let body = resp.encode()
            stats.bytesOut += Int64(VTRProtocol.headerSize + body.count)
            try messageIO.send(type: .configureAck, body: body)

            logger.info(
                "CONFIGURE ok mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) " +
                    "\(config.width)x\(config.height) " +
                    "pixfmt=\(config.pixelFormat)(\(VTRPixelFormat.name(config.pixelFormat))) " +
                    "tb=\(config.timebase.num)/\(config.timebase.den) " +
                    "br=\(config.options.bitrate) " +
                    "gop=\(config.options.gop) wc=\(config.options.wireCompression)" +
                    transcodeLogSuffix(for: config)
            )
        } catch {
            logger.error("CONFIGURE failed mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) error=\(error)")
            try sendErrorThrowing(code: 1, message: "configure failed: \(error)")
            throw error
        }
    }

    private func mainLoop() throws {
        guard let configuration, let codecSession else {
            throw VTRemotedError.protocolViolation("missing configuration")
        }

        func sendDoneAndLog() throws {
            try messageIO.send(type: .done, body: Data())
            let msg: String
            switch configuration.mode {
            case .encode:
                msg = "DONE client=\(clientName) frames=\(stats.framesIn) packets=\(stats.packetsOut)"
            case .decode:
                msg = "DONE client=\(clientName) packets=\(stats.packetsIn) frames=\(stats.framesOut)"
            case .transcode:
                msg = "DONE client=\(clientName) packets=\(stats.packetsIn) packets_out=\(stats.packetsOut)"
            }
            logger.info(msg)
        }

        // Prefer streaming reads when available to avoid materializing large FRAME payloads.
        if let streamIO = messageIO as? VTRStreamIO {
            while true {
                let header = try streamIO.readHeader(timeoutSeconds: idleTimeoutSeconds)
                let messageLength = Int(header.length)
                try validateMessageLength(messageLength, type: header.type, cap: maxMessageBytes)
                stats.bytesIn += Int64(VTRProtocol.headerSize) + Int64(messageLength)
                stats.maybeReport(mode: configuration.mode, logger: logger, intervalSeconds: 0.25)

                guard let type = VTRMessageType(rawValue: header.type) else {
                    try streamIO.skip(length: messageLength)
                    continue
                }

                switch type {
                case .frame:
                    stats.framesIn += 1
                    stats.recordSubmit()
                    if let streamSession = codecSession as? StreamingCodecSession {
                        try streamSession.handleFrameStream(streamIO: streamIO, length: messageLength)
                    } else {
                        let payload = try streamIO.readBody(length: messageLength, pool: inputBufferPool)
                        defer { inputBufferPool.return(payload) }
                        try codecSession.handleFrameMessage(payload)
                    }
                case .packet:
                    stats.packetsIn += 1
                    let payload = try streamIO.readBody(length: messageLength, pool: inputBufferPool)
                    defer { inputBufferPool.return(payload) }
                    try codecSession.handlePacketMessage(payload)
                case .flush:
                    try streamIO.skip(length: messageLength)
                    try codecSession.flush()
                    try sendDoneAndLog()
                    return
                case .ping:
                    try streamIO.skip(length: messageLength)
                    try messageIO.send(type: .pong, body: Data())
                default:
                    try streamIO.skip(length: messageLength)
                }
            }
        }

        while true {
            let (header, payload) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: idleTimeoutSeconds)
            defer { inputBufferPool.return(payload) }
            try validateMessageLength(payload.count, type: header.type, cap: maxMessageBytes)
            stats.bytesIn += Int64(VTRProtocol.headerSize + payload.count)
            stats.maybeReport(mode: configuration.mode, logger: logger, intervalSeconds: 0.25)
            guard let type = VTRMessageType(rawValue: header.type) else {
                continue
            }

            switch type {
            case .frame:
                stats.framesIn += 1
                stats.recordSubmit()
                try codecSession.handleFrameMessage(payload)
            case .packet:
                stats.packetsIn += 1
                try codecSession.handlePacketMessage(payload)
            case .flush:
                try codecSession.flush()
                try sendDoneAndLog()
                return
            case .ping:
                try messageIO.send(type: .pong, body: Data())
            default:
                break
            }
        }
    }
}
