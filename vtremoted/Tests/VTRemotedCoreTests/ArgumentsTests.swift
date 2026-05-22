@testable import VTRemotedCore
import XCTest

final class ArgumentsTests: XCTestCase {
    func testParseArgs() {
        let argv = [
            "vtremoted",
            "--listen", "127.0.0.1:9999",
            "--token", "abc",
            "--log-level", "2",
            "--once"
        ]
        let args = Arguments.parse(argv)
        XCTAssertEqual(args.listen, "127.0.0.1:9999")
        XCTAssertEqual(args.token, "abc")
        XCTAssertEqual(args.logLevel, .debug)
        XCTAssertTrue(args.once)
    }

    func testParseHelpAndVersion() {
        XCTAssertTrue(Arguments.parse(["vtremoted", "--help"]).showHelp)
        XCTAssertTrue(Arguments.parse(["vtremoted", "-h"]).showHelp)
        XCTAssertTrue(Arguments.parse(["vtremoted", "--version"]).showVersion)
        XCTAssertTrue(Arguments.usage.contains("--listen HOST:PORT"))
        XCTAssertEqual(Arguments.version, "0.5.0")
    }

    func testUnknownArgumentIsParseError() {
        let args = Arguments.parse(["vtremoted", "--bogus"])
        XCTAssertEqual(args.parseError, "unknown argument: --bogus")
    }
}
