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
        let bytes = [UInt8](data)
        var units: [Data] = []
        var index = 0
        var startPos: Int?

        func commit(until endPos: Int) {
            if let start = startPos, endPos > start {
                units.append(Data(bytes[start ..< endPos]))
            }
        }

        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                commit(until: index)
                startPos = index + 3
                index += 3
                continue
            }
            if index + 4 < bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                commit(until: index)
                startPos = index + 4
                index += 4
                continue
            }
            index += 1
        }

        if startPos != nil {
            commit(until: bytes.count)
        } else {
            units.append(data)
        }
        return units
    }

    public static func toLengthPrefixed(_ annexB: Data, lengthSize: Int) -> Data {
        precondition((1 ... 4).contains(lengthSize), "lengthSize must be 1...4")
        let units = splitNALUnits(annexB)
        var out = Data()
        out.reserveCapacity(annexB.count)
        for unit in units {
            let len = unit.count
            var prefix = [UInt8](repeating: 0, count: lengthSize)
            for idx in 0 ..< lengthSize {
                let shift = (lengthSize - 1 - idx) * 8
                prefix[idx] = UInt8((len >> shift) & 0xFF)
            }
            out.append(contentsOf: prefix)
            out.append(unit)
        }
        return out
    }
}
