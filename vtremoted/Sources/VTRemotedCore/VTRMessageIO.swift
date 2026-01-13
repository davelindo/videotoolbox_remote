import Foundation

public protocol VTRMessageIO: AnyObject, Sendable {
    func readMessage(timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data)
    func send(type: VTRMessageType, body: Data) throws
}

extension VTRWireConnection: VTRMessageIO {
    // Conformance is satisfied by `readMessage(timeoutSeconds:)` and `send(type:body:)`.
}
