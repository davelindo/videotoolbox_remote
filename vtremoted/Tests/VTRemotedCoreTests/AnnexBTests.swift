@testable import VTRemotedCore
import XCTest

final class AnnexBTests: XCTestCase {
    func testStripAtomHeaderIfPresent() {
        var atomData = Data()
        atomData.append(contentsOf: [0, 0, 0, 16])
        atomData.append("avcC".data(using: .ascii)!)
        atomData.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])

        let stripped = AnnexB.stripAtomHeaderIfPresent(atomData, fourCC: "avcC")
        XCTAssertEqual(stripped, Data([1, 2, 3, 4, 5, 6, 7, 8]))

        let unchanged = AnnexB.stripAtomHeaderIfPresent(atomData, fourCC: "hvcC")
        XCTAssertEqual(unchanged, atomData)
    }

    func testSplitNALUnits() {
        let nal1 = Data([0x65, 1, 2, 3])
        let nal2 = Data([0x41, 4, 5])
        var annex = Data([0, 0, 0, 1])
        annex.append(nal1)
        annex.append(contentsOf: [0, 0, 1])
        annex.append(nal2)

        let units = AnnexB.splitNALUnits(annex)
        XCTAssertEqual(units, [nal1, nal2])
    }

    func testToLengthPrefixed() {
        let nal = Data([0x65, 0xAA, 0xBB])
        var annex = Data([0, 0, 0, 1])
        annex.append(nal)
        let lengthPrefixed = AnnexB.toLengthPrefixed(annex, lengthSize: 4)
        XCTAssertEqual(lengthPrefixed.prefix(4), Data([0, 0, 0, 3]))
        XCTAssertEqual(lengthPrefixed.dropFirst(4), nal)
    }

    func testPooledConversionOfBorrowedMixedStartCodes() {
        let packet = Data([0xFF, 0, 0, 0, 1, 0x65, 0xAA, 0, 0, 1, 0x41, 0xBB, 0xCC, 0xFF])
        let pool = RawBufferPool()
        for lengthSize in 1...4 {
            let converted = packet.withUnsafeBytes { raw in
                AnnexB.toLengthPrefixed(UnsafeRawBufferPointer(rebasing: raw[1..<13]),
                                        lengthSize: lengthSize, pool: pool)
            }
            let padding = [UInt8](repeating: 0, count: lengthSize - 1)
            let expected = padding + [2, 0x65, 0xAA] + padding + [3, 0x41, 0xBB, 0xCC]
            XCTAssertEqual(converted, Data(expected))
        }
    }

    func testLengthPrefixedNALWithoutStartCode() {
        let nal = Data([0x41, 0xAA, 0xBB])
        XCTAssertEqual(AnnexB.toLengthPrefixed(nal, lengthSize: 4), Data([0, 0, 0, 3, 0x41, 0xAA, 0xBB]))
    }
}
