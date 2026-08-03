import XCTest
@testable import HAENA

final class HAENATests: XCTestCase {
    func testAppNameMatchesProductName() {
        XCTAssertEqual(AppInfo.name, "HAE.NA")
    }
}
