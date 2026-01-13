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
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE(_ value: UInt32) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    public mutating func writeBE(_ value: UInt64) {
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
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
        let bytes = try readBytes(count: 2)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    public mutating func readBEUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func readBEUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw VTRemotedError.protocolViolation("negative length")
        }
        guard index + count <= data.count else {
            throw VTRemotedError.protocolViolation("unexpected EOF")
        }
        defer { index += count }
        return data.subdata(in: index..<(index + count))
    }

    public mutating func readLengthPrefixedUTF8() throws -> String {
        let length = Int(try readBEUInt16())
        let bytes = try readBytes(count: length)
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}
