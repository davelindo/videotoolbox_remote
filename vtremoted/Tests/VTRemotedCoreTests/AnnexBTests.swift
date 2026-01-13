import XCTest
@testable import VTRemotedCore

final class AnnexBTests: XCTestCase {
    func testStripAtomHeaderIfPresent() {
        var d = Data()
        d.append(contentsOf: [0, 0, 0, 16])
        d.append("avcC".data(using: .ascii)!)
        d.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])

        let stripped = AnnexB.stripAtomHeaderIfPresent(d, fourCC: "avcC")
        XCTAssertEqual(stripped, Data([1, 2, 3, 4, 5, 6, 7, 8]))

        let unchanged = AnnexB.stripAtomHeaderIfPresent(d, fourCC: "hvcC")
        XCTAssertEqual(unchanged, d)
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
        let lp = AnnexB.toLengthPrefixed(annex, lengthSize: 4)
        XCTAssertEqual(lp.prefix(4), Data([0, 0, 0, 3]))
        XCTAssertEqual(lp.dropFirst(4), nal)
    }
}
