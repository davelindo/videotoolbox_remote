import Foundation

public final class VTRClientHandler: @unchecked Sendable {
    private let messageIO: VTRMessageIO
    private let expectedToken: String
    private let logger: Logger
    public typealias SessionFactory = (@escaping MessageSender) -> CodecSession
    private let sessionFactory: SessionFactory

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
        sessionFactory: @escaping SessionFactory = CodecSessionFactory.make
    ) {
        self.messageIO = messageIO
        self.expectedToken = expectedToken
        self.logger = logger
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

    private func handshake() throws {
        let (header, payload) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: 10)
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

        let ack = HelloAckResponse(status: status, supportedCodecs: ["h264", "hevc"], warnings: 0)
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
        let (header, payload) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: 10)
        defer { inputBufferPool.return(payload) }
        stats.bytesIn += Int64(VTRProtocol.headerSize + payload.count)
        guard header.type == VTRMessageType.configure.rawValue else {
            throw VTRemotedError.protocolViolation("expected CONFIGURE")
        }
        let request = try ConfigureRequest.decode(payload)
        let config = try SessionConfiguration(codec: codec, request: request)

        let wireComp = config.options.wireCompression
        if wireComp != 0, wireComp != 1, wireComp != 2 {
            let err = ErrorResponse(
                code: 1,
                message: "unsupported wire_compression=\(wireComp)"
            )
            let body = err.encode()
            stats.bytesOut += Int64(VTRProtocol.headerSize + body.count)
            try messageIO.send(type: .error, body: body)
            throw VTRemotedError.unsupported("wire_compression")
        }

        logger.info(
            "CONFIGURE req mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) " +
                "\(config.width)x\(config.height) " +
                "pix=\(config.pixelFormat) tb=\(config.timebase.num)/\(config.timebase.den) " +
                "fr=\(config.frameRate.num)/\(config.frameRate.den) br=\(config.options.bitrate) " +
                "gop=\(config.options.gop) wc=\(config.options.wireCompression)"
        )

        let mode = config.mode
        let session = sessionFactory { [weak self] type, bodyParts in
            guard let self else { return }
            let totalCount = bodyParts.reduce(0) { $0 + $1.count }
            stats.bytesOut += Int64(VTRProtocol.headerSize + totalCount)
            if type == .packet { stats.packetsOut += 1; stats.recordOutput() }
            if type == .frame { stats.framesOut += 1 }
            stats.maybeReport(mode: mode, logger: logger, intervalSeconds: 0.25)
            try messageIO.sendMessage(type: type, bodyParts: bodyParts)
        }
        codecSession = session
        configuration = config

        let extradata = try session.configure(config)
        let resp = ConfigureAckResponse(status: 0, extradata: extradata, pixelFormat: config.pixelFormat, warnings: 0)
        let body = resp.encode()
        stats.bytesOut += Int64(VTRProtocol.headerSize + body.count)
        try messageIO.send(type: .configureAck, body: body)

        logger.info(
            "CONFIGURE ok mode=\(config.mode.rawValue) codec=\(config.codec.rawValue) " +
                "\(config.width)x\(config.height) " +
                "pixfmt=\(config.pixelFormat) tb=\(config.timebase.num)/\(config.timebase.den) " +
                "br=\(config.options.bitrate) " +
                "gop=\(config.options.gop) wc=\(config.options.wireCompression)"
        )
    }

    private func mainLoop() throws {
        guard let configuration, let codecSession else {
            throw VTRemotedError.protocolViolation("missing configuration")
        }

        while true {
            let (header, payload) = try messageIO.readMessage(pool: inputBufferPool, timeoutSeconds: 10)
            stats.bytesIn += Int64(VTRProtocol.headerSize + payload.count)
            stats.maybeReport(mode: configuration.mode, logger: logger, intervalSeconds: 0.25)
            guard let type = VTRMessageType(rawValue: header.type) else {
                inputBufferPool.return(payload)
                continue
            }

            switch type {
            case .frame:
                stats.framesIn += 1
                stats.recordSubmit()
                try codecSession.handleFrameMessage(payload)
                inputBufferPool.return(payload)
            case .packet:
                stats.packetsIn += 1
                try codecSession.handlePacketMessage(payload)
                inputBufferPool.return(payload)
            case .flush:
                try codecSession.flush()
                try messageIO.send(type: .done, body: Data())
                let msg = configuration.mode == .encode
                    ? "DONE client=\(clientName) frames=\(stats.framesIn) packets=\(stats.packetsOut)"
                    : "DONE client=\(clientName) packets=\(stats.packetsIn) frames=\(stats.framesOut)"
                logger.info(msg)
                inputBufferPool.return(payload)
                return
            case .ping:
                try messageIO.send(type: .pong, body: Data())
                inputBufferPool.return(payload)
            default:
                inputBufferPool.return(payload)
                break
            }
        }
    }
}
