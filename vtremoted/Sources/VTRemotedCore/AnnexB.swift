import Foundation

public enum AnnexB {
    public static func stripAtomHeaderIfPresent(_ data: Data, fourCC: String) -> Data {
        guard data.count >= 8 else { return data }
        let type = data.subdata(in: 4..<8)
        if String(data: type, encoding: .ascii) == fourCC {
            return data.subdata(in: 8..<data.count)
        }
        return data
    }

    public static func splitNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0
        var start: Int? = nil

        func commit(until end: Int) {
            guard let s = start, end > s else { return }
            units.append(Data(bytes[s..<end]))
        }

        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                commit(until: i)
                start = i + 3
                i += 3
                continue
            }
            if i + 4 < bytes.count,
               bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                commit(until: i)
                start = i + 4
                i += 4
                continue
            }
            i += 1
        }

        if start != nil {
            commit(until: bytes.count)
        } else {
            units.append(data)
        }
        return units
    }

    public static func toLengthPrefixed(_ annexB: Data, lengthSize: Int) -> Data {
        precondition((1...4).contains(lengthSize), "lengthSize must be 1...4")
        let units = splitNALUnits(annexB)
        var out = Data()
        out.reserveCapacity(annexB.count)
        for unit in units {
            let len = unit.count
            var prefix = [UInt8](repeating: 0, count: lengthSize)
            for i in 0..<lengthSize {
                let shift = (lengthSize - 1 - i) * 8
                prefix[i] = UInt8((len >> shift) & 0xFF)
            }
            out.append(contentsOf: prefix)
            out.append(unit)
        }
        return out
    }
}
