import Foundation

public enum VTRemotedError: Error, CustomStringConvertible, Sendable {
    case protocolViolation(String)
    case ioError(code: Int32, message: String)
    case unsupported(String)
    case videoToolboxUnavailable

    public var description: String {
        switch self {
        case .protocolViolation(let msg):
            return "Protocol violation: \(msg)"
        case .ioError(let code, let message):
            return "I/O error \(code): \(message)"
        case .unsupported(let msg):
            return "Unsupported: \(msg)"
        case .videoToolboxUnavailable:
            return "VideoToolbox is unavailable on this platform"
        }
    }
}
