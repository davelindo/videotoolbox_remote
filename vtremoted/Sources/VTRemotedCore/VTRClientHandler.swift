import Foundation

public struct CodecAvailability: Sendable {
    private let lz4AvailableProbe: @Sendable () -> Bool
    private let zstdAvailableProbe: @Sendable () -> Bool
    private let lz4DiagnosticsProbe: @Sendable () -> String
    private let zstdDiagnosticsProbe: @Sendable () -> String

    public init(
        lz4Available: Bool,
        zstdAvailable: Bool,
        lz4Diagnostics: String,
        zstdDiagnostics: String
    ) {
        lz4AvailableProbe = { lz4Available }
        zstdAvailableProbe = { zstdAvailable }
        lz4DiagnosticsProbe = { lz4Diagnostics }
        zstdDiagnosticsProbe = { zstdDiagnostics }
    }

    public static var runtime: CodecAvailability {
        CodecAvailability(
            lz4Available: { LZ4Codec.isAvailable },
            zstdAvailable: { ZstdCodec.isAvailable },
            lz4Diagnostics: { LZ4Codec.loadDiagnostics },
            zstdDiagnostics: { ZstdCodec.loadDiagnostics }
        )
    }

    public init(
        lz4Available: @Sendable @escaping () -> Bool,
        zstdAvailable: @Sendable @escaping () -> Bool,
        lz4Diagnostics: @Sendable @escaping () -> String,
        zstdDiagnostics: @Sendable @escaping () -> String
    ) {
        lz4AvailableProbe = lz4Available
        zstdAvailableProbe = zstdAvailable
        lz4DiagnosticsProbe = lz4Diagnostics
        zstdDiagnosticsProbe = zstdDiagnostics
    }

    public var lz4Available: Bool {
        lz4AvailableProbe()
    }

    public var zstdAvailable: Bool {
        zstdAvailableProbe()
    }

    public var lz4Diagnostics: String {
        lz4DiagnosticsProbe()
    }

    public var zstdDiagnostics: String {
        zstdDiagnosticsProbe()
    }
}

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
    private let codecAvailability: CodecAvailability

    private let handshakeTimeoutSeconds: Int
    private let idleTimeoutSeconds: Int
    private let maxMessageBytes: Int

    private static let maxHelloBytes: Int = 64 * 1024
    private static let maxConfigureBytes: Int = 4 * 1024 * 1024

    private var codec: VideoCodec = .h264
    private var clientName: String = "unknown"
    private let stats = LockedClientStats()
    private let failure = SessionFailure()
    private var configuration: SessionConfiguration?
    private var codecSession: (any CodecSession)?
    private let inputBufferPool = BufferPool()

    private var sendsPacketAck: Bool {
        serverCapabilities.contains(VTRCapability.packetAckV1)
    }

    private func shouldSendPacketAck(for configuration: SessionConfiguration) -> Bool {
        configuration.mode == .transcode && sendsPacketAck && configuration.options.packetAckV1
    }

    private func sendTranscodePacketAckIfNeeded(for configuration: SessionConfiguration) throws {
        guard shouldSendPacketAck(for: configuration) else { return }
        try messageIO.send(type: .packetAck, body: Data())
        stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize) }
    }

    private func rejectUnexpectedKnownClientMessage(_ type: VTRMessageType) throws {
        switch type {
        case .helloAck, .configureAck, .done, .packetAck:
            sendError(code: 4, message: "unexpected client message type=\(type.rawValue)")
            throw VTRemotedError.protocolViolation("unexpected client message type=\(type.rawValue)")
        default:
            return
        }
    }

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
        codecAvailability: CodecAvailability = .runtime,
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
        self.codecAvailability = codecAvailability
        self.sessionFactory = sessionFactory
    }

    public func run() {
        defer {
            codecSession?.shutdown()
            if let configuration {
                logger.info(stats.snapshot().summary(mode: configuration.mode))
            }
        }

        do {
            try handshake()
            try configure()
            do {
                try mainLoop()
            } catch {
                if failure.record(error) {
                    sendError(code: 2, message: "processing failed: \(error)")
                }
                throw error
            }
        } catch {
            logger.error("ERROR session=\(clientName) err=\(error)")
        }
    }

    private func sendError(code: UInt32, message: String) {
        failure.record(VTRemotedError.protocolViolation(message))
        let body = ErrorResponse(code: code, message: message).encode()
        // Best-effort: if the socket is already dead, we'll just log on our side.
        do {
            try messageIO.send(type: .error, body: body)
            stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize + body.count) }
        } catch { }
    }

    private func validateMessageLength(
        _ length: Int,
        type: UInt16,
        cap: Int,
        sendErrorResponse: Bool = true
    ) throws {
        guard length > cap else { return }
        if sendErrorResponse {
            sendError(code: 4, message: "message too large type=\(type) len=\(length) cap=\(cap)")
        }
        throw VTRemotedError.protocolViolation("message too large")
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
        maxBodyBytes: Int,
        sendLengthError: Bool = true
    ) throws -> (header: VTRMessageHeader, body: Data) {
        let cap = min(max(1, maxBodyBytes), maxMessageBytes)

        if let streamIO = messageIO as? VTRStreamIO {
            return try streamIO.readMessageAtomically(
                pool: inputBufferPool,
                timeoutSeconds: timeoutSeconds,
                validateHeader: { header in
                    try validateMessageLength(
                        Int(header.length),
                        type: header.type,
                        cap: cap,
                        sendErrorResponse: sendLengthError
                    )
                }
            )
        }

        let (header, body) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: timeoutSeconds)
        try validateMessageLength(
            body.count,
            type: header.type,
            cap: cap,
            sendErrorResponse: sendLengthError
        )
        return (header, body)
    }

    private func handshake() throws {
        let (header, payload) = try readMessageCapped(
            timeoutSeconds: handshakeTimeoutSeconds,
            maxBodyBytes: Self.maxHelloBytes
        )
        defer { inputBufferPool.return(payload) }
        stats.update { $0.bytesIn += Int64(VTRProtocol.headerSize + payload.count) }
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
        try messageIO.send(type: .helloAck, body: ackBody)
        stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize + ackBody.count) }

        if !authed {
            logger.info("HELLO authfail from \(hello.clientName) codec=\(hello.codec)")
            throw VTRemotedError.protocolViolation("unauthorized")
        }
        logger.info("HELLO ok client=\(hello.clientName) build=\(hello.build) codec=\(hello.codec)")
    }

    private func configure() throws {
        do {
            try performConfigure()
        } catch {
            logger.error("CONFIGURE failed error=\(error)")
            if !failure.hasFailed { sendError(code: 1, message: "configure failed: \(error)") }
            throw error
        }
    }

    private func performConfigure() throws {
        let (header, payload) = try readMessageCapped(
            timeoutSeconds: handshakeTimeoutSeconds,
            maxBodyBytes: Self.maxConfigureBytes,
            sendLengthError: false
        )
        defer { inputBufferPool.return(payload) }
        stats.update { $0.bytesIn += Int64(VTRProtocol.headerSize + payload.count) }
        guard header.type == VTRMessageType.configure.rawValue else {
            throw VTRemotedError.protocolViolation("expected CONFIGURE")
        }
        let request = try ConfigureRequest.decode(payload)
        let config = try SessionConfiguration(
            codec: codec,
            request: request,
            maxFrameBytes: maxMessageBytes
        )

        try validateWireCompression(config.options.wireCompression)

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
            if type == .error {
                failure.record(VTRemotedError.protocolViolation("asynchronous codec failure"))
            } else {
                try failure.check()
            }
            defer {
                if type == .error { (messageIO as? VTRWireConnection)?.cancelRead() }
            }
            let totalCount = totalBodyByteCount(bodyParts)
            do {
                try messageIO.sendMessage(type: type, bodyParts: bodyParts)
            } catch {
                failure.record(error)
                (messageIO as? VTRWireConnection)?.cancelRead()
                throw error
            }
            stats.update {
                $0.bytesOut += Int64(VTRProtocol.headerSize + totalCount)
                if type == .packet { $0.packetsOut += 1; $0.recordOutput() }
                if type == .frame { $0.framesOut += 1; $0.recordOutput() }
            }
            stats.maybeReport(mode: mode, logger: logger, intervalSeconds: 0.25)
        }
        codecSession = session
        configuration = config

        let extradata = try session.configure(config)
        try failure.check()
        let resp = ConfigureAckResponse(
            status: 0,
            extradata: extradata,
            pixelFormat: config.pixelFormat,
            warnings: 0
        )
        let body = resp.encode()
        try messageIO.send(type: .configureAck, body: body)
        stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize + body.count) }

        logger.info(
            "CONFIGURE ok mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) " +
                "\(config.width)x\(config.height) " +
                "pixfmt=\(config.pixelFormat)(\(VTRPixelFormat.name(config.pixelFormat))) " +
                "tb=\(config.timebase.num)/\(config.timebase.den) " +
                "br=\(config.options.bitrate) " +
                "gop=\(config.options.gop) wc=\(config.options.wireCompression)" +
                transcodeLogSuffix(for: config)
        )
    }

    private func validateWireCompression(_ wireCompression: Int) throws {
        // Wire compression modes: 0=none, 1=LZ4, 2=Zstd.
        switch wireCompression {
        case 0:
            return
        case 1 where !codecAvailability.lz4Available:
            logger.error("CONFIGURE rejected: lz4 codec unavailable; \(codecAvailability.lz4Diagnostics)")
            throw VTRemotedError.unsupported("wire_compression=lz4")
        case 2 where !codecAvailability.zstdAvailable:
            logger.error("CONFIGURE rejected: zstd codec unavailable; \(codecAvailability.zstdDiagnostics)")
            throw VTRemotedError.unsupported("wire_compression=zstd")
        case 1, 2:
            return
        default:
            logger.error("CONFIGURE rejected: unsupported wire_compression=\(wireCompression)")
            throw VTRemotedError.unsupported("wire_compression=\(wireCompression)")
        }
    }

    private func mainLoop() throws {
        guard let configuration, let codecSession else {
            throw VTRemotedError.protocolViolation("missing configuration")
        }

        func sendDoneAndLog() throws {
            try failure.check()
            try messageIO.send(type: .done, body: Data())
            self.stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize) }
            let stats = stats.snapshot()
            let msg = switch configuration.mode {
            case .encode:
                "DONE client=\(clientName) frames=\(stats.framesIn) packets=\(stats.packetsOut)"
            case .decode:
                "DONE client=\(clientName) packets=\(stats.packetsIn) frames=\(stats.framesOut)"
            case .transcode:
                "DONE client=\(clientName) packets=\(stats.packetsIn) packets_out=\(stats.packetsOut)"
            }
            logger.info(msg)
        }

        // Prefer streaming reads when available to avoid materializing large FRAME payloads.
        if let streamIO = messageIO as? VTRStreamIO {
            while true {
                try failure.check()
                let header = try streamIO.readHeader(timeoutSeconds: idleTimeoutSeconds)
                try failure.check()
                let messageLength = Int(header.length)
                try validateMessageLength(messageLength, type: header.type, cap: maxMessageBytes)
                stats.update { $0.bytesIn += Int64(VTRProtocol.headerSize) + Int64(messageLength) }
                stats.maybeReport(mode: configuration.mode, logger: logger, intervalSeconds: 0.25)

                guard let type = VTRMessageType(rawValue: header.type) else {
                    try streamIO.skip(length: messageLength)
                    continue
                }

                switch type {
                case .frame:
                    stats.update { $0.framesIn += 1; $0.recordSubmit() }
                    if let streamSession = codecSession as? StreamingCodecSession {
                        try streamSession.handleFrameStream(streamIO: streamIO, length: messageLength)
                    } else {
                        let payload = try streamIO.readBody(length: messageLength, pool: inputBufferPool)
                        defer { inputBufferPool.return(payload) }
                        try codecSession.handleFrameMessage(payload)
                    }
                case .packet:
                    stats.update { $0.packetsIn += 1; $0.recordSubmit() }
                    let payload = try streamIO.readBody(length: messageLength, pool: inputBufferPool)
                    defer { inputBufferPool.return(payload) }
                    try codecSession.handlePacketMessage(payload)
                    try sendTranscodePacketAckIfNeeded(for: configuration)
                case .flush:
                    try streamIO.skip(length: messageLength)
                    try codecSession.flush()
                    try sendDoneAndLog()
                    return
                case .ping:
                    try streamIO.skip(length: messageLength)
                    try messageIO.send(type: .pong, body: Data())
                    stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize) }
                default:
                    try streamIO.skip(length: messageLength)
                    try rejectUnexpectedKnownClientMessage(type)
                }
            }
        }

        while true {
            try failure.check()
            let (header, payload) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: idleTimeoutSeconds)
            try failure.check()
            defer { inputBufferPool.return(payload) }
            try validateMessageLength(payload.count, type: header.type, cap: maxMessageBytes)
            stats.update { $0.bytesIn += Int64(VTRProtocol.headerSize + payload.count) }
            stats.maybeReport(mode: configuration.mode, logger: logger, intervalSeconds: 0.25)
            guard let type = VTRMessageType(rawValue: header.type) else {
                continue
            }

            switch type {
            case .frame:
                stats.update { $0.framesIn += 1; $0.recordSubmit() }
                try codecSession.handleFrameMessage(payload)
            case .packet:
                stats.update { $0.packetsIn += 1; $0.recordSubmit() }
                try codecSession.handlePacketMessage(payload)
                try sendTranscodePacketAckIfNeeded(for: configuration)
            case .flush:
                try codecSession.flush()
                try sendDoneAndLog()
                return
            case .ping:
                try messageIO.send(type: .pong, body: Data())
                stats.update { $0.bytesOut += Int64(VTRProtocol.headerSize) }
            default:
                try rejectUnexpectedKnownClientMessage(type)
            }
        }
    }
}
