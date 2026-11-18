import Foundation

public enum AnnexB {
    public static func stripAtomHeaderIfPresent(_ data: Data, fourCC: String) -> Data {
        guard data.count >= 8 else { return data }
        let type = data.subdata(in: 4 ..< 8)
        if String(data: type, encoding: .ascii) == fourCC {
            return data.subdata(in: 8 ..< data.count)
        }
        return data
    }

    public static func splitNALUnits(_ data: Data) -> [Data] {
        data.withUnsafeBytes { raw in
            nalUnitRanges(raw).map { range in
                range.isEmpty ? Data() : Data(bytes: raw.baseAddress!.advanced(by: range.lowerBound), count: range.count)
            }
        }
    }

    static func h264ParameterSetID(_ unit: Data) -> Int? {
        guard let header = unit.first else { return nil }
        let type = Int(header & 0x1F)
        guard type == 7 || type == 8 else { return nil }
        // The parameter-set ID is the first Exp-Golomb value (after the
        // profile, constraints and level bytes for SPS). Read only its prefix.
        var rbsp: [UInt8] = []
        var zeroRun = 0
        for byte in unit.dropFirst().prefix(12) {
            if zeroRun == 2, byte == 3 {
                zeroRun = 0
                continue
            }
            rbsp.append(byte)
            zeroRun = byte == 0 ? min(2, zeroRun + 1) : 0
        }
        var offset = type == 7 ? 24 : 0
        func popBit() -> Int {
            defer { offset += 1 }
            return Int((rbsp[offset / 8] >> (7 - (offset % 8))) & 1)
        }
        let bitCount = rbsp.count * 8
        var zeros = 0
        while offset < bitCount {
            if popBit() == 1 {
                guard offset + zeros <= bitCount else { return nil }
                var id = 0
                for _ in 0 ..< zeros { id = (id << 1) | popBit() }
                id += (1 << zeros) - 1
                guard id <= (type == 7 ? 31 : 255) else { return nil }
                return type * 256 + id
            }
            zeros += 1
            guard zeros <= 8 else { return nil }
        }
        return nil
    }

    static func nalUnitRanges(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>] {
        guard !bytes.isEmpty else { return [] }
        var units: [Range<Int>] = []
        var index = 0
        var startPos: Int?
        let count = bytes.count

        if let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {

            func commit(until endPos: Int) {
                if let start = startPos, endPos > start {
                    units.append(start ..< endPos)
                }
            }

            while index + 3 < count {
                // Check 0x000001
                if base[index] == 0, base[index + 1] == 0, base[index + 2] == 1 {
                    commit(until: index)
                    startPos = index + 3
                    index += 3
                    continue
                }
                // Check 0x00000001
                if index + 4 < count,
                   base[index] == 0, base[index + 1] == 0, base[index + 2] == 0, base[index + 3] == 1 {
                    commit(until: index)
                    startPos = index + 4
                    index += 4
                    continue
                }
                index += 1
            }
        }

        if startPos != nil {
            if let start = startPos, start < count {
                units.append(start ..< count)
            }
        } else {
            units.append(0 ..< count)
        }
        return units
    }

    public static func toLengthPrefixed(_ annexB: Data, lengthSize: Int) -> Data {
        precondition((1 ... 4).contains(lengthSize), "lengthSize must be 1...4")
        return annexB.withUnsafeBytes { source in
            let units = nalUnitRanges(source)
            let limit = UInt64(1) << (lengthSize * 8)
            guard units.allSatisfy({ UInt64($0.count) < limit }) else { return Data() }
            let totalSize = units.reduce(0) { $0 + lengthSize + $1.count }
            var out = Data(count: totalSize)
            out.withUnsafeMutableBytes { destination in
                writeLengthPrefixed(source, units: units, lengthSize: lengthSize, into: destination)
            }
            return out
        }
    }

    static func toLengthPrefixed(_ source: UnsafeRawBufferPointer, lengthSize: Int, pool: RawBufferPool) -> Data {
        precondition((1 ... 4).contains(lengthSize), "lengthSize must be 1...4")
        let units = nalUnitRanges(source)
        let limit = UInt64(1) << (lengthSize * 8)
        guard !units.isEmpty, units.allSatisfy({ UInt64($0.count) < limit }) else { return Data() }
        let totalSize = units.reduce(0) { $0 + lengthSize + $1.count }
        return pool.data(capacity: totalSize) { destination in
            writeLengthPrefixed(source, units: units, lengthSize: lengthSize, into: destination)
            return totalSize
        }!
    }

    private static func writeLengthPrefixed(_ source: UnsafeRawBufferPointer, units: [Range<Int>],
                                            lengthSize: Int, into destination: UnsafeMutableRawBufferPointer) {
        var offset = 0
        for unit in units {
            for index in 0 ..< lengthSize {
                let shift = (lengthSize - 1 - index) * 8
                destination[offset + index] = UInt8((unit.count >> shift) & 0xFF)
            }
            offset += lengthSize
            if !unit.isEmpty {
                memcpy(destination.baseAddress!.advanced(by: offset),
                       source.baseAddress!.advanced(by: unit.lowerBound), unit.count)
            }
            offset += unit.count
        }
    }
}
