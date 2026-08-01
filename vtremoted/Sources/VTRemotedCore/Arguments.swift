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
    public var parseError: String = ""

    public init() {}

    public static let version = "0.7.0"

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
        var index = 1

        func value(after option: String) -> String? {
            guard index + 1 < argv.count else {
                args.parseError = "missing value for \(option)"
                return nil
            }
            index += 1
            return argv[index]
        }

        func positiveInt(after option: String, maximum: Int? = nil) -> Int? {
            guard let raw = value(after: option) else { return nil }
            guard let parsed = Int(raw), parsed > 0,
                  maximum.map({ parsed <= $0 }) ?? true
            else {
                args.parseError = "invalid value for \(option): \(raw)"
                return nil
            }
            return parsed
        }

        func nonEmptyValue(after option: String) -> String? {
            guard let parsed = value(after: option) else { return nil }
            guard !parsed.isEmpty else {
                args.parseError = "invalid value for \(option)"
                return nil
            }
            return parsed
        }

        while index < argv.count {
            let arg = argv[index]
            switch arg {
            case "--listen":
                guard let parsed = nonEmptyValue(after: arg) else { return args }
                args.listen = parsed
            case "--token":
                guard let parsed = value(after: arg) else { return args }
                args.token = parsed
            case "--token-file":
                guard let parsed = nonEmptyValue(after: arg) else { return args }
                args.tokenFile = parsed
            case "--token-env":
                guard let parsed = nonEmptyValue(after: arg) else { return args }
                args.tokenEnv = parsed
            case "--max-sessions":
                guard let parsed = positiveInt(after: arg) else { return args }
                args.maxSessions = parsed
            case "--handshake-timeout":
                guard let parsed = positiveInt(after: arg) else { return args }
                args.handshakeTimeoutSeconds = parsed
            case "--idle-timeout":
                guard let parsed = positiveInt(after: arg) else { return args }
                args.idleTimeoutSeconds = parsed
            case "--max-message-bytes":
                guard let parsed = positiveInt(after: arg, maximum: Int(UInt32.max)) else { return args }
                args.maxMessageBytes = parsed
            case "--log-level":
                guard let raw = value(after: arg) else { return args }
                let lower = raw.lowercased()
                if let levelInt = Int(lower), let level = LogLevel(rawValue: levelInt) {
                    args.logLevel = level
                } else if lower == "debug" {
                    args.logLevel = .debug
                } else if lower == "info" {
                    args.logLevel = .info
                } else if lower == "error" {
                    args.logLevel = .error
                } else {
                    args.parseError = "invalid value for \(arg): \(raw)"
                    return args
                }
            case "--once":
                args.once = true
            case "-h", "--help":
                args.showHelp = true
            case "--version":
                args.showVersion = true
            default:
                args.parseError = "unknown argument: \(arg)"
                return args
            }
            index += 1
        }
        return args
    }
}
