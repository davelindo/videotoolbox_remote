import Foundation

public struct Arguments: Equatable, Sendable {
    public var listen: String = "0.0.0.0:5555"
    public var token: String = ""
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
