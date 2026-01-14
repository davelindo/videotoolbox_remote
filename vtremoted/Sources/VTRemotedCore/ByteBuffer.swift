import Foundation

public struct ByteWriter: Sendable {
    public private(set) var data = Data()

    public init(reserveCapacity: Int = 0) {
        data.reserveCapacity(reserveCapacity)
    }

    public mutating func write(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeBE(_ value: UInt16) {
        var valueCopy = value.bigEndian
        withUnsafeBytes(of: &valueCopy) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE(_ value: UInt32) {
        var valueCopy = value.bigEndian
        withUnsafeBytes(of: &valueCopy) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE(_ value: UInt64) {
        var valueCopy = value.bigEndian
        withUnsafeBytes(of: &valueCopy) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeLengthPrefixedUTF8(_ string: String) {
        let bytes = string.data(using: .utf8) ?? Data()
        writeBE(UInt16(clamping: bytes.count))
        write(bytes)
    }
}

public struct ByteReader: Sendable {
    private let data: Data
    public private(set) var index: Int

    public init(_ data: Data, index: Int = 0) {
        self.data = data
        self.index = index
    }

    public var remaining: Int { data.count - index }

    public mutating func readUInt8() throws -> UInt8 {
        guard index + 1 <= data.count else {
            throw VTRemotedError.protocolViolation("unexpected EOF")
        }
        defer { index += 1 }
        return data[index]
    }

    public mutating func readBEUInt16() throws -> UInt16 {
        guard index + 2 <= data.count else { throw VTRemotedError.protocolViolation("unexpected EOF") }
        let val = data.withUnsafeBytes { ptr in
            // Direct load if aligned, but manual reconstruction is safer for alignment/endianness.
            // Data is contiguous.
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let byte0 = UInt16(base[index])
            let byte1 = UInt16(base[index + 1])
            return (byte0 << 8) | byte1
        }
        index += 2
        return val
    }

    public mutating func readBEUInt32() throws -> UInt32 {
        guard index + 4 <= data.count else { throw VTRemotedError.protocolViolation("unexpected EOF") }
        let val = data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let byte0 = UInt32(base[index])
            let byte1 = UInt32(base[index + 1])
            let byte2 = UInt32(base[index + 2])
            let byte3 = UInt32(base[index + 3])
            return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
        }
        index += 4
        return val
    }

    public mutating func readBEUInt64() throws -> UInt64 {
        guard index + 8 <= data.count else { throw VTRemotedError.protocolViolation("unexpected EOF") }
        let val = data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let byte0 = UInt64(base[index])
            let byte1 = UInt64(base[index + 1])
            let byte2 = UInt64(base[index + 2])
            let byte3 = UInt64(base[index + 3])
            let byte4 = UInt64(base[index + 4])
            let byte5 = UInt64(base[index + 5])
            let byte6 = UInt64(base[index + 6])
            let byte7 = UInt64(base[index + 7])
            return (byte0 << 56) | (byte1 << 48) | (byte2 << 40) | (byte3 << 32) |
                (byte4 << 24) | (byte5 << 16) | (byte6 << 8) | byte7
        }
        index += 8
        return val
    }

    public mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative length")
        }
        guard index + count <= data.count else {
            throw VTRemotedError.protocolViolation("unexpected EOF")
        }
        defer { index += count }
        return data.subdata(in: index ..< (index + count))
    }

    public mutating func readLengthPrefixedUTF8() throws -> String {
        let length = try Int(readBEUInt16())
        let bytes = try readBytes(count: length)
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}
