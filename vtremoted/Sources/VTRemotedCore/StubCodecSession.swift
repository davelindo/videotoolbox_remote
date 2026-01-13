import Foundation

final class StubCodecSession: CodecSession {
    private let send: MessageSender
    private var config: SessionConfiguration?

    init(sender: @escaping MessageSender) {
        self.send = sender
    }

    func configure(_ configuration: SessionConfiguration) throws -> Data {
        self.config = configuration
        return Data()
    }

    func handleFrameMessage(_ payload: Data) throws {
        guard let config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }
        guard config.mode == .encode else { return }

        var r = ByteReader(payload)
        let pts = Int64(bitPattern: try r.readBEUInt64())
        let dur = Int64(bitPattern: try r.readBEUInt64())
        let flags = try r.readBEUInt32()
        let planeCount = try r.readUInt8()
        guard planeCount == 2 else {
            throw VTRemotedError.protocolViolation("expected 2 planes")
        }

        struct Plane {
            let stride: Int
            let height: Int
            let data: Data
        }

        var planes: [Plane] = []
        planes.reserveCapacity(2)
        for _ in 0..<2 {
            let stride = Int(try r.readBEUInt32())
            let height = Int(try r.readBEUInt32())
            let len = Int(try r.readBEUInt32())
            let raw = try r.readBytes(count: len)

            let expectedSize = max(0, stride * height)
            let planeData: Data
            if config.options.wireCompression == 1 {
                guard let decoded = LZ4Codec.decompress(raw, expectedSize: expectedSize) else {
                    throw VTRemotedError.protocolViolation("LZ4 decode failed")
                }
                planeData = decoded
            } else {
                planeData = raw
            }
            planes.append(Plane(stride: stride, height: height, data: planeData))
        }

        let digest = planes[0].data.prefix(16)
        var annexB = Data([0x00, 0x00, 0x00, 0x01])
        annexB.append(digest)

        var w = ByteWriter()
        w.writeBE(UInt64(bitPattern: pts)) // pts
        w.writeBE(UInt64(bitPattern: pts)) // dts
        w.writeBE(UInt64(bitPattern: dur)) // duration
        let isKey = (flags & 1) != 0
        w.writeBE(UInt32(isKey ? 1 : 0))
        w.writeBE(UInt32(annexB.count))
        w.write(annexB)

        try send(.packet, w.data)
    }

    func handlePacketMessage(_ payload: Data) throws {
        guard let config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
        guard config.mode == .decode else { return }

        var r = ByteReader(payload)
        let pts = try r.readBEUInt64()
        _ = try r.readBEUInt64() // dts
        let dur = try r.readBEUInt64()
        _ = try r.readBEUInt32() // isKey
        let dataLen = Int(try r.readBEUInt32())
        _ = try r.readBytes(count: dataLen)

        let bytesPerSample = (config.pixelFormat == 2) ? 2 : 1
        let yStride = config.width * bytesPerSample
        let uvStride = config.width * bytesPerSample
        let yHeight = config.height
        let uvHeight = config.height / 2
        let yBytes = yStride * yHeight
        let uvBytes = uvStride * uvHeight

        func maybeCompress(_ data: Data) throws -> Data {
            guard config.options.wireCompression == 1 else { return data }
            guard let compressed = LZ4Codec.compress(data) else {
                throw VTRemotedError.protocolViolation("LZ4 compress failed")
            }
            return compressed
        }

        let yPlane = try maybeCompress(Data(count: yBytes))
        let uvPlane = try maybeCompress(Data(count: uvBytes))

        var w = ByteWriter()
        w.writeBE(pts)
        w.writeBE(dur)
        w.writeBE(UInt32(0))
        w.write(UInt8(2))

        w.writeBE(UInt32(yStride))
        w.writeBE(UInt32(yHeight))
        w.writeBE(UInt32(yPlane.count))
        w.write(yPlane)

        w.writeBE(UInt32(uvStride))
        w.writeBE(UInt32(uvHeight))
        w.writeBE(UInt32(uvPlane.count))
        w.write(uvPlane)

        try send(.frame, w.data)
    }

    func flush() throws {}

    func shutdown() {}
}
