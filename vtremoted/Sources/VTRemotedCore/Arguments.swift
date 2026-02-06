import Foundation

public struct Arguments: Equatable, Sendable {
    // Safer-by-default: require an explicit opt-in to bind publicly.
    public var listen: String = "127.0.0.1:5555"

    // Auth: prefer token via env/file (so it doesn't appear in process listings).
    public var token: String = ""
    public var tokenFile: String = ""
    public var tokenEnv: String = ""

    // Concurrency and IO limits
    public var maxSessions: Int = 4
    public var handshakeTimeoutSeconds: Int = 10
    public var idleTimeoutSeconds: Int = 60
    public var maxMessageBytes: Int = 256 * 1024 * 1024

    public var logLevel: LogLevel = .info
    public var once: Bool = false

    public init() {}

    public static func parse(_ argv: [String]) -> Arguments {
        var args = Arguments()
        var iterator = argv.makeIterator()
        _ = iterator.next()
        while let arg = iterator.next() {
            switch arg {
            case "--listen":
                if let value = iterator.next() { args.listen = value }
            case "--token":
                if let value = iterator.next() { args.token = value }
            case "--token-file":
                if let value = iterator.next() { args.tokenFile = value }
            case "--token-env":
                if let value = iterator.next() { args.tokenEnv = value }
            case "--max-sessions":
                if let value = iterator.next(), let n = Int(value), n > 0 { args.maxSessions = n }
            case "--handshake-timeout":
                if let value = iterator.next(), let n = Int(value), n > 0 { args.handshakeTimeoutSeconds = n }
            case "--idle-timeout":
                if let value = iterator.next(), let n = Int(value), n > 0 { args.idleTimeoutSeconds = n }
            case "--max-message-bytes":
                if let value = iterator.next(), let n = Int(value), n > 0 { args.maxMessageBytes = n }
            case "--log-level":
                if let value = iterator.next() {
                    let lower = value.lowercased()
                    if let levelInt = Int(lower), let level = LogLevel(rawValue: levelInt) {
                        args.logLevel = level
                    } else if lower == "debug" {
                        args.logLevel = .debug
                    } else if lower == "info" {
                        args.logLevel = .info
                    } else if lower == "error" {
                        args.logLevel = .error
                    }
                }
            case "--once":
                args.once = true
            default:
                break
            }
        }
        return args
    }
}
