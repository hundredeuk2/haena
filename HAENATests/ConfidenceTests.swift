import XCTest
@testable import HAENA

final class ConfidenceTests: XCTestCase {
    func testValueWithinRangeIsPreservedExactly() {
        XCTAssertEqual(Confidence(0.42).value, 0.42)
    }

    func testValueBelowRangeIsClampedToZero() {
        XCTAssertEqual(Confidence(-3.5).value, 0.0)
    }

    func testValueAboveRangeIsClampedToOne() {
        XCTAssertEqual(Confidence(7.2).value, 1.0)
    }

    func testMinimumAndMaximumConstants() {
        XCTAssertEqual(Confidence.minimum.value, 0.0)
        XCTAssertEqual(Confidence.maximum.value, 1.0)
    }
}
