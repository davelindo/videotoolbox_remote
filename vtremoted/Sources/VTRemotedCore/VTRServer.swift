import Foundation

private final class VTRSessionLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private(set) var activeSessions: Int = 0
    let maxSessions: Int

    init(maxSessions: Int) {
        self.maxSessions = max(1, maxSessions)
        semaphore = DispatchSemaphore(value: self.maxSessions)
    }

    func tryAcquire() -> Bool {
        if semaphore.wait(timeout: .now()) == .success {
            lock.lock()
            activeSessions += 1
            lock.unlock()
            return true
        }
        return false
    }

    func release() {
        lock.lock()
        activeSessions = max(0, activeSessions - 1)
        lock.unlock()
        semaphore.signal()
    }

    func snapshot() -> (maxSessions: Int, activeSessions: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (maxSessions: maxSessions, activeSessions: activeSessions)
    }
}

public final class VTRServer {
    private let listenAddress: String
    private let tokenArg: String
    private let tokenFile: String
    private let tokenEnv: String
    private let once: Bool
    private let logger: Logger
    private let maxSessions: Int
    private let handshakeTimeoutSeconds: Int
    private let idleTimeoutSeconds: Int
    private let maxMessageBytes: Int

    public init(arguments: Arguments, logger: Logger = .shared) {
        listenAddress = arguments.listen
        tokenArg = arguments.token
        tokenFile = arguments.tokenFile
        tokenEnv = arguments.tokenEnv
        once = arguments.once
        self.logger = logger
        maxSessions = max(1, arguments.maxSessions)
        handshakeTimeoutSeconds = max(1, arguments.handshakeTimeoutSeconds)
        idleTimeoutSeconds = max(1, arguments.idleTimeoutSeconds)
        maxMessageBytes = max(1, arguments.maxMessageBytes)
    }

    public func run() throws {
        let (ipAddress, port) = try parseListenAddress(listenAddress)
        let expectedToken = try resolveExpectedToken()
        let limiter = VTRSessionLimiter(maxSessions: maxSessions)
        let serverName = "vtremoted"
        let serverVersion = ProcessInfo.processInfo.environment["VTREMOTED_VERSION"] ?? "unknown"
        let serverCapabilities = ["h264", "hevc"]

        #if os(Linux)
            let socketType = Int32(SOCK_STREAM.rawValue)
        #else
            let socketType = SOCK_STREAM
        #endif
        let socketFd = socket(AF_INET, socketType, 0)
        guard socketFd >= 0 else {
            throw VTRemotedError.ioError(code: errno, message: "socket failed")
        }
        defer { close(socketFd) }

        var yes: Int32 = 1
        _ = setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // Set large buffers on listening socket BEFORE listen() for correct TCP Window Scale negotiation
        var bufSize: Int32 = 16 * 1024 * 1024
        _ = setsockopt(socketFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout.size(ofValue: bufSize)))
        _ = setsockopt(socketFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout.size(ofValue: bufSize)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(ipAddress))

        var addrCopy = addr
        let bindResult = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(socketFd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw VTRemotedError.ioError(code: errno, message: "bind failed")
        }
        guard listen(socketFd, 8) == 0 else {
            throw VTRemotedError.ioError(code: errno, message: "listen failed")
        }

        print("vtremoted listening on \(listenAddress)")

        while true {
            var caddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    accept(socketFd, saPtr, &len)
                }
            }
            if clientFd < 0 { continue }
            
            var noDelay: Int32 = 1
            _ = setsockopt(clientFd, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, 
                           socklen_t(MemoryLayout.size(ofValue: noDelay)))

#if !os(Linux)
            var noSigPipe: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
#endif

            var bufSize: Int32 = 16 * 1024 * 1024
            _ = setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout.size(ofValue: bufSize)))
            _ = setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout.size(ofValue: bufSize)))
            
            if let lowatValue = ProcessInfo.processInfo.environment["VTREMOTED_NOTSENT_LOWAT"],
               let lowat = Int32(lowatValue),
               lowat > 0 {
                var notSentLowat = lowat
                // 0x201 is TCP_NOTSENT_LOWAT on Darwin
                _ = setsockopt(clientFd, Int32(IPPROTO_TCP), 0x201, &notSentLowat,
                               socklen_t(MemoryLayout.size(ofValue: notSentLowat)))
            }

            if !limiter.tryAcquire() {
                let snap = limiter.snapshot()
                logger.info("BUSY reject fd=\(clientFd) active=\(snap.activeSessions)/\(snap.maxSessions)")
                rejectBusy(
                    fd: clientFd,
                    serverName: serverName,
                    serverVersion: serverVersion,
                    serverCapabilities: serverCapabilities,
                    limiter: limiter
                )
                continue
            }

            let snap = limiter.snapshot()
            logger.info("ACCEPT fd=\(clientFd) active=\(snap.activeSessions)/\(snap.maxSessions)")
            if once {
                handleClient(
                    fd: clientFd,
                    expectedToken: expectedToken,
                    serverName: serverName,
                    serverVersion: serverVersion,
                    serverCapabilities: serverCapabilities,
                    limiter: limiter
                )
                return
            }
            let token = expectedToken
            let logger = logger
            let handshakeTimeoutSeconds = handshakeTimeoutSeconds
            let idleTimeoutSeconds = idleTimeoutSeconds
            let maxMessageBytes = maxMessageBytes
            DispatchQueue.global().async {
                defer {
                    limiter.release()
                    close(clientFd)
                }
                let connection = VTRWireConnection(fd: clientFd)
                let handler = VTRClientHandler(
                    io: connection,
                    expectedToken: token,
                    logger: logger,
                    handshakeTimeoutSeconds: handshakeTimeoutSeconds,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    maxMessageBytes: maxMessageBytes,
                    serverName: serverName,
                    serverVersion: serverVersion,
                    serverCapabilities: serverCapabilities,
                    serverSessionSnapshot: { limiter.snapshot() }
                )
                handler.run()
            }
        }
    }

    private func handleClient(
        fd clientFd: Int32,
        expectedToken: String,
        serverName: String,
        serverVersion: String,
        serverCapabilities: [String],
        limiter: VTRSessionLimiter
    ) {
        defer {
            limiter.release()
            close(clientFd)
        }
        let connection = VTRWireConnection(fd: clientFd)
        let handler = VTRClientHandler(
            io: connection,
            expectedToken: expectedToken,
            logger: logger,
            handshakeTimeoutSeconds: handshakeTimeoutSeconds,
            idleTimeoutSeconds: idleTimeoutSeconds,
            maxMessageBytes: maxMessageBytes,
            serverName: serverName,
            serverVersion: serverVersion,
            serverCapabilities: serverCapabilities,
            serverSessionSnapshot: { limiter.snapshot() }
        )
        handler.run()
    }

    private func rejectBusy(
        fd clientFd: Int32,
        serverName: String,
        serverVersion: String,
        serverCapabilities: [String],
        limiter: VTRSessionLimiter
    ) {
        defer { close(clientFd) }
        let snap = limiter.snapshot()
        let ack = HelloAckResponse(
            status: 1, // busy
            serverName: serverName,
            serverVersion: serverVersion,
            capabilities: serverCapabilities,
            maxSessions: UInt16(clamping: snap.maxSessions),
            activeSessions: UInt16(clamping: snap.activeSessions)
        )
        let body = ack.encode()
        let connection = VTRWireConnection(fd: clientFd)
        try? connection.send(type: .helloAck, body: body)
    }

    private func resolveExpectedToken() throws -> String {
        if !tokenArg.isEmpty {
            return tokenArg
        }
        if !tokenFile.isEmpty {
            let token = try String(contentsOfFile: tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                throw VTRemotedError.protocolViolation("token-file is empty")
            }
            return token
        }
        if !tokenEnv.isEmpty {
            let token = (ProcessInfo.processInfo.environment[tokenEnv] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                throw VTRemotedError.protocolViolation("token-env \(tokenEnv) is not set")
            }
            return token
        }
        return ""
    }

    private func parseListenAddress(_ addressString: String) throws -> (ip: String, port: UInt16) {
        let parts = addressString.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw VTRemotedError.protocolViolation("invalid listen address")
        }
        return (String(parts[0]), port)
    }
}
