import XCTest
@testable import HAENA

/// Covers what the home calls "my work": which tasks qualify, which must never be claimed, and what
/// the screen falls back to when the user has not identified themselves.
final class MyWorkTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day: TimeInterval = 86_400

    private static let me1 = UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!
    private static let me2 = UUID(uuidString: "0000000A-0000-0000-0000-000000000002")!
    private static let someoneElse = UUID(uuidString: "0000000A-0000-0000-0000-0000000000FF")!

    private func profile(linking ids: [UUID] = [me1, me2]) -> LocalUserProfile {
        LocalUserProfile(
            id: UUID(uuidString: "0000000F-0000-0000-0000-000000000001")!,
            displayName: "이헌득",
            linkedParticipantIDs: ids,
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    // MARK: - The policy itself

    func testWorkAssignedToALinkedParticipantIsMine() {
        XCTAssertTrue(MyWorkPolicy.isMine(Fixture.item(1, assignee: Self.me1), profile: profile()))
        XCTAssertTrue(MyWorkPolicy.isMine(Fixture.item(2, assignee: Self.me2), profile: profile()))
    }

    func testWorkAssignedToSomebodyElseIsNotMine() {
        XCTAssertFalse(MyWorkPolicy.isMine(Fixture.item(1, assignee: Self.someoneElse), profile: profile()))
    }

    /// Nobody has taken it, so claiming it would invent an assignment the meeting never made.
    func testUnassignedWorkIsNotMine() {
        XCTAssertFalse(MyWorkPolicy.isMine(Fixture.item(1, assignee: nil), profile: profile()))
    }

    func testNothingIsMineWithoutAProfileOrWithoutLinks() {
        XCTAssertFalse(MyWorkPolicy.isMine(Fixture.item(1, assignee: Self.me1), profile: nil))
        XCTAssertFalse(
            MyWorkPolicy.isMine(Fixture.item(1, assignee: Self.me1), profile: profile(linking: [])),
            "A named profile with no linked participants still cannot identify anyone's work."
        )
        XCTAssertFalse(MyWorkPolicy.isPersonalised(nil))
        XCTAssertFalse(MyWorkPolicy.isPersonalised(profile(linking: [])))
        XCTAssertTrue(MyWorkPolicy.isPersonalised(profile()))
    }

    // MARK: - The home section

    func testMyWorkContainsOnlyMyConfirmedAndInProgressTasks() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, title: "내 확정", assignee: Self.me1, status: .confirmed),
            Fixture.item(2, title: "내 진행 중", assignee: Self.me2, status: .inProgress),
            Fixture.item(3, title: "내 미검토", assignee: Self.me1, status: .proposed),
            Fixture.item(4, title: "내 완료", assignee: Self.me1, status: .completed),
            Fixture.item(5, title: "내 제외", assignee: Self.me1, status: .cancelled),
            Fixture.item(6, title: "남의 확정", assignee: Self.someoneElse, status: .confirmed),
            Fixture.item(7, title: "담당자 없음", assignee: nil, status: .confirmed)
        ])

        let summary = HomeSummary.complete(projects: [project], profile: profile(), referenceDate: Self.now)
        let mine = try? XCTUnwrap(summary.myActionItems)

        XCTAssertEqual(mine?.items.map(\.actionItem.title).sorted(), ["내 진행 중", "내 확정"])
        XCTAssertEqual(
            summary.activeActionItems.totalCount,
            4,
            "Everyone's list still holds all active work, including the unassigned task."
        )
    }

    /// One task has one assignee, so no combination of linked identities can make it appear twice.
    func testATaskAppearsOnceEvenWhenSeveralIdentitiesAreLinked() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, title: "내 업무", assignee: Self.me1, status: .confirmed)
        ])

        let summary = HomeSummary.complete(
            projects: [project],
            profile: profile(linking: [Self.me1, Self.me2, Self.someoneElse]),
            referenceDate: Self.now
        )

        XCTAssertEqual(summary.myActionItems?.items.count, 1)
        XCTAssertEqual(summary.myActionItems?.totalCount, 1)
        XCTAssertEqual(Set(summary.myActionItems?.items.map(\.id) ?? []).count, 1)
    }

    func testMyWorkKeepsTheDueDateOrderAndUndatedWorkLast() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, title: "마감 없음", assignee: Self.me1, status: .confirmed),
            Fixture.item(2, title: "모레", assignee: Self.me1, status: .confirmed, due: Self.now + 2 * Self.day),
            Fixture.item(3, title: "내일", assignee: Self.me2, status: .confirmed, due: Self.now + Self.day),
            Fixture.item(4, title: "남의 오늘", assignee: Self.someoneElse, status: .confirmed, due: Self.now)
        ])

        let summary = HomeSummary.complete(projects: [project], profile: profile(), referenceDate: Self.now)

        XCTAssertEqual(
            summary.myActionItems?.items.map(\.actionItem.title),
            ["내일", "모레", "마감 없음"]
        )
    }

    func testMyWorkTruncatesAtFiveAndStillReportsTheTrueTotal() {
        let project = Fixture.project(actionItems: (1...8).map {
            Fixture.item($0, assignee: Self.me1, status: .confirmed, due: Self.now + Double($0) * Self.day)
        })

        let summary = HomeSummary(projects: [project], profile: profile(), referenceDate: Self.now)

        XCTAssertEqual(summary.myActionItems?.items.count, 5)
        XCTAssertEqual(summary.myActionItems?.totalCount, 8)
        XCTAssertEqual(summary.myActionItems?.hiddenCount, 3)
    }

    /// Merging across projects still applies, and each row keeps the provenance the home navigates
    /// with.
    func testMyWorkSpansProjectsAndKeepsItsSourceAndAssignee() {
        let first = Fixture.project(
            id: Fixture.projectOne,
            name: "출시 준비",
            actionItems: [Fixture.item(1, assignee: Self.me1, status: .confirmed)]
        )
        let second = Fixture.project(
            id: Fixture.projectTwo,
            name: "고객 온보딩",
            actionItems: [Fixture.item(2, assignee: Self.me2, status: .confirmed)]
        )

        let summary = HomeSummary.complete(projects: [first, second], profile: profile(), referenceDate: Self.now)
        let mine = summary.myActionItems?.items ?? []

        XCTAssertEqual(Set(mine.map(\.projectName)), ["출시 준비", "고객 온보딩"])
        XCTAssertEqual(Set(mine.map(\.projectID)), [Fixture.projectOne, Fixture.projectTwo])
        XCTAssertTrue(mine.allSatisfy { $0.assigneeName != nil }, "Rows still name who the work belongs to.")
    }

    // MARK: - Fallback

    /// Without a profile the home must keep showing what it showed before, not an empty screen and
    /// not a guess.
    func testWithoutAProfileTheHomeStillShowsEveryonesWork() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, assignee: Self.me1, status: .confirmed),
            Fixture.item(2, assignee: Self.someoneElse, status: .confirmed)
        ])

        let summary = HomeSummary(projects: [project], profile: nil, referenceDate: Self.now)

        XCTAssertNil(summary.myActionItems, "Nil, not empty: nobody has said who the user is.")
        XCTAssertFalse(summary.isPersonalised)
        XCTAssertEqual(summary.activeActionItems.totalCount, 2)
        XCTAssertNil(summary.localUserName)
    }

    func testANamedProfileWithNoLinksStillFallsBackToEveryonesWork() {
        let project = Fixture.project(actionItems: [Fixture.item(1, assignee: Self.me1, status: .confirmed)])

        let summary = HomeSummary(projects: [project], profile: profile(linking: []), referenceDate: Self.now)

        XCTAssertNil(summary.myActionItems)
        XCTAssertFalse(summary.isPersonalised)
        XCTAssertEqual(summary.localUserName, "이헌득", "The name is still shown, so the user can see what is missing.")
        XCTAssertEqual(summary.activeActionItems.totalCount, 1)
    }

    /// Identifying yourself must not remove the other three areas, or the full work list.
    func testPersonalisationLeavesTheRestOfTheHomeIntact() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, assignee: Self.me1, status: .confirmed),
            Fixture.item(2, assignee: Self.someoneElse, status: .confirmed)
        ])

        let anonymous = HomeSummary(projects: [project], profile: nil, referenceDate: Self.now)
        let personalised = HomeSummary(projects: [project], profile: profile(), referenceDate: Self.now)

        XCTAssertEqual(personalised.activeActionItems, anonymous.activeActionItems)
        XCTAssertEqual(personalised.pendingProposalCount, anonymous.pendingProposalCount)
        XCTAssertEqual(personalised.unresolvedQuestions, anonymous.unresolvedQuestions)
        XCTAssertEqual(personalised.upcomingAgendaItems, anonymous.upcomingAgendaItems)
        XCTAssertEqual(personalised.myActionItems?.totalCount, 1)
    }

    /// A link to a participant that no longer exists must simply match nothing.
    func testStaleLinksMatchNothing() {
        let project = Fixture.project(actionItems: [
            Fixture.item(1, assignee: Self.someoneElse, status: .confirmed)
        ])

        let summary = HomeSummary(projects: [project], profile: profile(linking: [UUID()]), referenceDate: Self.now)

        XCTAssertEqual(summary.myActionItems?.totalCount, 0)
        XCTAssertTrue(summary.myActionItems?.isEmpty == true)
        XCTAssertEqual(summary.activeActionItems.totalCount, 1)
    }

    // MARK: - Fixtures

    private enum Fixture {
        static let projectOne = UUID(uuidString: "0000000B-0000-0000-0000-000000000001")!
        static let projectTwo = UUID(uuidString: "0000000B-0000-0000-0000-000000000002")!

        static func item(
            _ index: Int,
            title: String? = nil,
            assignee: UUID?,
            status: ActionItemStatus = .confirmed,
            due: Date? = nil
        ) -> ActionItem {
            ActionItem(
                id: UUID(uuidString: "0000000C-0000-0000-0000-\(String(format: "%012d", index))")!,
                projectID: projectOne,
                meetingID: projectOne,
                title: title ?? "업무 \(index)",
                details: nil,
                assigneeID: assignee,
                dueDate: due,
                status: status,
                evidence: EvidenceReference(
                    meetingID: projectOne,
                    transcriptSegmentID: TestFixtures.segmentID,
                    quote: "근거"
                ),
                confidence: Confidence(0.6),
                createdAt: MyWorkTests.now,
                updatedAt: MyWorkTests.now
            )
        }

        static func project(
            id: UUID = Fixture.projectOne,
            name: String = "출시 준비",
            actionItems: [ActionItem]
        ) -> Project {
            let meeting = Meeting(
                id: id,
                projectID: id,
                title: "\(name) 회의",
                occurredAt: MyWorkTests.now,
                sourceType: .pastedText,
                participants: [
                    Participant(id: MyWorkTests.me1, displayName: "이헌득", linkedUserID: nil, speakerLabel: nil),
                    Participant(id: MyWorkTests.me2, displayName: "HD", linkedUserID: nil, speakerLabel: nil),
                    Participant(id: MyWorkTests.someoneElse, displayName: "민준", linkedUserID: nil, speakerLabel: nil)
                ],
                transcriptSegments: [],
                createdAt: MyWorkTests.now
            )
            return Project(
                id: id,
                name: name,
                summary: "",
                createdAt: MyWorkTests.now,
                updatedAt: MyWorkTests.now,
                meetings: [meeting],
                decisions: [],
                actionItems: actionItems.map { rehome($0, to: id) },
                openQuestions: [],
                nextAgenda: []
            )
        }

        private static func rehome(_ item: ActionItem, to projectID: UUID) -> ActionItem {
            ActionItem(
                id: item.id,
                projectID: projectID,
                meetingID: projectID,
                title: item.title,
                details: item.details,
                assigneeID: item.assigneeID,
                dueDate: item.dueDate,
                status: item.status,
                evidence: item.evidence,
                confidence: item.confidence,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
        }
    }
}
