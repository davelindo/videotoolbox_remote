import Foundation

final class StubCodecSession: CodecSession {
    private struct PacketEnvelope {
        let pts: UInt64
        let dts: UInt64
        let dur: UInt64
    }

    private let send: MessageSender
    private var config: SessionConfiguration?
    private let timestampTracker = TimestampTracker()

    init(sender: @escaping MessageSender) {
        send = sender
    }

    func configure(_ configuration: SessionConfiguration) throws -> Data {
        config = configuration
        let enforceMonotonicPts = configuration.options.maxBFrames <= 0
        timestampTracker.reset(enforceMonotonicPts: enforceMonotonicPts)
        return Data()
    }

    private func maybeDecompress(_ data: Data, expectedSize: Int, compressionMode: Int) throws -> Data {
        switch compressionMode {
        case 1:
            guard let decoded = LZ4Codec.decompress(data, expectedSize: expectedSize) else {
                throw VTRemotedError.protocolViolation("LZ4 decode failed")
            }
            return decoded
        case 2:
            guard let decoded = ZstdCodec.decompress(data, expectedSize: expectedSize) else {
                throw VTRemotedError.protocolViolation("Zstd decode failed")
            }
            return decoded
        default:
            return data
        }
    }

    private func maybeCompress(_ data: Data, compressionMode: Int) throws -> Data {
        switch compressionMode {
        case 1:
            guard let compressed = LZ4Codec.compress(data) else {
                throw VTRemotedError.protocolViolation("LZ4 compress failed")
            }
            return compressed
        case 2:
            guard let compressed = ZstdCodec.compress(data) else {
                throw VTRemotedError.protocolViolation("Zstd compress failed")
            }
            return compressed
        default:
            return data
        }
    }

    private func decodePacketEnvelope(_ payload: Data) throws -> PacketEnvelope {
        var reader = ByteReader(payload)
        let pts = try reader.readBEUInt64()
        let dts = try reader.readBEUInt64()
        let dur = try reader.readBEUInt64()
        _ = try reader.readBEUInt32() // isKey
        let dataLen = try Int(reader.readBEUInt32())
        _ = try reader.readBytes(count: dataLen)
        return PacketEnvelope(pts: pts, dts: dts, dur: dur)
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
            let planeData = try maybeDecompress(
                raw,
                expectedSize: expectedSize,
                compressionMode: configuration.options.wireCompression
            )
            planes.append(Plane(stride: stride, height: height, data: planeData))
        }

        let digest = planes[0].data.prefix(16)
        var annexB = Data([0x00, 0x00, 0x00, 0x01])
        annexB.append(digest)

        // Process timestamps to ensure monotonicity.
        let result = timestampTracker.process(ptsTicks: pts, dtsTicks: pts)
        let adjustedPts: Int64
        let dts: Int64
        switch result {
        case .emit(let ptsValue, let dtsValue, _):
            adjustedPts = ptsValue
            dts = dtsValue
        }

        var writer = ByteWriter()
        writer.writeBE(UInt64(bitPattern: adjustedPts))
        writer.writeBE(UInt64(bitPattern: dts))
        writer.writeBE(UInt64(bitPattern: dur))
        let isKey = (flags & 1) != 0
        writer.writeBE(UInt32(isKey ? 1 : 0))
        writer.writeBE(UInt32(annexB.count))
        writer.write(annexB)

        try send(.packet, [writer.data])
    }

    func handlePacketMessage(_ payload: Data) throws {
        guard let configuration = config else { throw VTRemotedError.protocolViolation("PACKET before CONFIGURE") }
        guard configuration.mode == .decode || configuration.mode == .transcode else { return }
        let packet = try decodePacketEnvelope(payload)

        if configuration.mode == .transcode {
            var writer = ByteWriter()
            writer.writeBE(packet.pts)
            writer.writeBE(packet.dts)
            writer.writeBE(packet.dur)
            writer.writeBE(UInt32(1))
            writer.writeBE(UInt32(4))
            writer.write(Data([0x00, 0x00, 0x00, 0x01]))
            try send(.packet, [writer.data])
            return
        }

        let bytesPerSample = (configuration.pixelFormat == 2) ? 2 : 1
        let yStride = configuration.width * bytesPerSample
        let uvStride = configuration.width * bytesPerSample
        let yHeight = configuration.height
        let uvHeight = configuration.height / 2
        let yBytes = yStride * yHeight
        let uvBytes = uvStride * uvHeight

        let yPlane = try maybeCompress(Data(count: yBytes), compressionMode: configuration.options.wireCompression)
        let uvPlane = try maybeCompress(Data(count: uvBytes), compressionMode: configuration.options.wireCompression)

        var writer = ByteWriter()
        writer.writeBE(packet.pts)
        writer.writeBE(packet.dur)
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
