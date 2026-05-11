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
    public var showHelp: Bool = false
    public var showVersion: Bool = false

    public init() {}

    public static let version = "0.4.1"

    public static let usage = """
    Usage: vtremoted [options]

    Options:
      --listen HOST:PORT          Address to listen on (default: 127.0.0.1:5555)
      --token TOKEN               Authentication token (prefer --token-file or --token-env)
      --token-file PATH           Read authentication token from a file
      --token-env VAR             Read authentication token from an environment variable
      --max-sessions N            Maximum concurrent sessions (default: 4)
      --handshake-timeout S       Handshake timeout in seconds (default: 10)
      --idle-timeout S            Idle timeout in seconds (default: 60)
      --max-message-bytes N       Maximum protocol message size (default: 268435456)
      --log-level LEVEL           error, info, debug, or numeric 0..2 (default: info)
      --once                      Handle one accepted connection, then exit
      --version                   Print version and exit
      -h, --help                  Print this help and exit
    """

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
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 { args.maxSessions = parsed }
            case "--handshake-timeout":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 {
                    args.handshakeTimeoutSeconds = parsed
                }
            case "--idle-timeout":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 { args.idleTimeoutSeconds = parsed }
            case "--max-message-bytes":
                if let value = iterator.next(), let parsed = Int(value), parsed > 0 { args.maxMessageBytes = parsed }
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
            case "-h", "--help":
                args.showHelp = true
            case "--version":
                args.showVersion = true
            default:
                break
            }
        }
        return args
    }
}
