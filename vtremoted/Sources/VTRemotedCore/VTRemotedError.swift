import Foundation

public enum VTRemotedError: Error, CustomStringConvertible, Sendable {
    case protocolViolation(String)
    case ioError(code: Int32, message: String)
    case unsupported(String)
    case videoToolboxUnavailable

    public var description: String {
        switch self {
        case let .protocolViolation(msg):
            "Protocol violation: \(msg)"
        case let .ioError(code, message):
            "I/O error \(code): \(message)"
        case let .unsupported(msg):
            "Unsupported: \(msg)"
        case .videoToolboxUnavailable:
            "VideoToolbox is unavailable on this platform"
        }
    }
}
