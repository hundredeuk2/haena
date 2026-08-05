import XCTest
@testable import HAENA

/// The export leaves the app and cannot be corrected afterwards, so these tests are mostly about
/// what must *not* end up in the document: unreviewed proposals, rejected work, invented owners
/// or deadlines, internal identifiers.
final class ProjectMarkdownRendererTests: XCTestCase {
    /// Locale and time zone are pinned so the rendered dates are the same on any machine.
    private let renderer = ProjectMarkdownRenderer(
        dateFormatter: MeetingDateFormatter(
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    )
    private let generatedAt = TestFixtures.fixedDate

    private func render(_ project: Project) -> String {
        renderer.render(
            project: project,
            summary: .complete(project: project, referenceDate: TestFixtures.fixedDate),
            generatedAt: generatedAt
        )
    }

    // MARK: - Determinism and structure

    func testSameInputProducesTheSameDocument() {
        let project = reviewedProject()

        XCTAssertEqual(render(project), render(project))
    }

    func testSectionsAppearInAFixedOrderWithTheProjectNameAsTitle() {
        let markdown = render(reviewedProject())

        let headings = markdown
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") }

        XCTAssertEqual(headings, [
            "# HAE.NA",
            "## 확정된 결정",
            "## 진행 중인 업무",
            "## 미해결 질문",
            "## 다음 아젠다",
        ])
    }

    func testHeaderCarriesGenerationTimeAndPendingCount() {
        let markdown = render(reviewedProject())

        XCTAssertTrue(markdown.contains("- 생성 시각: 2023. 11. 14. 오후 10:13"), markdown)
        XCTAssertTrue(markdown.contains("- 확인 필요한 AI 제안: 0건"), markdown)
    }

    func testDocumentEndsWithExactlyOneNewline() {
        let markdown = render(reviewedProject())

        XCTAssertTrue(markdown.hasSuffix("\n"))
        XCTAssertFalse(markdown.hasSuffix("\n\n"))
    }

    // MARK: - Inclusion and exclusion

    func testUnreviewedProposalsAreCountedButTheirTextNeverAppears() {
        // ReviewFixtures.project() is one unreviewed proposal of each kind.
        let markdown = render(ReviewFixtures.project())

        XCTAssertTrue(markdown.contains("- 확인 필요한 AI 제안: 4건"), markdown)
        XCTAssertFalse(markdown.contains("2월 출시로 진행한다"), "a proposal's text must not leave the app")
        XCTAssertFalse(markdown.contains("지표 정의 초안 작성"))
        XCTAssertFalse(markdown.contains("지표 정의는 누가 확정하는가?"))
        XCTAssertFalse(markdown.contains("지표 정의 확정"))
    }

    func testRejectedCancelledResolvedAndDismissedItemsAreExcluded() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .rejected)],
            actionItems: [ReviewFixtures.actionItem(status: .completed)],
            openQuestions: [ReviewFixtures.openQuestion(status: .resolved, reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(status: .dismissed, reviewedAt: TestFixtures.laterDate)]
        )

        let markdown = render(project)

        XCTAssertFalse(markdown.contains("2월 출시로 진행한다"))
        XCTAssertFalse(markdown.contains("지표 정의 초안 작성"))
        XCTAssertFalse(markdown.contains("지표 정의는 누가 확정하는가?"))
        XCTAssertFalse(markdown.contains("지표 정의 확정"))
        XCTAssertEqual(markdown.components(separatedBy: "없음").count - 1, 4, "every section reports 없음")
    }

    func testEmptyProjectStillWritesEverySectionAsNone() {
        let project = ReviewFixtures.project(
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        let markdown = render(project)

        XCTAssertTrue(markdown.contains("## 확정된 결정\n\n없음"), markdown)
        XCTAssertTrue(markdown.contains("## 진행 중인 업무\n\n없음"), markdown)
        XCTAssertTrue(markdown.contains("## 미해결 질문\n\n없음"), markdown)
        XCTAssertTrue(markdown.contains("## 다음 아젠다\n\n없음"), markdown)
    }

    func testExportIsNotTruncatedToTheScreensThreeItemLimit() {
        let decisions = (0..<5).map { index in
            Decision(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", index))")!,
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                statement: "결정 \(index)",
                rationale: nil,
                status: .confirmed,
                evidence: nil,
                confidence: Confidence(0.8),
                createdAt: TestFixtures.fixedDate,
                updatedAt: TestFixtures.fixedDate
            )
        }

        let markdown = render(ReviewFixtures.project(decisions: decisions))

        for index in 0..<5 {
            XCTAssertTrue(markdown.contains("- 결정 \(index)"), "decision \(index) missing from the export")
        }
    }

    // MARK: - Work item fields

    func testWorkItemWithAssigneeAndDueDateShowsBoth() {
        let markdown = render(reviewedProject(assigneeID: ReviewFixtures.assignee.id, dueDate: TestFixtures.fixedDate))

        XCTAssertTrue(markdown.contains("  - 담당자: 서연"), markdown)
        XCTAssertTrue(markdown.contains("  - 마감일: 2023. 11. 14."), markdown)
        XCTAssertTrue(markdown.contains("  - 상태: 확정"), markdown)
    }

    func testWorkItemWithoutAssigneeOrDueDateSaysSoRatherThanInventingOne() {
        let markdown = render(reviewedProject(assigneeID: nil, dueDate: nil))

        XCTAssertTrue(markdown.contains("  - 담당자: 미지정"), markdown)
        XCTAssertTrue(markdown.contains("  - 마감일: 없음"), markdown)
    }

    func testAnAssigneeIdThatMatchesNoParticipantNeverLeaksAsAnIdentifier() {
        let stranger = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
        let markdown = render(reviewedProject(assigneeID: stranger, dueDate: nil))

        XCTAssertTrue(markdown.contains("  - 담당자: 미지정"), markdown)
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains(stranger.uuidString))
    }

    func testNoInternalIdentifiersAppearAnywhereInTheDocument() {
        let markdown = render(reviewedProject(assigneeID: ReviewFixtures.assignee.id, dueDate: TestFixtures.fixedDate))

        for identifier in [TestFixtures.projectID, TestFixtures.meetingID, TestFixtures.segmentID, ReviewFixtures.assignee.id] {
            XCTAssertFalse(markdown.localizedCaseInsensitiveContains(identifier.uuidString), "leaked \(identifier)")
        }
    }

    // MARK: - Evidence

    func testEvidenceIsQuotedVerbatimWhenPresent() {
        let markdown = render(reviewedProject())

        XCTAssertTrue(markdown.contains("  > 2월 출시로 가기로 했습니다"), markdown)
    }

    func testAMultiLineQuoteKeepsEveryLineInsideTheBlockquote() {
        let evidence = EvidenceReference(
            meetingID: TestFixtures.meetingID,
            transcriptSegmentID: TestFixtures.segmentID,
            quote: "첫 줄\n둘째 줄"
        )
        var decision = ReviewFixtures.decision(status: .confirmed)
        decision.evidence = evidence

        let markdown = render(ReviewFixtures.project(decisions: [decision]))

        XCTAssertTrue(markdown.contains("  > 첫 줄\n  > 둘째 줄"), markdown)
    }

    func testAnItemWithoutEvidenceGetsNoQuoteLineAtAll() {
        var decision = ReviewFixtures.decision(status: .confirmed)
        decision.evidence = nil

        let markdown = render(ReviewFixtures.project(
            decisions: [decision],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        ))

        XCTAssertTrue(markdown.contains("- 2월 출시로 진행한다"), markdown)
        XCTAssertFalse(markdown.contains(">"), "no quote marker when there is nothing to quote")
    }

    // MARK: - Text fidelity

    func testKoreanEnglishAndSpecialCharactersSurviveUnchanged() {
        let statement = "Ship v1.0 by *Feb* — 한국어 & English, 100% <확정> \"인용\""
        var decision = ReviewFixtures.decision(status: .confirmed)
        decision.statement = statement
        decision.evidence = EvidenceReference(
            meetingID: TestFixtures.meetingID,
            transcriptSegmentID: TestFixtures.segmentID,
            quote: "Let's ship — 2월에 가시죠 #1"
        )

        let markdown = render(ReviewFixtures.project(decisions: [decision]))

        XCTAssertTrue(markdown.contains("- \(statement)"), markdown)
        XCTAssertTrue(markdown.contains("  > Let's ship — 2월에 가시죠 #1"), markdown)
    }

    func testProjectNameIsWrittenAsTypedIncludingMarkdownCharacters() {
        var project = reviewedProject()
        project.name = "HAE.NA *v2* & 파트너"

        XCTAssertTrue(render(project).hasPrefix("# HAE.NA *v2* & 파트너\n"))
    }

    // MARK: - Fixtures

    /// A project where every kind has been through review, so it renders in full.
    private func reviewedProject(
        assigneeID: UUID? = nil,
        dueDate: Date? = nil
    ) -> Project {
        var actionItem = ReviewFixtures.actionItem(status: .confirmed)
        actionItem.assigneeID = assigneeID
        actionItem.dueDate = dueDate

        return ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)],
            actionItems: [actionItem],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )
    }
}
