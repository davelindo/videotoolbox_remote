import Foundation

public protocol VTRMessageIO: AnyObject, Sendable {
    func readMessage(pool: BufferPool?, timeoutSeconds: Int) throws -> (header: VTRMessageHeader, body: Data)
    func send(type: VTRMessageType, body: Data) throws
    func sendMessage(type: VTRMessageType, bodyParts: [Data]) throws
}

/// Optional low-level streaming IO for hot paths (e.g. FRAME payloads).
///
/// `VTRMessageIO.readMessage` forces callers to materialize the whole payload in a `Data`.
/// For large FRAME messages this is a measurable cost. When available, higher layers can
/// read headers and stream plane bytes directly into their final destination buffers.
public protocol VTRStreamIO: VTRMessageIO {
    func readHeader(timeoutSeconds: Int) throws -> VTRMessageHeader
    func readBody(length: Int, pool: BufferPool?) throws -> Data
    func readExact(into buffer: inout Data, count: Int) throws
    func readExact(into buffer: UnsafeMutableRawPointer, count: Int) throws
    func skip(length: Int) throws
}

extension VTRWireConnection: VTRMessageIO {
    // Conformance is satisfied by `readMessage(timeoutSeconds:)` and `send(type:body:)`.
}
