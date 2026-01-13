import Foundation

public final class VTRServer {
    private let listenAddress: String
    private let expectedToken: String
    private let once: Bool
    private let logger: Logger

    public init(arguments: Arguments, logger: Logger = .shared) {
        self.listenAddress = arguments.listen
        self.expectedToken = arguments.token
        self.once = arguments.once
        self.logger = logger
    }

    public func run() throws {
        let (ip, port) = try parseListenAddress(listenAddress)

        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, socketType, 0)
        guard fd >= 0 else {
            throw VTRemotedError.ioError(code: errno, message: "socket failed")
        }
        defer { close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(ip))

        var addrCopy = addr
        let bindResult = withUnsafePointer(to: &addrCopy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw VTRemotedError.ioError(code: errno, message: "bind failed")
        }
        guard listen(fd, 8) == 0 else {
            throw VTRemotedError.ioError(code: errno, message: "listen failed")
        }

        print("vtremoted listening on \(listenAddress)")

        while true {
            var caddr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    accept(fd, saPtr, &len)
                }
            }
            if cfd < 0 { continue }

            logger.info("ACCEPT fd=\(cfd)")
            if once {
                handleClient(fd: cfd)
                return
            }
            let token = expectedToken
            DispatchQueue.global().async {
                let connection = VTRWireConnection(fd: cfd)
                let handler = VTRClientHandler(io: connection, expectedToken: token)
                handler.run()
                close(cfd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        let connection = VTRWireConnection(fd: fd)
        let handler = VTRClientHandler(io: connection, expectedToken: expectedToken, logger: logger)
        handler.run()
        close(fd)
    }

    private func parseListenAddress(_ s: String) throws -> (ip: String, port: UInt16) {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw VTRemotedError.protocolViolation("invalid listen address")
        }
        return (String(parts[0]), port)
    }
}
