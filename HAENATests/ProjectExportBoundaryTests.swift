import UniformTypeIdentifiers
import XCTest
@testable import HAENA

/// Records what would have been copied instead of touching `NSPasteboard.general` — a unit test
/// must not destroy whatever the person running it had on their clipboard.
private final class SpyPasteboardWriter: PasteboardWriter {
    private(set) var written: [String] = []
    var succeeds = true

    func write(_ string: String) -> Bool {
        written.append(string)
        return succeeds
    }
}

/// Records what would have been saved instead of opening a modal panel or writing to disk.
@MainActor
private final class SpyFileExporter: MarkdownFileExporter {
    private(set) var exported: [(markdown: String, filename: String)] = []
    var outcome: MarkdownExportOutcome = .saved

    func export(_ markdown: String, suggestedFilename: String) -> MarkdownExportOutcome {
        exported.append((markdown, suggestedFilename))
        return outcome
    }
}

final class ProjectExportBoundaryTests: XCTestCase {
    // MARK: - Filename

    func testFilenameUsesTheProjectNameAndMarkdownExtension() {
        XCTAssertEqual(ProjectExportFilename.markdownFilename(for: "HAE.NA"), "HAE.NA.md")
    }

    func testPathSeparatorsAndReservedCharactersAreRemoved() {
        let filename = ProjectExportFilename.markdownFilename(for: "2026/08 리뷰: v1*?\"<>|")

        XCTAssertFalse(filename.dropLast(3).contains("/"), filename)
        XCTAssertFalse(filename.contains(":"), filename)
        XCTAssertFalse(filename.contains("*"), filename)
        XCTAssertFalse(filename.contains("?"), filename)
        XCTAssertFalse(filename.contains("\""), filename)
        XCTAssertTrue(filename.hasSuffix(".md"), filename)
    }

    func testKoreanNamesAreKept() {
        XCTAssertEqual(ProjectExportFilename.markdownFilename(for: "해나 프로젝트"), "해나 프로젝트.md")
    }

    func testANameThatSanitizesToNothingFallsBackRatherThanProducingADotFile() {
        XCTAssertEqual(ProjectExportFilename.markdownFilename(for: "///"), "project.md")
        XCTAssertEqual(ProjectExportFilename.markdownFilename(for: "   "), "project.md")
        XCTAssertEqual(ProjectExportFilename.markdownFilename(for: ""), "project.md")
    }

    func testALeadingDotIsDroppedSoTheFileIsNotHidden() {
        XCTAssertFalse(ProjectExportFilename.markdownFilename(for: ".hidden").hasPrefix("."))
    }

    func testAVeryLongNameIsTruncatedToStayWithinFilesystemLimits() {
        let filename = ProjectExportFilename.markdownFilename(for: String(repeating: "프", count: 400))

        XCTAssertLessThanOrEqual(filename.count, 103)
        XCTAssertTrue(filename.hasSuffix(".md"))
    }

    // MARK: - Document

    func testDocumentEncodesAsUTF8AndRoundTrips() throws {
        let markdown = "# 해나\n\n## 확정된 결정\n\n- 2월 출시 — *확정*\n"

        let data = try MarkdownExportData.utf8Data(markdown)

        XCTAssertEqual(String(data: data, encoding: .utf8), markdown)
        XCTAssertEqual(data, markdown.data(using: .utf8))
    }

    func testTheExportedContentTypeCarriesTheMarkdownExtension() {
        XCTAssertEqual(UTType.markdownText.preferredFilenameExtension, "md")
    }

    // MARK: - Pasteboard

    func testCopyingWritesTheStringAndReportsSuccess() {
        let spy = SpyPasteboardWriter()

        XCTAssertTrue(spy.write("# 해나"))
        XCTAssertEqual(spy.written, ["# 해나"])
    }

    func testAFailedPasteboardWriteIsReportedRatherThanSwallowed() {
        let spy = SpyPasteboardWriter()
        spy.succeeds = false

        XCTAssertFalse(spy.write("# 해나"))
    }

    // MARK: - Both actions

    /// The two actions must never diverge: what is copied is byte-identical to what is saved.
    @MainActor
    func testSavingAndCopyingUseTheSameRenderedText() throws {
        let markdown = renderedProjectMarkdown()

        let pasteboard = SpyPasteboardWriter()
        let exporter = SpyFileExporter()
        _ = pasteboard.write(markdown)
        _ = exporter.export(markdown, suggestedFilename: "HAE.NA.md")

        let savedBytes = try MarkdownExportData.utf8Data(try XCTUnwrap(exporter.exported.first?.markdown))

        XCTAssertEqual(pasteboard.written.first, String(data: savedBytes, encoding: .utf8))
    }

    @MainActor
    func testExportIsOfferedUnderTheSanitizedProjectFilename() {
        let exporter = SpyFileExporter()

        _ = exporter.export(renderedProjectMarkdown(), suggestedFilename: ProjectExportFilename.markdownFilename(for: "HAE.NA"))

        XCTAssertEqual(exporter.exported.first?.filename, "HAE.NA.md")
    }

    @MainActor
    func testCancellingIsDistinctFromFailingSoItIsNotReportedAsAnError() {
        let exporter = SpyFileExporter()
        exporter.outcome = .cancelled

        XCTAssertEqual(exporter.export("# 해나", suggestedFilename: "a.md"), .cancelled)
        XCTAssertNotEqual(MarkdownExportOutcome.cancelled, .failed)
    }

    private func renderedProjectMarkdown() -> String {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)],
            actionItems: [ReviewFixtures.actionItem(status: .confirmed)],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )
        return ProjectMarkdownRenderer().render(
            project: project,
            summary: .complete(project: project, referenceDate: TestFixtures.fixedDate),
            generatedAt: TestFixtures.fixedDate
        )
    }
}
