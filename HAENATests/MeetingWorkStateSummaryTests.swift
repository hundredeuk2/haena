import XCTest
@testable import HAENA

/// Covers the rules the meeting results screen is not allowed to own: which results belong to a
/// meeting, how far each one has been through review, and in what order they are shown.
final class MeetingWorkStateSummaryTests: XCTestCase {
    private typealias Fixtures = MeetingResultFixtures

    private func summary(_ project: Project, meetingID: UUID = Fixtures.meetingA) -> MeetingWorkStateSummary {
        MeetingWorkStateSummary(project: project, meetingID: meetingID)
    }

    // MARK: - 1-6. Meeting attribution

    func testIncludesOnlyDecisionsFromThisMeeting() {
        let mine = Fixtures.decision(id: Fixtures.uuid(1), status: .confirmed)
        let theirs = Fixtures.decision(
            id: Fixtures.uuid(2),
            fromMeeting: Fixtures.meetingB,
            status: .confirmed
        )

        let result = summary(Fixtures.project(decisions: [mine, theirs]))

        XCTAssertEqual(result.decisions.reviewed.map(\.id), [mine.id])
        XCTAssertEqual(result.decisions.totalCount, 1)
    }

    func testIncludesOnlyActionItemsFromThisMeeting() {
        let mine = Fixtures.actionItem(id: Fixtures.uuid(1), status: .confirmed)
        let theirs = Fixtures.actionItem(
            id: Fixtures.uuid(2),
            fromMeeting: Fixtures.meetingB,
            status: .confirmed
        )

        let result = summary(Fixtures.project(actionItems: [mine, theirs]))

        XCTAssertEqual(result.actionItems.reviewed.map(\.id), [mine.id])
    }

    func testIncludesOnlyOpenQuestionsFromThisMeeting() {
        let mine = Fixtures.openQuestion(id: Fixtures.uuid(1), reviewedAt: TestFixtures.laterDate)
        let theirs = Fixtures.openQuestion(
            id: Fixtures.uuid(2),
            fromMeeting: Fixtures.meetingB,
            reviewedAt: TestFixtures.laterDate
        )

        let result = summary(Fixtures.project(openQuestions: [mine, theirs]))

        XCTAssertEqual(result.openQuestions.reviewed.map(\.id), [mine.id])
    }

    func testIncludesOnlyAgendaItemsWhoseSourceMeetingMatches() {
        let mine = Fixtures.agendaItem(id: Fixtures.uuid(1), reviewedAt: TestFixtures.laterDate)
        let theirs = Fixtures.agendaItem(
            id: Fixtures.uuid(2),
            fromMeeting: Fixtures.meetingB,
            reviewedAt: TestFixtures.laterDate
        )

        let result = summary(Fixtures.project(nextAgenda: [mine, theirs]))

        XCTAssertEqual(result.agendaItems.reviewed.map(\.id), [mine.id])
    }

    /// The whole-project version of the four tests above: with every kind present for both
    /// meetings, neither meeting's summary may contain a single record from the other.
    func testEveryResultFromAnotherMeetingIsExcluded() {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(2), fromMeeting: Fixtures.meetingB, status: .confirmed)
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(3), status: .confirmed),
                Fixtures.actionItem(id: Fixtures.uuid(4), fromMeeting: Fixtures.meetingB, status: .confirmed)
            ],
            openQuestions: [
                Fixtures.openQuestion(id: Fixtures.uuid(5), reviewedAt: TestFixtures.laterDate),
                Fixtures.openQuestion(
                    id: Fixtures.uuid(6),
                    fromMeeting: Fixtures.meetingB,
                    reviewedAt: TestFixtures.laterDate
                )
            ],
            nextAgenda: [
                Fixtures.agendaItem(id: Fixtures.uuid(7), reviewedAt: TestFixtures.laterDate),
                Fixtures.agendaItem(
                    id: Fixtures.uuid(8),
                    fromMeeting: Fixtures.meetingB,
                    reviewedAt: TestFixtures.laterDate
                )
            ]
        )

        let first = summary(project, meetingID: Fixtures.meetingA)
        let second = summary(project, meetingID: Fixtures.meetingB)

        XCTAssertEqual(first.decisions.reviewed.map(\.id), [Fixtures.uuid(1)])
        XCTAssertEqual(first.actionItems.reviewed.map(\.id), [Fixtures.uuid(3)])
        XCTAssertEqual(first.openQuestions.reviewed.map(\.id), [Fixtures.uuid(5)])
        XCTAssertEqual(first.agendaItems.reviewed.map(\.id), [Fixtures.uuid(7)])

        XCTAssertEqual(second.decisions.reviewed.map(\.id), [Fixtures.uuid(2)])
        XCTAssertEqual(second.actionItems.reviewed.map(\.id), [Fixtures.uuid(4)])
        XCTAssertEqual(second.openQuestions.reviewed.map(\.id), [Fixtures.uuid(6)])
        XCTAssertEqual(second.agendaItems.reviewed.map(\.id), [Fixtures.uuid(8)])
    }

    /// A record that names a different project cannot show up as this project's meeting output,
    /// even if it is sitting in this project's array and points at this meeting.
    func testResultsBelongingToAnotherProjectAreExcluded() {
        let foreign = Fixtures.decision(
            id: Fixtures.uuid(1),
            inProject: Fixtures.projectB,
            status: .confirmed
        )
        let foreignAgenda = Fixtures.agendaItem(
            id: Fixtures.uuid(2),
            inProject: Fixtures.projectB,
            reviewedAt: TestFixtures.laterDate
        )

        let result = summary(Fixtures.project(decisions: [foreign], nextAgenda: [foreignAgenda]))

        XCTAssertTrue(result.decisions.reviewed.isEmpty)
        XCTAssertTrue(result.agendaItems.reviewed.isEmpty)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - 7. Pending judgement matches the shared policy

    /// Every combination of status, evidence and review marker, compared against
    /// `PendingAIProposalPolicy` directly. If the two ever disagree, a proposal can be shown as
    /// settled here while re-extraction still treats it as replaceable.
    func testNeedsReviewAgreesWithPendingAIProposalPolicyForEveryCombination() {
        let evidenceCases: [EvidenceReference?] = [Fixtures.evidenceA, nil]
        var index = 100

        for evidence in evidenceCases {
            for status in [DecisionStatus.proposed, .confirmed, .superseded, .rejected] {
                index += 1
                let decision = Fixtures.decision(id: Fixtures.uuid(index), status: status, evidence: evidence)
                let area = summary(Fixtures.project(decisions: [decision])).decisions
                XCTAssertEqual(
                    area.needsReview.map(\.id),
                    PendingAIProposalPolicy.isPending(decision) ? [decision.id] : [],
                    "Decision status \(status), evidence \(evidence == nil ? "nil" : "set")"
                )
            }

            for status in [ActionItemStatus.proposed, .confirmed, .inProgress, .completed, .cancelled] {
                index += 1
                let item = Fixtures.actionItem(id: Fixtures.uuid(index), status: status, evidence: evidence)
                let area = summary(Fixtures.project(actionItems: [item])).actionItems
                XCTAssertEqual(
                    area.needsReview.map(\.id),
                    PendingAIProposalPolicy.isPending(item) ? [item.id] : [],
                    "ActionItem status \(status), evidence \(evidence == nil ? "nil" : "set")"
                )
            }

            for status in [OpenQuestionStatus.open, .resolved, .dismissed] {
                for reviewedAt in [nil, TestFixtures.laterDate] as [Date?] {
                    index += 1
                    let question = Fixtures.openQuestion(
                        id: Fixtures.uuid(index),
                        status: status,
                        evidence: evidence,
                        reviewedAt: reviewedAt
                    )
                    let area = summary(Fixtures.project(openQuestions: [question])).openQuestions
                    XCTAssertEqual(
                        area.needsReview.map(\.id),
                        PendingAIProposalPolicy.isPending(question) ? [question.id] : [],
                        "OpenQuestion status \(status), reviewedAt \(reviewedAt == nil ? "nil" : "set")"
                    )
                }
            }

            for status in [AgendaItemStatus.pending, .resolved, .dismissed] {
                for reviewedAt in [nil, TestFixtures.laterDate] as [Date?] {
                    index += 1
                    let item = Fixtures.agendaItem(
                        id: Fixtures.uuid(index),
                        status: status,
                        evidence: evidence,
                        reviewedAt: reviewedAt
                    )
                    let area = summary(Fixtures.project(nextAgenda: [item])).agendaItems
                    XCTAssertEqual(
                        area.needsReview.map(\.id),
                        PendingAIProposalPolicy.isPending(item) ? [item.id] : [],
                        "AgendaItem status \(status), reviewedAt \(reviewedAt == nil ? "nil" : "set")"
                    )
                }
            }
        }
    }

    /// The live list is the app's existing project-wide selection, narrowed to one meeting — not a
    /// second opinion about what counts as live.
    func testReviewedMatchesWorkStateInboxNarrowedToTheMeeting() {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(2), status: .rejected),
                Fixtures.decision(id: Fixtures.uuid(3), fromMeeting: Fixtures.meetingB, status: .confirmed)
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(4), status: .inProgress),
                Fixtures.actionItem(id: Fixtures.uuid(5), status: .completed)
            ],
            openQuestions: [
                Fixtures.openQuestion(id: Fixtures.uuid(6), reviewedAt: TestFixtures.laterDate),
                Fixtures.openQuestion(id: Fixtures.uuid(7), status: .resolved)
            ],
            nextAgenda: [
                Fixtures.agendaItem(id: Fixtures.uuid(8), reviewedAt: TestFixtures.laterDate),
                Fixtures.agendaItem(id: Fixtures.uuid(9), status: .dismissed)
            ]
        )
        let result = summary(project)

        XCTAssertEqual(
            result.decisions.reviewed.map(\.id),
            WorkStateInbox.confirmedDecisions(in: project)
                .filter { $0.meetingID == Fixtures.meetingA }
                .map(\.id)
        )
        XCTAssertEqual(
            Set(result.actionItems.reviewed.map(\.id)),
            Set(
                WorkStateInbox.activeActionItems(in: project)
                    .filter { $0.meetingID == Fixtures.meetingA }
                    .map(\.id)
            )
        )
        XCTAssertEqual(
            result.openQuestions.reviewed.map(\.id),
            WorkStateInbox.reviewedOpenQuestions(in: project)
                .filter { $0.meetingID == Fixtures.meetingA }
                .map(\.id)
        )
        XCTAssertEqual(
            result.agendaItems.reviewed.map(\.id),
            WorkStateInbox.reviewedAgendaItems(in: project)
                .filter { $0.sourceMeetingID == Fixtures.meetingA }
                .map(\.id)
        )
    }

    // MARK: - 8. Approval moves a result out of 확인 필요

    func testApprovingMovesEachKindFromNeedsReviewToReviewed() {
        let proposed = Fixtures.project(
            decisions: [Fixtures.decision(id: Fixtures.uuid(1))],
            actionItems: [Fixtures.actionItem(id: Fixtures.uuid(2))],
            openQuestions: [Fixtures.openQuestion(id: Fixtures.uuid(3))],
            nextAgenda: [Fixtures.agendaItem(id: Fixtures.uuid(4))]
        )
        let before = summary(proposed)

        XCTAssertEqual(before.decisions.needsReview.count, 1)
        XCTAssertEqual(before.actionItems.needsReview.count, 1)
        XCTAssertEqual(before.openQuestions.needsReview.count, 1)
        XCTAssertEqual(before.agendaItems.needsReview.count, 1)
        XCTAssertTrue(before.decisions.reviewed.isEmpty)
        XCTAssertTrue(before.actionItems.reviewed.isEmpty)
        XCTAssertTrue(before.openQuestions.reviewed.isEmpty)
        XCTAssertTrue(before.agendaItems.reviewed.isEmpty)

        let approved = Fixtures.project(
            decisions: [Fixtures.decision(id: Fixtures.uuid(1), status: .confirmed)],
            actionItems: [Fixtures.actionItem(id: Fixtures.uuid(2), status: .confirmed)],
            openQuestions: [Fixtures.openQuestion(id: Fixtures.uuid(3), reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [Fixtures.agendaItem(id: Fixtures.uuid(4), reviewedAt: TestFixtures.laterDate)]
        )
        let after = summary(approved)

        XCTAssertTrue(after.decisions.needsReview.isEmpty)
        XCTAssertTrue(after.actionItems.needsReview.isEmpty)
        XCTAssertTrue(after.openQuestions.needsReview.isEmpty)
        XCTAssertTrue(after.agendaItems.needsReview.isEmpty)
        XCTAssertEqual(after.decisions.reviewed.map(\.id), [Fixtures.uuid(1)])
        XCTAssertEqual(after.actionItems.reviewed.map(\.id), [Fixtures.uuid(2)])
        XCTAssertEqual(after.openQuestions.reviewed.map(\.id), [Fixtures.uuid(3)])
        XCTAssertEqual(after.agendaItems.reviewed.map(\.id), [Fixtures.uuid(4)])
    }

    // MARK: - 9. Closed-out results move to 처리됨 and are never dropped

    func testClosedOutResultsMoveToProcessedRatherThanDisappearing() {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1), status: .rejected),
                Fixtures.decision(id: Fixtures.uuid(2), status: .superseded)
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(3), status: .completed),
                Fixtures.actionItem(id: Fixtures.uuid(4), status: .cancelled)
            ],
            openQuestions: [
                Fixtures.openQuestion(id: Fixtures.uuid(5), status: .resolved),
                Fixtures.openQuestion(id: Fixtures.uuid(6), status: .dismissed)
            ],
            nextAgenda: [
                Fixtures.agendaItem(id: Fixtures.uuid(7), status: .resolved),
                Fixtures.agendaItem(id: Fixtures.uuid(8), status: .dismissed)
            ]
        )
        let result = summary(project)

        XCTAssertEqual(result.decisions.processed.count, 2)
        XCTAssertEqual(result.actionItems.processed.count, 2)
        XCTAssertEqual(result.openQuestions.processed.count, 2)
        XCTAssertEqual(result.agendaItems.processed.count, 2)

        // Nothing is live, so every section reads as empty — while still accounting for all eight.
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.decisions.activeCount, 0)
        XCTAssertEqual(result.decisions.totalCount, 2)
        XCTAssertEqual(result.actionItems.totalCount, 2)
        XCTAssertEqual(result.openQuestions.totalCount, 2)
        XCTAssertEqual(result.agendaItems.totalCount, 2)
    }

    // MARK: - 10. The three buckets never overlap, and never lose a record

    func testBucketsArePartitionsOfEveryResultInScope() {
        let decisions = [DecisionStatus.proposed, .confirmed, .superseded, .rejected].enumerated().map {
            Fixtures.decision(id: Fixtures.uuid(200 + $0.offset), status: $0.element)
        }
        let actionItems = [ActionItemStatus.proposed, .confirmed, .inProgress, .completed, .cancelled]
            .enumerated()
            .map { Fixtures.actionItem(id: Fixtures.uuid(210 + $0.offset), status: $0.element) }
        let openQuestions = [OpenQuestionStatus.open, .resolved, .dismissed].enumerated().map {
            Fixtures.openQuestion(id: Fixtures.uuid(220 + $0.offset), status: $0.element)
        }
        let agenda = [AgendaItemStatus.pending, .resolved, .dismissed].enumerated().map {
            Fixtures.agendaItem(id: Fixtures.uuid(230 + $0.offset), status: $0.element)
        }

        let result = summary(
            Fixtures.project(
                decisions: decisions,
                actionItems: actionItems,
                openQuestions: openQuestions,
                nextAgenda: agenda
            )
        )

        assertPartition(
            needsReview: result.decisions.needsReview.map(\.id),
            reviewed: result.decisions.reviewed.map(\.id),
            processed: result.decisions.processed.map(\.id),
            expected: decisions.map(\.id),
            label: "Decision"
        )
        assertPartition(
            needsReview: result.actionItems.needsReview.map(\.id),
            reviewed: result.actionItems.reviewed.map(\.id),
            processed: result.actionItems.processed.map(\.id),
            expected: actionItems.map(\.id),
            label: "ActionItem"
        )
        assertPartition(
            needsReview: result.openQuestions.needsReview.map(\.id),
            reviewed: result.openQuestions.reviewed.map(\.id),
            processed: result.openQuestions.processed.map(\.id),
            expected: openQuestions.map(\.id),
            label: "OpenQuestion"
        )
        assertPartition(
            needsReview: result.agendaItems.needsReview.map(\.id),
            reviewed: result.agendaItems.reviewed.map(\.id),
            processed: result.agendaItems.processed.map(\.id),
            expected: agenda.map(\.id),
            label: "AgendaItem"
        )
    }

    private func assertPartition(
        needsReview: [UUID],
        reviewed: [UUID],
        processed: [UUID],
        expected: [UUID],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let all = needsReview + reviewed + processed
        XCTAssertEqual(
            Set(all),
            Set(expected),
            "\(label): every record in scope must land in exactly one bucket",
            file: file,
            line: line
        )
        XCTAssertEqual(
            all.count,
            expected.count,
            "\(label): a record appears in more than one bucket",
            file: file,
            line: line
        )
    }

    // MARK: - 11. Due-date ordering

    func testActiveWorkIsOrderedByDueDateWithUndatedWorkLast() {
        let soon = TestFixtures.fixedDate.addingTimeInterval(3_600)
        let later = TestFixtures.fixedDate.addingTimeInterval(86_400)

        let project = Fixtures.project(
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(1), dueDate: nil, status: .confirmed),
                Fixtures.actionItem(id: Fixtures.uuid(2), dueDate: later, status: .confirmed),
                Fixtures.actionItem(id: Fixtures.uuid(3), dueDate: soon, status: .inProgress)
            ]
        )

        XCTAssertEqual(
            summary(project).actionItems.reviewed.map(\.id),
            [Fixtures.uuid(3), Fixtures.uuid(2), Fixtures.uuid(1)]
        )
    }

    // MARK: - 12. Deterministic order on ties

    func testOrderIsTotalWhenTimestampsAreIdentical() {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1)),
                Fixtures.decision(id: Fixtures.uuid(2)),
                Fixtures.decision(id: Fixtures.uuid(3), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(4), status: .confirmed)
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(5), status: .confirmed),
                Fixtures.actionItem(id: Fixtures.uuid(6), status: .confirmed)
            ]
        )

        // Everything shares one timestamp, so only the id can decide — and it must decide the same
        // way every time the same data is read.
        let first = summary(project)
        let second = summary(project)
        XCTAssertEqual(first, second)

        // Proposals: oldest first, then ascending id.
        XCTAssertEqual(first.decisions.needsReview.map(\.id), [Fixtures.uuid(1), Fixtures.uuid(2)])
        // Confirmed decisions: most recently touched first, then descending id.
        XCTAssertEqual(first.decisions.reviewed.map(\.id), [Fixtures.uuid(4), Fixtures.uuid(3)])
        // Undated work: ascending id.
        XCTAssertEqual(first.actionItems.reviewed.map(\.id), [Fixtures.uuid(5), Fixtures.uuid(6)])

        // Reversing the stored order must not change what is rendered.
        let reversed = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(4), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(3), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(2)),
                Fixtures.decision(id: Fixtures.uuid(1))
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(6), status: .confirmed),
                Fixtures.actionItem(id: Fixtures.uuid(5), status: .confirmed)
            ]
        )
        XCTAssertEqual(summary(reversed), first)
    }

    // MARK: - 13. Nothing to show

    func testEmptyProjectAndMeetingWithNoResults() {
        let empty = Fixtures.project()
        let result = summary(empty)

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.decisions.activeCount, 0)
        XCTAssertEqual(result.actionItems.totalCount, 0)
        XCTAssertTrue(result.openQuestions.processed.isEmpty)
        XCTAssertTrue(result.agendaItems.needsReview.isEmpty)

        // A meeting the project does not contain yields an empty summary rather than the project's
        // whole work state.
        let unknown = summary(empty, meetingID: Fixtures.uuid(999))
        XCTAssertTrue(unknown.isEmpty)
        XCTAssertEqual(unknown.decisions.totalCount, 0)
    }

    // MARK: - 14. Hand-entered results

    /// A record someone typed in has no evidence, so it is not an AI proposal — but it is still
    /// live, and it still belongs to the meeting it names. It must be shown, not silently dropped
    /// and not presented as something waiting on review.
    func testHandEnteredResultsWithNoEvidenceAreShownAsLive() {
        let project = Fixtures.project(
            decisions: [Fixtures.decision(id: Fixtures.uuid(1), evidence: nil)],
            actionItems: [Fixtures.actionItem(id: Fixtures.uuid(2), evidence: nil)],
            openQuestions: [Fixtures.openQuestion(id: Fixtures.uuid(3), evidence: nil)],
            nextAgenda: [Fixtures.agendaItem(id: Fixtures.uuid(4), evidence: nil)]
        )
        let result = summary(project)

        XCTAssertTrue(result.decisions.needsReview.isEmpty)
        XCTAssertTrue(result.actionItems.needsReview.isEmpty)
        XCTAssertTrue(result.openQuestions.needsReview.isEmpty)
        XCTAssertTrue(result.agendaItems.needsReview.isEmpty)

        XCTAssertEqual(result.decisions.reviewed.map(\.id), [Fixtures.uuid(1)])
        XCTAssertEqual(result.actionItems.reviewed.map(\.id), [Fixtures.uuid(2)])
        XCTAssertEqual(result.openQuestions.reviewed.map(\.id), [Fixtures.uuid(3)])
        XCTAssertEqual(result.agendaItems.reviewed.map(\.id), [Fixtures.uuid(4)])
    }

    // MARK: - 15. Agenda items with no source meeting

    func testAgendaItemWithNoSourceMeetingIsNotAttributedToAnyMeeting() {
        let orphan = Fixtures.agendaItem(
            id: Fixtures.uuid(1),
            fromMeeting: nil,
            evidence: nil,
            reviewedAt: TestFixtures.laterDate
        )
        let project = Fixtures.project(nextAgenda: [orphan])

        XCTAssertTrue(summary(project, meetingID: Fixtures.meetingA).agendaItems.isEmpty)
        XCTAssertTrue(summary(project, meetingID: Fixtures.meetingB).agendaItems.isEmpty)
        // It is still the project's agenda item — only this screen has nowhere to put it.
        XCTAssertEqual(WorkStateInbox.reviewedAgendaItems(in: project).map(\.id), [orphan.id])
    }

    /// Evidence naming a meeting is not a substitute for the direct link. An item whose quote came
    /// from meeting A but which carries no `sourceMeetingID` belongs to neither meeting.
    func testEvidenceAloneDoesNotAttributeAnAgendaItemToAMeeting() {
        let project = Fixtures.project(
            nextAgenda: [
                Fixtures.agendaItem(
                    id: Fixtures.uuid(1),
                    fromMeeting: nil,
                    evidence: Fixtures.evidenceA,
                    reviewedAt: TestFixtures.laterDate
                )
            ]
        )

        XCTAssertTrue(summary(project).agendaItems.isEmpty)
    }

    // MARK: - 16. Survives a round trip through storage

    func testSummaryIsUnchangedAfterSavingAndReloading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-MeetingResults-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1)),
                Fixtures.decision(id: Fixtures.uuid(2), status: .confirmed),
                Fixtures.decision(id: Fixtures.uuid(3), status: .rejected)
            ],
            actionItems: [
                Fixtures.actionItem(
                    id: Fixtures.uuid(4),
                    assigneeID: Fixtures.assignee.id,
                    dueDate: TestFixtures.laterDate,
                    status: .confirmed
                )
            ],
            openQuestions: [Fixtures.openQuestion(id: Fixtures.uuid(5), reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [Fixtures.agendaItem(id: Fixtures.uuid(6), reviewedAt: TestFixtures.laterDate)]
        )

        let repository = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        try await repository.save(project)
        let reloaded = try await repository.project(id: project.id)

        let loaded = try XCTUnwrap(reloaded)
        XCTAssertEqual(summary(loaded), summary(project))
    }

    // MARK: - Evidence timestamps

    func testEvidenceTimestampComesFromTheReferencedSegment() {
        let meeting = Fixtures.meeting(startTime: 65)

        XCTAssertEqual(
            MeetingWorkStateSummary.evidenceTimestamp(Fixtures.evidenceA, in: meeting),
            "01:05"
        )
    }

    func testEvidenceTimestampIsNilWhenItCannotBeAnsweredTruthfully() {
        let untimed = Fixtures.meeting(startTime: nil)
        XCTAssertNil(MeetingWorkStateSummary.evidenceTimestamp(Fixtures.evidenceA, in: untimed))

        let timed = Fixtures.meeting(startTime: 65)
        XCTAssertNil(MeetingWorkStateSummary.evidenceTimestamp(nil, in: timed))

        // Evidence pointing at a segment this meeting does not have.
        let missingSegment = EvidenceReference(
            meetingID: Fixtures.meetingA,
            transcriptSegmentID: Fixtures.uuid(998),
            quote: "없는 구간"
        )
        XCTAssertNil(MeetingWorkStateSummary.evidenceTimestamp(missingSegment, in: timed))

        // Evidence from a different meeting entirely.
        XCTAssertNil(MeetingWorkStateSummary.evidenceTimestamp(Fixtures.evidenceB, in: timed))
    }
}
