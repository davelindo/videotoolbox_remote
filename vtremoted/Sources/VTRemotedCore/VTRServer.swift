import Foundation

public final class VTRServer {
    private let listenAddress: String
    private let expectedToken: String
    private let once: Bool
    private let logger: Logger

    public init(arguments: Arguments, logger: Logger = .shared) {
        listenAddress = arguments.listen
        expectedToken = arguments.token
        once = arguments.once
        self.logger = logger
    }

    public func run() throws {
        let (ipAddress, port) = try parseListenAddress(listenAddress)

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

            logger.info("ACCEPT fd=\(clientFd)")
            if once {
                handleClient(fd: clientFd)
                return
            }
            let token = expectedToken
            DispatchQueue.global().async {
                let connection = VTRWireConnection(fd: clientFd)
                let handler = VTRClientHandler(io: connection, expectedToken: token)
                handler.run()
                close(clientFd)
            }
        }
    }

    private func handleClient(fd clientFd: Int32) {
        let connection = VTRWireConnection(fd: clientFd)
        let handler = VTRClientHandler(io: connection, expectedToken: expectedToken, logger: logger)
        handler.run()
        close(clientFd)
    }

    private func parseListenAddress(_ addressString: String) throws -> (ip: String, port: UInt16) {
        let parts = addressString.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else {
            throw VTRemotedError.protocolViolation("invalid listen address")
        }
        return (String(parts[0]), port)
    }
}
