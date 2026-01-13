import Foundation

public protocol CodecSession: AnyObject {
    /// Called after CONFIGURE. Returns encoder extradata to include in CONFIGURE_ACK.
    func configure(_ configuration: SessionConfiguration) throws -> Data

    /// Handle a FRAME message (client->server) in encode mode.
    func handleFrameMessage(_ payload: Data) throws

    /// Handle a PACKET message (client->server) in decode mode.
    func handlePacketMessage(_ payload: Data) throws

    func flush() throws
    func shutdown()
}

public typealias MessageSender = (VTRMessageType, Data) throws -> Void

public enum CodecSessionFactory {
    public static func make(sender: @escaping MessageSender) -> CodecSession {
        #if canImport(VideoToolbox)
        return VideoToolboxCodecSession(sender: sender)
        #else
        return StubCodecSession(sender: sender)
        #endif
    }
}
