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
        XCTAssertTrue(Arguments.version.hasPrefix("0."),
                      "version should be a semver string, got \(Arguments.version)")
        XCTAssertEqual(Arguments.version.split(separator: ".").count, 3)
    }

    func testUnknownArgumentIsParseError() {
        let args = Arguments.parse(["vtremoted", "--bogus"])
        XCTAssertEqual(args.parseError, "unknown argument: --bogus")
    }

    func testMissingOptionValueIsParseError() {
        XCTAssertEqual(
            Arguments.parse(["vtremoted", "--listen"]).parseError,
            "missing value for --listen"
        )
        XCTAssertEqual(
            Arguments.parse(["vtremoted", "--max-sessions"]).parseError,
            "missing value for --max-sessions"
        )
    }

    func testInvalidNumericAndLogValuesAreParseErrors() {
        XCTAssertFalse(Arguments.parse(["vtremoted", "--max-sessions", "0"]).parseError.isEmpty)
        XCTAssertFalse(Arguments.parse(["vtremoted", "--idle-timeout", "nope"]).parseError.isEmpty)
        XCTAssertFalse(Arguments.parse(["vtremoted", "--max-message-bytes", "4294967296"]).parseError.isEmpty)
        XCTAssertFalse(Arguments.parse(["vtremoted", "--log-level", "verbose"]).parseError.isEmpty)
    }

    func testEmptyRequiredStringValuesAreParseErrors() {
        XCTAssertFalse(Arguments.parse(["vtremoted", "--listen", ""]).parseError.isEmpty)
        XCTAssertFalse(Arguments.parse(["vtremoted", "--token-file", ""]).parseError.isEmpty)
        XCTAssertFalse(Arguments.parse(["vtremoted", "--token-env", ""]).parseError.isEmpty)
    }
}
