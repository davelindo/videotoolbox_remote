import XCTest
@testable import VTRemotedCore

final class ArgumentsTests: XCTestCase {
    func testParseArgs() {
        let argv = [
            "vtremoted",
            "--listen", "127.0.0.1:9999",
            "--token", "abc",
            "--log-level", "2",
            "--once",
        ]
        let args = Arguments.parse(argv)
        XCTAssertEqual(args.listen, "127.0.0.1:9999")
        XCTAssertEqual(args.token, "abc")
        XCTAssertEqual(args.logLevel, .debug)
        XCTAssertTrue(args.once)
    }
}
