import Foundation

public struct Arguments: Equatable, Sendable {
    public var listen: String = "0.0.0.0:5555"
    public var token: String = ""
    public var logLevel: LogLevel = .info
    public var once: Bool = false

    public init() {}

    public static func parse(_ argv: [String]) -> Arguments {
        var args = Arguments()
        var it = argv.makeIterator()
        _ = it.next()
        while let arg = it.next() {
            switch arg {
            case "--listen":
                if let v = it.next() { args.listen = v }
            case "--token":
                if let v = it.next() { args.token = v }
            case "--log-level":
                if let v = it.next() {
                    let lower = v.lowercased()
                    if let n = Int(lower), let lvl = LogLevel(rawValue: n) {
                        args.logLevel = lvl
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
