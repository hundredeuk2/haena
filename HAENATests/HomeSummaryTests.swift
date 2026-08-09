import XCTest
@testable import HAENA

/// Covers the home screen's whole job: merging four kinds of work across every project, applying
/// exactly the domain's existing include/exclude rules, ordering the result, and truncating it
/// without misreporting the totals.
final class HomeSummaryTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Merging across projects

    func testWorkFromEveryProjectAppearsInOneSummary() {
        let first = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, title: "지표 정의", status: .confirmed)],
            openQuestions: [Fixture.question(1, text: "누가 확정하나?", reviewed: true)],
            agenda: [Fixture.agenda(1, title: "지표 확정", reviewed: true)]
        )
        let second = Fixture.project(
            name: "고객 온보딩",
            actionItems: [Fixture.actionItem(2, title: "가이드 작성", status: .inProgress)],
            openQuestions: [Fixture.question(2, text: "언제 배포하나?", reviewed: true)],
            agenda: [Fixture.agenda(2, title: "일정 확정", reviewed: true)]
        )

        let summary = HomeSummary(projects: [first, second], referenceDate: Self.now)

        XCTAssertEqual(summary.projectCount, 2)
        XCTAssertEqual(summary.activeActionItems.totalCount, 2)
        XCTAssertEqual(summary.unresolvedQuestions.totalCount, 2)
        XCTAssertEqual(summary.upcomingAgendaItems.totalCount, 2)
        XCTAssertEqual(
            Set(summary.activeActionItems.items.map(\.projectName)),
            ["출시 준비", "고객 온보딩"]
        )
    }

    /// Every row has to name its project — two identically worded tasks from different projects
    /// are otherwise indistinguishable, and there is nowhere to navigate to.
    func testEveryRowCarriesTheProjectItCameFrom() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, status: .confirmed)],
            openQuestions: [Fixture.question(1, reviewed: true)],
            agenda: [Fixture.agenda(1, reviewed: true)]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.activeActionItems.items.first?.projectName, "출시 준비")
        XCTAssertEqual(summary.activeActionItems.items.first?.projectID, project.id)
        XCTAssertEqual(summary.unresolvedQuestions.items.first?.projectName, "출시 준비")
        XCTAssertEqual(summary.unresolvedQuestions.items.first?.projectID, project.id)
        XCTAssertEqual(summary.upcomingAgendaItems.items.first?.projectName, "출시 준비")
        XCTAssertEqual(summary.upcomingAgendaItems.items.first?.projectID, project.id)
    }

    // MARK: - 확인 필요

    func testPendingProposalsAreCountedAcrossProjectsAndAttributed() {
        let first = Fixture.project(
            name: "출시 준비",
            decisions: [Fixture.decision(1), Fixture.decision(2)],
            actionItems: [Fixture.actionItem(1)],
            openQuestions: [Fixture.question(1)],
            agenda: [Fixture.agenda(1)]
        )
        let second = Fixture.project(name: "고객 온보딩", decisions: [Fixture.decision(3)])

        let summary = HomeSummary(projects: [first, second], referenceDate: Self.now)

        XCTAssertEqual(summary.pendingProposalCount, 6, "All four kinds count, from both projects.")
        XCTAssertEqual(summary.pendingProposalsByProject.totalCount, 2)
        XCTAssertEqual(summary.pendingProposalsByProject.items.first?.projectName, "출시 준비")
        XCTAssertEqual(summary.pendingProposalsByProject.items.first?.count, 5)
        XCTAssertEqual(summary.pendingProposalsByProject.items.last?.count, 1)
    }

    /// The screen shows counts, never the proposals themselves — and it must agree exactly with the
    /// single policy the review screen and re-extraction already share.
    func testPendingCountMatchesPendingAIProposalPolicyExactly() {
        let project = Fixture.project(
            name: "출시 준비",
            decisions: [
                Fixture.decision(1),                                   // pending
                Fixture.decision(2, status: .confirmed),               // reviewed
                Fixture.decision(3, evidence: nil)                     // hand-entered, not a proposal
            ],
            actionItems: [
                Fixture.actionItem(1),                                 // pending
                Fixture.actionItem(2, evidence: nil)                   // hand-entered
            ],
            openQuestions: [
                Fixture.question(1),                                   // pending
                Fixture.question(2, reviewed: true)                    // reviewed
            ],
            agenda: [
                Fixture.agenda(1),                                     // pending
                Fixture.agenda(2, reviewed: true)                      // reviewed
            ]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)
        let byPolicy = WorkStateInbox.pendingProposals(in: project).count

        XCTAssertEqual(summary.pendingProposalCount, byPolicy)
        XCTAssertEqual(summary.pendingProposalCount, 4)
    }

    /// A project with nothing waiting must not appear in the list at all.
    func testProjectsWithNothingPendingAreNotListed() {
        let quiet = Fixture.project(name: "조용한 프로젝트", decisions: [Fixture.decision(1, status: .confirmed)])
        let busy = Fixture.project(name: "바쁜 프로젝트", decisions: [Fixture.decision(2)])

        let summary = HomeSummary(projects: [quiet, busy], referenceDate: Self.now)

        XCTAssertEqual(summary.pendingProposalsByProject.totalCount, 1)
        XCTAssertEqual(summary.pendingProposalsByProject.items.first?.projectName, "바쁜 프로젝트")
    }

    // MARK: - Unreviewed proposals never mix into settled work

    /// The load-bearing rule of the whole screen: an unreviewed proposal is a machine's guess, and
    /// showing one beside approved work would present it as settled fact.
    func testUnreviewedProposalsNeverAppearInTheSettledAreas() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, title: "제안된 업무", status: .proposed)],
            openQuestions: [Fixture.question(1, text: "제안된 질문", reviewed: false)],
            agenda: [Fixture.agenda(1, title: "제안된 아젠다", reviewed: false)]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.pendingProposalCount, 3)
        XCTAssertTrue(summary.activeActionItems.isEmpty)
        XCTAssertTrue(summary.unresolvedQuestions.isEmpty)
        XCTAssertTrue(summary.upcomingAgendaItems.isEmpty)
    }

    // MARK: - Finished and excluded work

    func testCompletedCancelledResolvedAndDismissedWorkIsExcluded() {
        let project = Fixture.project(
            name: "출시 준비",
            decisions: [Fixture.decision(9, status: .rejected)],
            actionItems: [
                Fixture.actionItem(1, title: "확정", status: .confirmed),
                Fixture.actionItem(2, title: "진행 중", status: .inProgress),
                Fixture.actionItem(3, title: "완료", status: .completed),
                Fixture.actionItem(4, title: "제외", status: .cancelled)
            ],
            openQuestions: [
                Fixture.question(1, text: "미해결", reviewed: true),
                Fixture.question(2, text: "해결됨", status: .resolved, reviewed: true),
                Fixture.question(3, text: "제외됨", status: .dismissed, reviewed: true)
            ],
            agenda: [
                Fixture.agenda(1, title: "예정", reviewed: true),
                Fixture.agenda(2, title: "처리됨", status: .resolved, reviewed: true),
                Fixture.agenda(3, title: "제외됨", status: .dismissed, reviewed: true)
            ]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.activeActionItems.items.map(\.actionItem.title), ["확정", "진행 중"])
        XCTAssertEqual(summary.unresolvedQuestions.items.map(\.value.question), ["미해결"])
        XCTAssertEqual(summary.upcomingAgendaItems.items.map(\.value.title), ["예정"])
        XCTAssertEqual(summary.pendingProposalCount, 0, "A rejected decision is not waiting on anyone.")
    }

    /// Each area must agree item for item with the per-project inbox it is built from.
    func testEachAreaAgreesWithWorkStateInbox() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [
                Fixture.actionItem(1, status: .confirmed),
                Fixture.actionItem(2, status: .completed)
            ],
            openQuestions: [Fixture.question(1, reviewed: true), Fixture.question(2)],
            agenda: [Fixture.agenda(1, reviewed: true), Fixture.agenda(2)]
        )

        let summary = HomeSummary.complete(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(
            Set(summary.activeActionItems.items.map(\.id)),
            Set(WorkStateInbox.activeActionItems(in: project).map(\.id))
        )
        XCTAssertEqual(
            Set(summary.unresolvedQuestions.items.map(\.id)),
            Set(WorkStateInbox.reviewedOpenQuestions(in: project).map(\.id))
        )
        XCTAssertEqual(
            Set(summary.upcomingAgendaItems.items.map(\.id)),
            Set(WorkStateInbox.reviewedAgendaItems(in: project).map(\.id))
        )
    }

    // MARK: - Ordering

    func testWorkIsOrderedBySoonestDeadlineWithUndatedWorkLast() {
        let day: TimeInterval = 86_400
        let first = Fixture.project(
            name: "A",
            actionItems: [
                Fixture.actionItem(1, title: "마감 없음", status: .confirmed, dueDate: nil),
                Fixture.actionItem(2, title: "모레", status: .confirmed, dueDate: Self.now + 2 * day)
            ]
        )
        let second = Fixture.project(
            name: "B",
            actionItems: [
                Fixture.actionItem(3, title: "내일", status: .inProgress, dueDate: Self.now + day),
                Fixture.actionItem(4, title: "마감 없음 2", status: .confirmed, dueDate: nil)
            ]
        )

        let summary = HomeSummary(projects: [first, second], referenceDate: Self.now)

        XCTAssertEqual(
            summary.activeActionItems.items.map(\.actionItem.title),
            ["내일", "모레", "마감 없음", "마감 없음 2"],
            "Deadlines first across projects; undated work keeps its place at the end."
        )
    }

    /// Ties must break deterministically, or the list reshuffles between reads of the same data.
    func testTiedItemsHaveAStableOrder() {
        let due = Self.now + 86_400
        let projects = [
            Fixture.project(name: "A", actionItems: [
                Fixture.actionItem(3, status: .confirmed, dueDate: due),
                Fixture.actionItem(1, status: .confirmed, dueDate: due)
            ]),
            Fixture.project(name: "B", actionItems: [
                Fixture.actionItem(2, status: .confirmed, dueDate: due)
            ])
        ]

        let first = HomeSummary(projects: projects, referenceDate: Self.now).activeActionItems.items.map(\.id)
        let reversed = HomeSummary(projects: projects.reversed(), referenceDate: Self.now)
            .activeActionItems.items.map(\.id)

        XCTAssertEqual(first, reversed, "Order must not depend on the order projects came in.")
        XCTAssertEqual(first, first.sorted { $0.uuidString < $1.uuidString })
    }

    func testQuestionsAndAgendaAreOrderedNewestFirstAcrossProjects() {
        let minute: TimeInterval = 60
        let projects = [
            Fixture.project(name: "A", openQuestions: [
                Fixture.question(1, text: "오래된", reviewed: true, createdAt: Self.now)
            ], agenda: [
                Fixture.agenda(1, title: "오래된", reviewed: true, createdAt: Self.now)
            ]),
            Fixture.project(name: "B", openQuestions: [
                Fixture.question(2, text: "최근", reviewed: true, createdAt: Self.now + minute)
            ], agenda: [
                Fixture.agenda(2, title: "최근", reviewed: true, createdAt: Self.now + minute)
            ])
        ]

        let summary = HomeSummary(projects: projects, referenceDate: Self.now)

        XCTAssertEqual(summary.unresolvedQuestions.items.map(\.value.question), ["최근", "오래된"])
        XCTAssertEqual(summary.upcomingAgendaItems.items.map(\.value.title), ["최근", "오래된"])
    }

    // MARK: - Truncation

    func testEachAreaShowsFiveItemsAndStillReportsTheTrueTotal() {
        let day: TimeInterval = 86_400
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: (1...8).map {
                Fixture.actionItem($0, status: .confirmed, dueDate: Self.now + Double($0) * day)
            },
            openQuestions: (1...7).map { Fixture.question($0, reviewed: true) },
            agenda: (1...6).map { Fixture.agenda($0, reviewed: true) }
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.activeActionItems.items.count, 5)
        XCTAssertEqual(summary.activeActionItems.totalCount, 8)
        XCTAssertEqual(summary.activeActionItems.hiddenCount, 3)

        XCTAssertEqual(summary.unresolvedQuestions.items.count, 5)
        XCTAssertEqual(summary.unresolvedQuestions.totalCount, 7)
        XCTAssertEqual(summary.unresolvedQuestions.hiddenCount, 2)

        XCTAssertEqual(summary.upcomingAgendaItems.items.count, 5)
        XCTAssertEqual(summary.upcomingAgendaItems.totalCount, 6)
        XCTAssertEqual(summary.upcomingAgendaItems.hiddenCount, 1)
    }

    /// Truncation must keep the front of the sorted list, not an arbitrary five.
    func testTruncationKeepsTheMostUrgentWork() {
        let day: TimeInterval = 86_400
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: (1...8).map {
                Fixture.actionItem($0, title: "D+\($0)", status: .confirmed, dueDate: Self.now + Double($0) * day)
            }
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(
            summary.activeActionItems.items.map(\.actionItem.title),
            ["D+1", "D+2", "D+3", "D+4", "D+5"]
        )
    }

    func testPendingProjectListIsTruncatedWhileTheProposalTotalStaysComplete() {
        let projects = (1...7).map { index in
            Fixture.project(name: "프로젝트 \(index)", decisions: [Fixture.decision(index)])
        }

        let summary = HomeSummary(projects: projects, referenceDate: Self.now)

        XCTAssertEqual(summary.pendingProposalsByProject.items.count, 5)
        XCTAssertEqual(summary.pendingProposalsByProject.totalCount, 7)
        XCTAssertEqual(summary.pendingProposalCount, 7, "The proposal total is never truncated.")
    }

    // MARK: - Empty states

    func testEmptyStoreProducesAnEmptyButValidSummary() {
        let summary = HomeSummary(projects: [], referenceDate: Self.now)

        XCTAssertEqual(summary.projectCount, 0)
        XCTAssertEqual(summary.pendingProposalCount, 0)
        XCTAssertTrue(summary.pendingProposalsByProject.isEmpty)
        XCTAssertTrue(summary.activeActionItems.isEmpty)
        XCTAssertTrue(summary.unresolvedQuestions.isEmpty)
        XCTAssertTrue(summary.upcomingAgendaItems.isEmpty)
        XCTAssertTrue(summary.hasNothingToShow)
    }

    /// Having projects whose work is all finished is a real state, and a different one from having
    /// no projects at all.
    func testProjectsWithNothingLeftToDoAreDistinctFromNoProjects() {
        let project = Fixture.project(
            name: "끝난 프로젝트",
            actionItems: [Fixture.actionItem(1, status: .completed)]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.projectCount, 1)
        XCTAssertTrue(summary.hasNothingToShow)
    }

    // MARK: - Assignee

    /// There is no signed-in user, so the list is everyone's work and each row says whose. An
    /// unassigned task must resolve to nothing rather than to a name.
    func testUnassignedWorkResolvesToNoNameRatherThanAPlaceholder() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, status: .confirmed, assigneeID: nil)]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertNil(summary.activeActionItems.items.first?.assigneeName)
    }

    func testAssignedWorkShowsTheParticipantName() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, status: .confirmed, assigneeID: Fixture.assignee.id)]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertEqual(summary.activeActionItems.items.first?.assigneeName, "서연")
    }

    /// An id that matches nobody must not be printed raw, and must not be mistaken for a person.
    func testAnUnresolvableAssigneeIdShowsNoName() {
        let project = Fixture.project(
            name: "출시 준비",
            actionItems: [Fixture.actionItem(1, status: .confirmed, assigneeID: UUID())]
        )

        let summary = HomeSummary(projects: [project], referenceDate: Self.now)

        XCTAssertNil(summary.activeActionItems.items.first?.assigneeName)
    }

    // MARK: - Overdue

    func testOnlyWorkWithAPassedDeadlineIsOverdue() {
        let day: TimeInterval = 86_400
        let overdue = Fixture.actionItem(1, status: .confirmed, dueDate: Self.now - day)
        let upcoming = Fixture.actionItem(2, status: .confirmed, dueDate: Self.now + day)
        let undated = Fixture.actionItem(3, status: .confirmed, dueDate: nil)

        let summary = HomeSummary(projects: [], referenceDate: Self.now)

        XCTAssertTrue(summary.isOverdue(overdue))
        XCTAssertFalse(summary.isOverdue(upcoming))
        XCTAssertFalse(summary.isOverdue(undated), "A missing deadline is unknown, not breached.")
    }

    // MARK: - Round trip through storage

    /// The home reads whatever the repository returns, so the same data written and read back must
    /// produce the identical summary — otherwise the screen changes after a restart.
    func testTheSummaryIsUnchangedAfterAJSONRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let day: TimeInterval = 86_400
        let projects = [
            Fixture.project(
                name: "출시 준비",
                decisions: [Fixture.decision(1)],
                actionItems: [
                    Fixture.actionItem(1, status: .confirmed, dueDate: Self.now + day, assigneeID: Fixture.assignee.id),
                    Fixture.actionItem(2, status: .inProgress)
                ],
                openQuestions: [Fixture.question(1, reviewed: true)],
                agenda: [Fixture.agenda(1, reviewed: true)]
            ),
            Fixture.project(
                name: "고객 온보딩",
                actionItems: [Fixture.actionItem(3, status: .confirmed, dueDate: Self.now + 2 * day)]
            )
        ]

        let repository = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        for project in projects {
            try await repository.save(project)
        }

        let reloaded = try await ProjectBrowserQueryService(repository: repository).loadProjects()
        let expected = HomeSummary(projects: projects, referenceDate: Self.now)
        let actual = HomeSummary(projects: reloaded, referenceDate: Self.now)

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.activeActionItems.items.map(\.id), expected.activeActionItems.items.map(\.id))
        XCTAssertEqual(actual.activeActionItems.items.first?.assigneeName, "서연")
        XCTAssertEqual(actual.pendingProposalCount, 1)
    }

    // MARK: - Fixtures

    /// Built here rather than reusing `ReviewFixtures`, which pins one id per kind — the home is
    /// about many items across many projects, so every id has to vary.
    private enum Fixture {
        static let assignee = Participant(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            displayName: "서연",
            linkedUserID: nil,
            speakerLabel: nil
        )

        static func id(_ prefix: String, _ index: Int) -> UUID {
            UUID(uuidString: "\(prefix)-0000-0000-0000-\(String(format: "%012d", index))")!
        }

        /// A stable id per project name. Deliberately not `hashValue`, which is seeded per process
        /// and would make a round-trip comparison depend on which run it happened in.
        static func projectID(for name: String) -> UUID {
            let checksum = name.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 1_000_000_000 }
            return id("0000000A", checksum)
        }

        static func evidence(_ meetingID: UUID) -> EvidenceReference {
            EvidenceReference(
                meetingID: meetingID,
                transcriptSegmentID: TestFixtures.segmentID,
                quote: "회의에서 언급된 근거"
            )
        }

        static func project(
            name: String,
            decisions: [Decision] = [],
            actionItems: [ActionItem] = [],
            openQuestions: [OpenQuestion] = [],
            agenda: [AgendaItem] = []
        ) -> Project {
            // Derived from the name so a project keeps the same identity across the two summaries a
            // round-trip test compares, without every call site having to pass an id.
            let projectID = projectID(for: name)
            let meeting = Meeting(
                id: meetingID(for: projectID),
                projectID: projectID,
                title: "\(name) 회의",
                occurredAt: now,
                sourceType: .pastedText,
                participants: [assignee],
                transcriptSegments: [],
                createdAt: now
            )
            return Project(
                id: projectID,
                name: name,
                summary: "",
                createdAt: now,
                updatedAt: now,
                meetings: [meeting],
                decisions: decisions.map { rehome($0, projectID: projectID, meetingID: meeting.id) },
                actionItems: actionItems.map { rehome($0, projectID: projectID, meetingID: meeting.id) },
                openQuestions: openQuestions.map { rehome($0, projectID: projectID, meetingID: meeting.id) },
                nextAgenda: agenda.map { rehome($0, projectID: projectID, meetingID: meeting.id) }
            )
        }

        // MARK: Items

        static func decision(
            _ index: Int,
            status: DecisionStatus = .proposed,
            evidence: EvidenceReference? = placeholderEvidence
        ) -> Decision {
            Decision(
                id: id("0000000D", index),
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                statement: "결정 \(index)",
                rationale: nil,
                status: status,
                evidence: evidence,
                confidence: Confidence(0.8),
                createdAt: now,
                updatedAt: now
            )
        }

        static func actionItem(
            _ index: Int,
            title: String? = nil,
            status: ActionItemStatus = .proposed,
            dueDate: Date? = nil,
            assigneeID: UUID? = nil,
            evidence: EvidenceReference? = placeholderEvidence
        ) -> ActionItem {
            ActionItem(
                id: id("0000000C", index),
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                title: title ?? "업무 \(index)",
                details: nil,
                assigneeID: assigneeID,
                dueDate: dueDate,
                status: status,
                evidence: evidence,
                confidence: Confidence(0.7),
                createdAt: now,
                updatedAt: now
            )
        }

        static func question(
            _ index: Int,
            text: String? = nil,
            status: OpenQuestionStatus = .open,
            reviewed: Bool = false,
            createdAt: Date = now,
            evidence: EvidenceReference? = placeholderEvidence
        ) -> OpenQuestion {
            OpenQuestion(
                id: id("0000000B", index),
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                question: text ?? "질문 \(index)",
                status: status,
                evidence: evidence,
                confidence: Confidence(0.6),
                createdAt: createdAt,
                resolvedAt: nil,
                reviewedAt: reviewed ? now : nil
            )
        }

        static func agenda(
            _ index: Int,
            title: String? = nil,
            status: AgendaItemStatus = .pending,
            reviewed: Bool = false,
            createdAt: Date = now,
            evidence: EvidenceReference? = placeholderEvidence
        ) -> AgendaItem {
            AgendaItem(
                id: id("0000000E", index),
                projectID: TestFixtures.projectID,
                title: title ?? "아젠다 \(index)",
                reason: "이번 회의에서 결론이 나지 않음",
                sourceMeetingID: TestFixtures.meetingID,
                relatedActionItemID: nil,
                relatedOpenQuestionID: nil,
                status: status,
                createdAt: createdAt,
                evidence: evidence,
                confidence: evidence == nil ? nil : Confidence(0.5),
                reviewedAt: reviewed ? now : nil
            )
        }

        // MARK: Plumbing

        private static let now = HomeSummaryTests.now

        /// A stand-in replaced by `rehome` once the owning project is known. Non-nil so the
        /// pending-proposal policy sees an AI-derived record; callers pass nil to model a
        /// hand-entered one.
        private static let placeholderEvidence = EvidenceReference(
            meetingID: TestFixtures.meetingID,
            transcriptSegmentID: TestFixtures.segmentID,
            quote: "회의에서 언급된 근거"
        )

        private static func meetingID(for projectID: UUID) -> UUID {
            UUID(uuidString: "0000000F" + projectID.uuidString.dropFirst(8))!
        }

        private static func rehome(_ value: Decision, projectID: UUID, meetingID: UUID) -> Decision {
            Decision(
                id: value.id,
                projectID: projectID,
                meetingID: meetingID,
                statement: value.statement,
                rationale: value.rationale,
                status: value.status,
                evidence: value.evidence.map { _ in evidence(meetingID) },
                confidence: value.confidence,
                createdAt: value.createdAt,
                updatedAt: value.updatedAt
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

        private static func rehome(_ value: OpenQuestion, projectID: UUID, meetingID: UUID) -> OpenQuestion {
            OpenQuestion(
                id: value.id,
                projectID: projectID,
                meetingID: meetingID,
                question: value.question,
                status: value.status,
                evidence: value.evidence.map { _ in evidence(meetingID) },
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
                evidence: value.evidence.map { _ in evidence(meetingID) },
                confidence: value.confidence,
                reviewedAt: value.reviewedAt
            )
        }
    }
}
