import XCTest
@testable import HAENA

/// Covers the one question the home's 지금 할 일 card answers: out of everything stored, which
/// single thing should the user do now — and, just as importantly, when the honest answer is
/// nothing at all.
///
/// Every case pins both the reference date and the calendar, so what counts as overdue and how a
/// deadline reads never depend on when or where the suite runs.
final class NextActionTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let day: TimeInterval = 86_400

    private static let me1 = UUID(uuidString: "0000000A-0000-0000-0000-000000000001")!
    private static let me2 = UUID(uuidString: "0000000A-0000-0000-0000-000000000002")!
    private static let someoneElse = UUID(uuidString: "0000000A-0000-0000-0000-0000000000FF")!

    private let policy = NextActionPolicy(
        referenceDate: NextActionTests.now,
        calendar: NextActionTests.utcCalendar
    )

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    private func profile(linking ids: [UUID] = [me1, me2]) -> LocalUserProfile {
        LocalUserProfile(
            id: UUID(uuidString: "0000000F-0000-0000-0000-000000000001")!,
            displayName: "이헌득",
            linkedParticipantIDs: ids,
            createdAt: Self.now,
            updatedAt: Self.now
        )
    }

    // MARK: - Unreviewed proposals come first

    /// The headline rule. An unjudged proposal is the app asking a question it cannot answer
    /// itself; a late task is only late. Nothing about how overdue the task is changes this.
    func testAnUnreviewedProposalBeatsAnOverdueTaskOfTheUsersOwn() {
        let project = Fixture.project(
            decisions: [Fixture.decision(1)],
            actionItems: [Fixture.item(1, assignee: Self.me1, due: Self.now - 90 * Self.day)]
        )

        let action = policy.next(projects: [project], profile: profile())

        guard case .review(let review) = action else {
            return XCTFail("Expected a review recommendation, got \(String(describing: action))")
        }
        XCTAssertEqual(review.projectID, project.id)
    }

    /// The count on the card is that one project's, not the total across every project — the card
    /// names a project, and a number that did not belong to it would misreport what pressing it
    /// leads to.
    func testTheCountIsTheChosenProjectsOwnPendingProposals() {
        let chosen = Fixture.project(
            id: Fixture.projectOne,
            name: "출시 준비",
            decisions: [Fixture.decision(1, createdAt: Self.now - 10 * Self.day)],
            actionItems: [Fixture.item(1, status: .proposed), Fixture.item(2, status: .proposed)],
            openQuestions: [Fixture.question(1)]
        )
        let noisier = Fixture.project(
            id: Fixture.projectTwo,
            name: "고객 온보딩",
            decisions: [
                Fixture.decision(2, createdAt: Self.now),
                Fixture.decision(3, createdAt: Self.now),
                Fixture.decision(4, createdAt: Self.now),
                Fixture.decision(5, createdAt: Self.now)
            ]
        )

        guard case .review(let review)? = policy.next(projects: [chosen, noisier], profile: nil) else {
            return XCTFail("Expected a review recommendation")
        }
        XCTAssertEqual(review.projectID, Fixture.projectOne)
        XCTAssertEqual(review.projectName, "출시 준비")
        XCTAssertEqual(review.pendingCount, 4, "Two proposed tasks, one decision and one question")
    }

    /// Oldest waiting proposal, not biggest pile: otherwise the noisiest project would be the
    /// recommendation for as long as it stayed noisy, and the one question left unanswered since
    /// last month would never come up.
    func testTheProjectWithTheLongestWaitingProposalIsChosen() {
        let recent = Fixture.project(
            id: Fixture.projectOne,
            name: "최근",
            decisions: [
                Fixture.decision(1, createdAt: Self.now - Self.day),
                Fixture.decision(2, createdAt: Self.now - Self.day)
            ]
        )
        let oldest = Fixture.project(
            id: Fixture.projectTwo,
            name: "오래 기다림",
            decisions: [Fixture.decision(3, createdAt: Self.now - 30 * Self.day)]
        )
        let middle = Fixture.project(
            id: Fixture.projectThree,
            name: "중간",
            decisions: [Fixture.decision(4, createdAt: Self.now - 5 * Self.day)]
        )

        for order in [[recent, oldest, middle], [middle, recent, oldest], [oldest, middle, recent]] {
            guard case .review(let review)? = policy.next(projects: order, profile: nil) else {
                return XCTFail("Expected a review recommendation")
            }
            XCTAssertEqual(review.projectID, Fixture.projectTwo, "Ordering of the input must not matter")
        }
    }

    /// Two projects whose oldest proposal arrived at the same instant. The winner has to be the
    /// same one every time, whatever order storage hands them over in — a recommendation that
    /// flickers between two projects on reload is one the user cannot trust.
    func testAProposalTieIsBrokenDeterministicallyByProject() {
        let first = Fixture.project(
            id: Fixture.projectOne,
            name: "가",
            decisions: [Fixture.decision(1, createdAt: Self.now - Self.day)]
        )
        let second = Fixture.project(
            id: Fixture.projectTwo,
            name: "나",
            decisions: [Fixture.decision(2, createdAt: Self.now - Self.day)]
        )

        let forwards = policy.next(projects: [first, second], profile: nil)
        let backwards = policy.next(projects: [second, first], profile: nil)

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards?.projectID, Fixture.projectOne, "The lower project id wins")
    }

    // MARK: - The user's own work

    func testAnOverdueTaskBeatsAnUpcomingOne() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, title: "다가오는 업무", assignee: Self.me1, due: Self.now + Self.day),
                Fixture.item(2, title: "지난 업무", assignee: Self.me1, due: Self.now - Self.day)
            ]
        )

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "지난 업무")
        XCTAssertTrue(work.isOverdue)
    }

    /// The one that has been late longest, not the most recently missed.
    func testTheLongestOverdueTaskIsChosen() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, title: "어제 마감", assignee: Self.me1, due: Self.now - Self.day),
                Fixture.item(2, title: "한 달 전 마감", assignee: Self.me1, due: Self.now - 30 * Self.day),
                Fixture.item(3, title: "일주일 전 마감", assignee: Self.me2, due: Self.now - 7 * Self.day)
            ]
        )

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "한 달 전 마감")
    }

    func testTheSoonestUpcomingDeadlineIsChosenWhenNothingIsLate() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, title: "다음 달", assignee: Self.me1, due: Self.now + 30 * Self.day),
                Fixture.item(2, title: "내일", assignee: Self.me1, due: Self.now + Self.day),
                Fixture.item(3, title: "다음 주", assignee: Self.me2, due: Self.now + 7 * Self.day)
            ]
        )

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "내일")
        XCTAssertFalse(work.isOverdue)
    }

    /// No deadline is unknown, not urgent — but not dropped either, so it is what the card falls
    /// back to once everything dated has been dealt with.
    func testUndatedWorkComesAfterEverythingDatedAndIsStillOffered() {
        let dated = Fixture.item(1, title: "마감 있음", assignee: Self.me1, due: Self.now + 365 * Self.day)
        let undated = Fixture.item(2, title: "마감 없음", assignee: Self.me1)

        guard case .work(let withBoth)? = policy.next(
            projects: [Fixture.project(actionItems: [undated, dated])],
            profile: profile()
        ) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(withBoth.title, "마감 있음")

        guard case .work(let undatedOnly)? = policy.next(
            projects: [Fixture.project(actionItems: [undated])],
            profile: profile()
        ) else {
            return XCTFail("Undated work is still work the user has to do")
        }
        XCTAssertEqual(undatedOnly.title, "마감 없음")
        XCTAssertEqual(undatedOnly.dueDateLabel, "마감일 없음")
        XCTAssertFalse(undatedOnly.isOverdue, "A missing deadline is unknown, not breached")
    }

    /// Same deadline, two projects: broken on project then task, so the answer survives a reload
    /// and a differently ordered store.
    func testATaskTieIsBrokenDeterministicallyByProjectThenItem() {
        let first = Fixture.project(
            id: Fixture.projectOne,
            name: "가",
            actionItems: [Fixture.item(2, assignee: Self.me1, due: Self.now + Self.day)]
        )
        let second = Fixture.project(
            id: Fixture.projectTwo,
            name: "나",
            actionItems: [Fixture.item(1, assignee: Self.me1, due: Self.now + Self.day)]
        )

        let forwards = policy.next(projects: [first, second], profile: profile())
        let backwards = policy.next(projects: [second, first], profile: profile())

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards?.projectID, Fixture.projectOne, "The lower project id wins before the item id does")
    }

    /// The user is two participants across the roster. Selecting per linked identity and merging
    /// would let one task be considered twice; filtering one already-built list cannot.
    func testATaskAssignedUnderSeveralOfTheUsersIdentitiesIsConsideredOnce() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, title: "첫 이름으로 배정", assignee: Self.me1, due: Self.now - 2 * Self.day),
                Fixture.item(2, title: "두 번째 이름으로 배정", assignee: Self.me2, due: Self.now - Self.day)
            ]
        )

        let rows = [
            HomeActionItem(project.actionItems[0], in: project),
            HomeActionItem(project.actionItems[1], in: project)
        ]
        XCTAssertEqual(MyWorkPolicy.mine(rows, profile: profile()).count, 2, "Each task exactly once")

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "첫 이름으로 배정")
        XCTAssertEqual(work.assigneeName, "이헌득")
    }

    /// Somebody else's overdue task is not a thing to recommend to this user, however late it is.
    func testSomebodyElsesWorkIsNeverRecommended() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, title: "민준의 업무", assignee: Self.someoneElse, due: Self.now - 30 * Self.day),
                Fixture.item(2, title: "주인 없는 업무", assignee: nil, due: Self.now - 20 * Self.day),
                Fixture.item(3, title: "내 업무", assignee: Self.me1, due: Self.now + 30 * Self.day)
            ]
        )

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "내 업무", "Unassigned work is nobody's, and is not claimed either")
    }

    /// Only work a person accepted and has not finished. A proposal is not yet work, and finished
    /// or excluded work is not work any more — the same three exclusions `WorkStateInbox` already
    /// applies everywhere else.
    ///
    /// The proposed task here carries no evidence, so it is somebody's own hand-entered draft
    /// rather than a pending AI proposal. That isolates the exclusion being tested: it is kept out
    /// because it is `.proposed`, not because the review branch happened to fire first.
    func testProposedCompletedAndCancelledWorkIsNeverRecommended() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(
                    1,
                    title: "제안됨",
                    assignee: Self.me1,
                    status: .proposed,
                    due: Self.now - 40 * Self.day,
                    evidence: nil
                ),
                Fixture.item(2, title: "완료", assignee: Self.me1, status: .completed, due: Self.now - 30 * Self.day),
                Fixture.item(3, title: "제외됨", assignee: Self.me1, status: .cancelled, due: Self.now - 20 * Self.day),
                Fixture.item(4, title: "진행 중", assignee: Self.me1, status: .inProgress, due: Self.now + Self.day)
            ]
        )

        guard case .work(let work)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "진행 중")
    }

    /// A proposed task carries evidence, so it is also a pending proposal — which is what the card
    /// must offer instead of quietly treating it as work.
    func testAProposedTaskIsOfferedAsSomethingToReviewRatherThanToDo() {
        let project = Fixture.project(
            actionItems: [Fixture.item(1, title: "제안됨", assignee: Self.me1, status: .proposed)]
        )

        guard case .review(let review)? = policy.next(projects: [project], profile: profile()) else {
            return XCTFail("Expected a review recommendation")
        }
        XCTAssertEqual(review.pendingCount, 1)
    }

    // MARK: - Nothing to say

    /// Without a profile there is no basis for "mine" — but proposals belong to nobody in
    /// particular, so those are still worth recommending.
    func testWithoutAProfileTheCardStillOffersProposalsToReview() {
        let project = Fixture.project(
            decisions: [Fixture.decision(1)],
            actionItems: [Fixture.item(1, assignee: Self.someoneElse, due: Self.now - Self.day)]
        )

        guard case .review? = policy.next(projects: [project], profile: nil) else {
            return XCTFail("Expected a review recommendation")
        }
    }

    /// The whole point of the narrow rule: with nothing to review and no way to say which work is
    /// the user's, the card says so instead of handing them somebody else's task.
    func testWithoutAProfileAndWithNothingToReviewThereIsNoRecommendation() {
        let project = Fixture.project(
            actionItems: [
                Fixture.item(1, assignee: Self.someoneElse, status: .confirmed, due: Self.now - Self.day),
                Fixture.item(2, assignee: nil, status: .inProgress)
            ]
        )

        XCTAssertNil(policy.next(projects: [project], profile: nil))
    }

    /// A named profile that has not been linked to any participant is the same situation: a name
    /// is not an identity in a transcript, and matching it against one would be a guess.
    func testANamedProfileWithNoLinkedParticipantRecommendsNothing() {
        let project = Fixture.project(
            actionItems: [Fixture.item(1, assignee: Self.me1, status: .confirmed, due: Self.now - Self.day)]
        )

        XCTAssertNil(policy.next(projects: [project], profile: profile(linking: [])))
    }

    func testAnEmptyStoreRecommendsNothing() {
        XCTAssertNil(policy.next(projects: [], profile: profile()))
        XCTAssertNil(policy.next(projects: [], profile: nil))
    }

    // MARK: - Round trip through storage

    /// The card is read from whatever the repository returns, so the same data written and read
    /// back has to recommend the identical thing — otherwise the app tells the user to do something
    /// different after a restart.
    func testTheRecommendationIsUnchangedAfterAJSONRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-NextAction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let projects = [
            Fixture.project(
                id: Fixture.projectOne,
                name: "출시 준비",
                actionItems: [
                    Fixture.item(1, title: "지난 업무", assignee: Self.me1, due: Self.now - 3 * Self.day),
                    Fixture.item(2, title: "다가오는 업무", assignee: Self.me2, due: Self.now + Self.day)
                ]
            ),
            Fixture.project(
                id: Fixture.projectTwo,
                name: "고객 온보딩",
                actionItems: [Fixture.item(3, title: "남의 업무", assignee: Self.someoneElse, due: Self.now - 9 * Self.day)]
            )
        ]

        let repository = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        for project in projects {
            try await repository.save(project)
        }
        let reloaded = try await ProjectBrowserQueryService(repository: repository).loadProjects()

        let expected = policy.next(projects: projects, profile: profile())
        let actual = policy.next(projects: reloaded, profile: profile())

        XCTAssertEqual(actual, expected)
        guard case .work(let work)? = actual else {
            return XCTFail("Expected a task recommendation")
        }
        XCTAssertEqual(work.title, "지난 업무")
        XCTAssertEqual(work.projectID, Fixture.projectOne)
        XCTAssertEqual(work.projectName, "출시 준비")
        XCTAssertTrue(work.isOverdue)
    }

    // MARK: - What the home does with it

    /// One card or none, whatever else is on the screen. Guaranteed by the shape of the value
    /// rather than by a view remembering a rule: there is a single optional recommendation, so
    /// there is nothing a second card could be rendered from.
    func testTheHomeCarriesExactlyOneRecommendationOrNone() {
        let busy = Fixture.project(
            decisions: [Fixture.decision(1), Fixture.decision(2)],
            actionItems: [
                Fixture.item(1, assignee: Self.me1, status: .confirmed, due: Self.now - Self.day),
                Fixture.item(2, assignee: Self.me2, status: .inProgress, due: Self.now + Self.day)
            ],
            openQuestions: [Fixture.question(1, reviewed: true)]
        )

        let summary = HomeSummary(
            projects: [busy],
            profile: profile(),
            referenceDate: Self.now,
            calendar: Self.utcCalendar
        )

        XCTAssertNotNil(summary.nextAction)
        XCTAssertEqual(summary.nextAction, policy.next(projects: [busy], profile: profile()))

        let quiet = Fixture.project(actionItems: [Fixture.item(9, assignee: Self.someoneElse, status: .completed)])
        XCTAssertNil(
            HomeSummary(projects: [quiet], profile: profile(), referenceDate: Self.now, calendar: Self.utcCalendar)
                .nextAction
        )
    }

    /// The card is added above the four areas, not instead of any of them: the recommendation
    /// answers "what now", and the areas still have to answer "what is going on".
    func testTheFourExistingAreasAreUnaffectedByTheRecommendation() {
        let project = Fixture.project(
            decisions: [Fixture.decision(1)],
            actionItems: [
                Fixture.item(1, assignee: Self.me1, status: .confirmed, due: Self.now - Self.day),
                Fixture.item(2, assignee: Self.someoneElse, status: .inProgress)
            ],
            openQuestions: [Fixture.question(1, reviewed: true)],
            agenda: [Fixture.agenda(1, reviewed: true)]
        )

        let summary = HomeSummary.complete(
            projects: [project],
            profile: profile(),
            referenceDate: Self.now,
            calendar: Self.utcCalendar
        )

        XCTAssertNotNil(summary.nextAction, "There is something to recommend…")
        XCTAssertEqual(summary.pendingProposalCount, 1, "…and 확인 필요 still reports it too")
        XCTAssertEqual(summary.activeActionItems.totalCount, 2, "진행 업무 still shows everybody's work")
        XCTAssertEqual(summary.myActionItems?.totalCount, 1)
        XCTAssertEqual(summary.unresolvedQuestions.totalCount, 1)
        XCTAssertEqual(summary.upcomingAgendaItems.totalCount, 1)
    }

    // MARK: - Fixtures

    private enum Fixture {
        static let projectOne = UUID(uuidString: "0000000B-0000-0000-0000-000000000001")!
        static let projectTwo = UUID(uuidString: "0000000B-0000-0000-0000-000000000002")!
        static let projectThree = UUID(uuidString: "0000000B-0000-0000-0000-000000000003")!

        static func project(
            id: UUID = Fixture.projectOne,
            name: String = "출시 준비",
            decisions: [Decision] = [],
            actionItems: [ActionItem] = [],
            openQuestions: [OpenQuestion] = [],
            agenda: [AgendaItem] = []
        ) -> Project {
            let meeting = Meeting(
                id: meetingID(for: id),
                projectID: id,
                title: "\(name) 회의",
                occurredAt: now,
                sourceType: .pastedText,
                participants: [
                    Participant(id: me1, displayName: "이헌득", linkedUserID: nil, speakerLabel: nil),
                    Participant(id: me2, displayName: "HD", linkedUserID: nil, speakerLabel: nil),
                    Participant(id: someoneElse, displayName: "민준", linkedUserID: nil, speakerLabel: nil)
                ],
                transcriptSegments: [],
                createdAt: now
            )
            return Project(
                id: id,
                name: name,
                summary: "",
                createdAt: now,
                updatedAt: now,
                meetings: [meeting],
                decisions: decisions.map { rehome($0, projectID: id, meetingID: meeting.id) },
                actionItems: actionItems.map { rehome($0, projectID: id, meetingID: meeting.id) },
                openQuestions: openQuestions.map { rehome($0, projectID: id, meetingID: meeting.id) },
                nextAgenda: agenda.map { rehome($0, projectID: id, meetingID: meeting.id) }
            )
        }

        /// `evidence` non-nil by default so the pending-proposal policy sees an AI-derived record;
        /// pass nil to model one a person typed in themselves, which is never pending however it is
        /// statused.
        static func item(
            _ index: Int,
            title: String? = nil,
            assignee: UUID? = nil,
            status: ActionItemStatus = .confirmed,
            due: Date? = nil,
            evidence: EvidenceReference? = placeholderEvidence
        ) -> ActionItem {
            ActionItem(
                id: id("0000000C", index),
                projectID: projectOne,
                meetingID: projectOne,
                title: title ?? "업무 \(index)",
                details: nil,
                assigneeID: assignee,
                dueDate: due,
                status: status,
                evidence: evidence,
                confidence: Confidence(0.7),
                createdAt: now,
                updatedAt: now
            )
        }

        static func decision(_ index: Int, createdAt: Date = now) -> Decision {
            Decision(
                id: id("0000000D", index),
                projectID: projectOne,
                meetingID: projectOne,
                statement: "결정 \(index)",
                rationale: nil,
                status: .proposed,
                evidence: placeholderEvidence,
                confidence: Confidence(0.8),
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }

        static func question(_ index: Int, reviewed: Bool = false, createdAt: Date = now) -> OpenQuestion {
            OpenQuestion(
                id: id("0000000E", index),
                projectID: projectOne,
                meetingID: projectOne,
                question: "질문 \(index)",
                status: .open,
                evidence: placeholderEvidence,
                confidence: Confidence(0.6),
                createdAt: createdAt,
                resolvedAt: nil,
                reviewedAt: reviewed ? now : nil
            )
        }

        static func agenda(_ index: Int, reviewed: Bool = false, createdAt: Date = now) -> AgendaItem {
            AgendaItem(
                id: id("00000010", index),
                projectID: projectOne,
                title: "아젠다 \(index)",
                reason: "이번 회의에서 결론이 나지 않음",
                sourceMeetingID: projectOne,
                relatedActionItemID: nil,
                relatedOpenQuestionID: nil,
                status: .pending,
                createdAt: createdAt,
                evidence: placeholderEvidence,
                confidence: Confidence(0.5),
                reviewedAt: reviewed ? now : nil
            )
        }

        // MARK: Plumbing

        private static let now = NextActionTests.now
        private static let me1 = NextActionTests.me1
        private static let me2 = NextActionTests.me2
        private static let someoneElse = NextActionTests.someoneElse

        /// Non-nil so the pending-proposal policy sees an AI-derived record rather than something a
        /// person typed in. Replaced by `rehome` once the owning project is known.
        private static let placeholderEvidence = EvidenceReference(
            meetingID: projectOne,
            transcriptSegmentID: TestFixtures.segmentID,
            quote: "회의에서 언급된 근거"
        )

        static func id(_ prefix: String, _ index: Int) -> UUID {
            UUID(uuidString: "\(prefix)-0000-0000-0000-\(String(format: "%012d", index))")!
        }

        private static func meetingID(for projectID: UUID) -> UUID {
            UUID(uuidString: "0000000F" + projectID.uuidString.dropFirst(8))!
        }

        private static func evidence(_ meetingID: UUID) -> EvidenceReference {
            EvidenceReference(
                meetingID: meetingID,
                transcriptSegmentID: TestFixtures.segmentID,
                quote: "회의에서 언급된 근거"
            )
        }

        private static func rehome(_ value: ActionItem, projectID: UUID, meetingID: UUID) -> ActionItem {
            ActionItem(
                id: value.id,
                projectID: projectID,
                meetingID: meetingID,
                title: value.title,
                details: value.details,
                assigneeID: value.assigneeID,
                dueDate: value.dueDate,
                status: value.status,
                evidence: value.evidence.map { _ in evidence(meetingID) },
                confidence: value.confidence,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            )
        }

        private static func rehome(_ value: Decision, projectID: UUID, meetingID: UUID) -> Decision {
            Decision(
                id: value.id,
                projectID: projectID,
                meetingID: meetingID,
                statement: value.statement,
                rationale: value.rationale,
                status: value.status,
                evidence: evidence(meetingID),
                confidence: value.confidence,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
            )
        }

        private static func rehome(_ value: OpenQuestion, projectID: UUID, meetingID: UUID) -> OpenQuestion {
            OpenQuestion(
                id: value.id,
                projectID: projectID,
                meetingID: meetingID,
                question: value.question,
                status: value.status,
                evidence: evidence(meetingID),
                confidence: value.confidence,
                createdAt: value.createdAt,
                resolvedAt: value.resolvedAt,
                reviewedAt: value.reviewedAt
            )
        }

        private static func rehome(_ value: AgendaItem, projectID: UUID, meetingID: UUID) -> AgendaItem {
            AgendaItem(
                id: value.id,
                projectID: projectID,
                title: value.title,
                reason: value.reason,
                sourceMeetingID: meetingID,
                relatedActionItemID: nil,
                relatedOpenQuestionID: nil,
                status: value.status,
                createdAt: value.createdAt,
                evidence: evidence(meetingID),
                confidence: value.confidence,
                reviewedAt: value.reviewedAt
            )
        }
    }
}
