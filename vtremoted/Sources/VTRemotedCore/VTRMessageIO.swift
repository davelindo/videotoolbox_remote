import Foundation

public protocol VTRMessageIO: AnyObject, Sendable {
    func readMessage(pool: BufferPool?, timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data)
    func send(type: VTRMessageType, body: Data) throws
    func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws
}

extension VTRWireConnection: VTRMessageIO {
    // Conformance is satisfied by `readMessage(timeoutSeconds:)` and `send(type:body:)`.
}
