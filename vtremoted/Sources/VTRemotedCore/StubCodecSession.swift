import Foundation

final class StubCodecSession: CodecSession {
    private let send: MessageSender
    private var config: SessionConfiguration?

    init(sender: @escaping MessageSender) {
        send = sender
    }

    func configure(_ configuration: SessionConfiguration) throws -> Data {
        config = configuration
        return Data()
    }

    func handleFrameMessage(_ payload: Data) throws {
        guard let configuration = config else { throw VTRemotedError.protocolViolation("FRAME before CONFIGURE") }
        guard configuration.mode == .encode else { return }

        var reader = ByteReader(payload)
        let pts = try Int64(bitPattern: reader.readBEUInt64())
        let dur = try Int64(bitPattern: reader.readBEUInt64())
        let flags = try reader.readBEUInt32()
        let planeCount = try reader.readUInt8()
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
        for _ in 0 ..< 2 {
            let stride = try Int(reader.readBEUInt32())
            let height = try Int(reader.readBEUInt32())
            let len = try Int(reader.readBEUInt32())
            let raw = try reader.readBytes(count: len)

            let expectedSize = max(0, stride * height)
            let planeData: Data
            if configuration.options.wireCompression == 1 {
                guard let decoded = LZ4Codec.decompress(raw, expectedSize: expectedSize) else {
                    throw VTRemotedError.protocolViolation("LZ4 decode failed")
                }
                planeData = decoded
            } else if configuration.options.wireCompression == 2 {
                guard let decoded = ZstdCodec.decompress(raw, expectedSize: expectedSize) else {
                    throw VTRemotedError.protocolViolation("Zstd decode failed")
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

        var writer = ByteWriter()
        writer.writeBE(UInt64(bitPattern: pts)) // pts
        writer.writeBE(UInt64(bitPattern: pts)) // dts
        writer.writeBE(UInt64(bitPattern: dur)) // duration
        let isKey = (flags & 1) != 0
        writer.writeBE(UInt32(isKey ? 1 : 0))
        writer.writeBE(UInt32(annexB.count))
        writer.write(annexB)

        try send(.packet, [writer.data])
    }

    func handlePacketMessage(_ payload: Data) throws {
        guard let configuration = config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
        guard configuration.mode == .decode else { return }

        var reader = ByteReader(payload)
        let pts = try reader.readBEUInt64()
        _ = try reader.readBEUInt64() // dts
        let dur = try reader.readBEUInt64()
        _ = try reader.readBEUInt32() // isKey
        let dataLen = try Int(reader.readBEUInt32())
        _ = try reader.readBytes(count: dataLen)

        let bytesPerSample = (configuration.pixelFormat == 2) ? 2 : 1
        let yStride = configuration.width * bytesPerSample
        let uvStride = configuration.width * bytesPerSample
        let yHeight = configuration.height
        let uvHeight = configuration.height / 2
        let yBytes = yStride * yHeight
        let uvBytes = uvStride * uvHeight

        func maybeCompress(_ data: Data) throws -> Data {
            if configuration.options.wireCompression == 1 {
                guard let compressed = LZ4Codec.compress(data) else {
                    throw VTRemotedError.protocolViolation("LZ4 compress failed")
                }
                return compressed
            } else if configuration.options.wireCompression == 2 {
                guard let compressed = ZstdCodec.compress(data) else {
                    throw VTRemotedError.protocolViolation("Zstd compress failed")
                }
                return compressed
            }
            return data
        }

        let yPlane = try maybeCompress(Data(count: yBytes))
        let uvPlane = try maybeCompress(Data(count: uvBytes))

        var writer = ByteWriter()
        writer.writeBE(pts)
        writer.writeBE(dur)
        writer.writeBE(UInt32(0))
        writer.write(UInt8(2))

        writer.writeBE(UInt32(yStride))
        writer.writeBE(UInt32(yHeight))
        writer.writeBE(UInt32(yPlane.count))
        writer.write(yPlane)

        writer.writeBE(UInt32(uvStride))
        writer.writeBE(UInt32(uvHeight))
        writer.writeBE(UInt32(uvPlane.count))
        writer.write(uvPlane)

        try send(.frame, [writer.data])
    }

    func flush() throws {}

    func shutdown() {}
}
