import Foundation

public struct ByteWriter: Sendable {
    public private(set) var data = Data()

    public init(reserveCapacity: Int = 0) {
        data.reserveCapacity(reserveCapacity)
    }

    public mutating func write(_ value: UInt8) {
        data.append(value)
    }

    private mutating func writeBigEndian<T: FixedWidthInteger>(_ value: T) {
        var valueCopy = value.bigEndian
        withUnsafeBytes(of: &valueCopy) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE(_ value: UInt16) {
        writeBigEndian(value)
    }

    public mutating func writeBE(_ value: UInt32) {
        writeBigEndian(value)
    }

    public mutating func writeBE(_ value: UInt64) {
        writeBigEndian(value)
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
    
    /// Validates and advances the read position by `count` bytes.
    /// Returns the start index of the consumed range.
    private mutating func consumeBytes(_ count: Int) throws -> Int {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative length")
        }
        guard index + count <= data.count else {
            throw VTRemotedError.protocolViolation("unexpected EOF")
        }
        let startIdx = index
        index += count
        return startIdx
    }
    
    /// Returns the byte range for a slice without copying.
    /// Advances the read position by `count` bytes.
    /// Use with the underlying Data's withUnsafeBytes for zero-copy access.
    public mutating func sliceRange(count: Int) throws -> Range<Int> {
        let startIdx = try consumeBytes(count)
        return startIdx ..< (startIdx + count)
    }

    private mutating func readBigEndian(byteCount: Int) throws -> UInt64 {
        let startIdx = try consumeBytes(byteCount)
        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var value: UInt64 = 0
            for offset in 0 ..< byteCount {
                value = (value << 8) | UInt64(base[startIdx + offset])
            }
            return value
        }
    }

    public mutating func readUInt8() throws -> UInt8 {
        let startIdx = try consumeBytes(1)
        return data[startIdx]
    }

    public mutating func readBEUInt16() throws -> UInt16 {
        UInt16(try readBigEndian(byteCount: 2))
    }

    public mutating func readBEUInt32() throws -> UInt32 {
        UInt32(try readBigEndian(byteCount: 4))
    }

    public mutating func readBEUInt64() throws -> UInt64 {
        try readBigEndian(byteCount: 8)
    }

    public mutating func readBytes(count: Int) throws -> Data {
        let range = try sliceRange(count: count)
        return data.subdata(in: range)
    }

    public mutating func readLengthPrefixedUTF8() throws -> String {
        let length = try Int(readBEUInt16())
        let bytes = try readBytes(count: length)
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}
