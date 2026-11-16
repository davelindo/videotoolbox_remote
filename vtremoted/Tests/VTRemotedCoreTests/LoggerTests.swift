@testable import VTRemotedCore
import XCTest

final class LoggerTests: XCTestCase {
    func testFilteredMessagesAreNotEvaluated() {
        let logger = Logger()
        logger.level = .error
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "logger test"
        }
        logger.debug(message())
        logger.info(message())
        XCTAssertEqual(evaluations, 0)
        logger.error(message())
        XCTAssertEqual(evaluations, 1)
    }
}
