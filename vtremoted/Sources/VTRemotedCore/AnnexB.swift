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
        var units: [Data] = []
        var index = 0
        var startPos: Int?
        let count = data.count

        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            func commit(until endPos: Int) {
                if let start = startPos, endPos > start {
                    units.append(data.subdata(in: start ..< endPos))
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
                units.append(data.subdata(in: start ..< count))
            }
        } else {
            units.append(data)
        }
        return units
    }

    public static func toLengthPrefixed(_ annexB: Data, lengthSize: Int) -> Data {
        precondition((1 ... 4).contains(lengthSize), "lengthSize must be 1...4")
        let units = splitNALUnits(annexB)
        
        // Calculate total size
        let totalSize = units.reduce(0) { $0 + lengthSize + $1.count }
        var out = Data(count: totalSize)
        
        var offset = 0
        out.withUnsafeMutableBytes { outRaw in
             guard let outBase = outRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
             
             for unit in units {
                 let len = unit.count
                 // Write length prefix
                 for idx in 0 ..< lengthSize {
                     let shift = (lengthSize - 1 - idx) * 8
                     outBase[offset + idx] = UInt8((len >> shift) & 0xFF)
                 }
                 offset += lengthSize
                 
                 // Copy NAL unit
                 unit.withUnsafeBytes { inRaw in
                     if let from = inRaw.baseAddress {
                        // UnsafeRawPointer to UnsafeMutableRawPointer copy
                        // We need to cast destinations to raw for memcpy or use assign
                        // But since we have specific pointers let's use memcpy which is available in Darwin
                        memcpy(outBase + offset, from, len)
                     }
                 }
                 offset += len
             }
        }
        return out
    }
}
