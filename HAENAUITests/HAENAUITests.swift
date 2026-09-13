import XCTest

@MainActor
final class HAENAUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeScreenShowsRecordAndImportButtons() throws {
        let app = try AppShellUITests.guardedLaunch(for: self)
        defer { app.terminate() }

        let recordButton = app.buttons["record-button"]
        let importButton = app.buttons["import-button"]

        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(recordButton.isHittable)
        XCTAssertTrue(importButton.isHittable)
        try AppShellUITests.validateEnvironment(app)
    }

    func testHomeScreenShowsProductName() throws {
        let app = try AppShellUITests.guardedLaunch(for: self)
        defer { app.terminate() }

        let productName = app.staticTexts["product-name"]

        XCTAssertTrue(productName.waitForExistence(timeout: 5))
        // On macOS, AXStaticText exposes its text via the `value` attribute rather than `label`.
        let displayedText = productName.label.isEmpty ? (productName.value as? String ?? "") : productName.label
        XCTAssertEqual(displayedText, "HAE.NA")
        try AppShellUITests.validateEnvironment(app)
    }
}
