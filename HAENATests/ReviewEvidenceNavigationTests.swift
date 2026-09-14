#if DEBUG
import XCTest
@testable import HAENA

/// Task 2.6: a stored source quote leads to its owning meeting's transcript at the exact stored
/// segment, or honestly nowhere. Nothing here matches text or invents a position.
@MainActor
final class ReviewEvidenceNavigationTests: XCTestCase {
    private typealias F = ReviewQueueUITestSeed
    private var project: Project { F.project(.evidence) }
    private func entries(_ p: Project) -> [ReviewQueue.Entry] { ReviewQueue(project: p).groups.flatMap(\.entries) }
    private func entry(_ n: Int, in p: Project) -> ReviewQueue.Entry? { entries(p).first { $0.proposal.id == F.id(n) } }

    // MARK: - Exact stored IDs

    func testEvidenceScenarioExtendsQueueWithoutChangingPendingSet() {
        let base = F.project(.queue)
        XCTAssertEqual(entries(project).map(\.id), entries(base).map(\.id))
        XCTAssertEqual(ReviewQueue(project: project).pendingCount, 5)
        XCTAssertEqual(project.meetings[0].transcriptSegments.map(\.id), [F.id(8), F.id(4), F.id(7)])
        XCTAssertEqual(project.meetings[0].transcriptSegments[0].text, project.meetings[0].transcriptSegments[1].text)
    }

    func testSelectionUsesStoredMeetingAndSegmentIDs() {
        for n in [100, 101, 102] {
            XCTAssertEqual(entry(n, in: project)?.transcriptSelection, .init(meetingID: F.id(2), segmentID: F.id(4)), "\(n)")
        }
        XCTAssertEqual(entry(103, in: project)?.transcriptSelection, .init(meetingID: F.id(2), segmentID: F.id(7)))
        XCTAssertEqual(entry(104, in: project)?.transcriptSelection, .init(meetingID: F.id(3), segmentID: F.id(5)))
        for e in entries(project) {
            XCTAssertEqual(e.transcriptSelection?.meetingID, e.proposal.meetingID)
            XCTAssertEqual(e.transcriptSelection?.segmentID, e.proposal.evidence?.transcriptSegmentID)
        }
    }

    func testMultipleProposalsInOneMeetingKeepTheirOwnSegment() {
        let decision = entry(100, in: project)!, agenda = entry(103, in: project)!
        XCTAssertEqual(decision.transcriptSelection?.meetingID, agenda.transcriptSelection?.meetingID)
        XCTAssertNotEqual(decision.transcriptSelection?.segmentID, agenda.transcriptSelection?.segmentID)
        XCTAssertEqual(decision.timestamp, "01:05"); XCTAssertEqual(agenda.timestamp, "02:05")
    }

    func testIdenticalTextInAnotherSegmentIsNeverSelected() {
        let duplicate = project.meetings[0].transcriptSegments[0]
        XCTAssertEqual(duplicate.text, entry(100, in: project)?.proposal.evidence?.quote)
        XCTAssertFalse(entries(project).contains { $0.transcriptSelection?.segmentID == duplicate.id })
        XCTAssertEqual(entry(100, in: project)?.timestamp, "01:05", "the earlier duplicate at 00:05 is not borrowed")
    }

    // MARK: - Pasted transcript and missing audio

    func testPastedTranscriptNavigatesByStoredIDWithoutTimestampOrAudio() {
        let pasted = project.meetings[1]
        XCTAssertEqual(pasted.sourceType, .pastedText); XCTAssertNil(pasted.audioAsset)
        let e = entry(104, in: project)!
        XCTAssertEqual(e.transcriptSelection, .init(meetingID: pasted.id, segmentID: F.id(5)))
        XCTAssertNil(e.timestamp); XCTAssertNil(e.sourceIssue)
        XCTAssertNil(MeetingWorkStateSummary.evidenceTimestamp(e.proposal.evidence, in: pasted))
    }

    func testRecordedMeetingWithoutStoredAudioStillNavigatesFromTranscriptTiming() {
        var p = project; p.meetings[0].audioAsset = nil
        XCTAssertEqual(p.meetings[0].sourceType, .audioFile)
        let e = entry(100, in: p)!
        XCTAssertEqual(e.transcriptSelection?.segmentID, F.id(4))
        XCTAssertEqual(e.timestamp, "01:05", "timing comes from the stored segment, not from audio")
    }

    // MARK: - Unavailable references keep the quote and offer no navigation

    func testMissingSegmentKeepsQuoteWithoutSelection() {
        for e in ReviewQueue(project: F.project(.missingSource)).groups[0].entries {
            XCTAssertEqual(e.sourceIssue, .missingSegment)
            XCTAssertNil(e.transcriptSelection); XCTAssertNil(e.timestamp)
            XCTAssertEqual(e.proposal.evidence?.quote, "Synthetic exact source quote.")
        }
    }

    func testDanglingMeetingHasNoSelection() {
        var p = project; p.meetings.removeFirst()
        let group = ReviewQueue(project: p).groups.first { $0.id == F.id(2) }!
        XCTAssertTrue(group.entries.allSatisfy { $0.sourceIssue == .missingMeeting && $0.transcriptSelection == nil })
        XCTAssertEqual(group.entries.map { $0.proposal.evidence?.quote }.compactMap { $0 }.count, 4)
    }

    func testCrossMeetingReferenceIsNotRetargeted() {
        var p = project
        p.actionItems[1].evidence = p.actionItems[2].evidence
        let e = entry(101, in: p)!
        XCTAssertEqual(e.sourceIssue, .differentMeeting)
        XCTAssertNil(e.transcriptSelection)
        XCTAssertEqual(e.proposal.evidence?.transcriptSegmentID, F.id(5), "the stored reference itself is untouched")
    }

    func testUnassignedOwnerHasNoSelectionEvenThoughEvidenceMeetingExists() {
        var p = project; p.nextAgenda[1].sourceMeetingID = nil
        let e = ReviewQueue(project: p).groups.first { $0.id == nil }!.entries[0]
        XCTAssertEqual(e.sourceIssue, .noOwningMeeting); XCTAssertNil(e.transcriptSelection)
    }

    func testEmptyTranscriptSelectsNothingRatherThanNearestSegment() {
        var p = project
        p.meetings[0].transcriptSegments = [p.meetings[0].transcriptSegments[0]] // only the same-text duplicate remains
        let e = entry(100, in: p)!
        XCTAssertEqual(e.sourceIssue, .missingSegment); XCTAssertNil(e.transcriptSelection); XCTAssertNil(e.timestamp)
    }

    // MARK: - Typed route and shell state

    func testRouteOpensOwningMeetingTranscriptAtExactSegment() {
        let selection = entry(100, in: project)!.transcriptSelection!
        let route = BrowserDestination.transcriptEvidence(projectID: project.id, selection)
        XCTAssertEqual(route.target, .transcriptEvidence(selection))
        XCTAssertEqual(route.meetingID, F.id(2)); XCTAssertEqual(route.pane, .meetings)
        XCTAssertNil(route.selection); XCTAssertNil(route.actionItemID)
        var nav = AppShellNavigation(); nav.open(route)
        XCTAssertEqual(nav.destination, .transcripts)
        XCTAssertEqual(nav.projectID, project.id); XCTAssertEqual(nav.meetingID, F.id(2))
        XCTAssertEqual(nav.meetingPane, .transcript); XCTAssertEqual(nav.projectPane, .meetings)
        XCTAssertEqual(nav.transcriptSelection, selection)
        XCTAssertEqual(nav.highlightedSegmentID(in: F.id(2)), F.id(4))
        XCTAssertNil(nav.highlightedSegmentID(in: F.id(3)), "the other meeting never inherits the highlight")
        XCTAssertNil(nav.workStateSelection)
    }

    func testRouteMeetingComesFromTheStoredReferenceNotTheCaller() {
        let selection = TranscriptEvidenceSelection(meetingID: F.id(3), segmentID: F.id(5))
        let mismatched = BrowserDestination(projectID: project.id, meetingID: F.id(2), target: .transcriptEvidence(selection))
        var nav = AppShellNavigation(); nav.open(mismatched)
        XCTAssertEqual(nav.meetingID, F.id(3))
        XCTAssertEqual(nav.highlightedSegmentID(in: F.id(3)), F.id(5)); XCTAssertNil(nav.highlightedSegmentID(in: F.id(2)))
    }

    func testSelectionChangeReplacesHighlightWithNewExactSegment() {
        var nav = AppShellNavigation()
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        let first = nav.requestID
        nav.open(.transcriptEvidence(projectID: project.id, entry(103, in: project)!.transcriptSelection!))
        XCTAssertNotEqual(nav.requestID, first)
        XCTAssertEqual(nav.highlightedSegmentID(in: F.id(2)), F.id(7))
        nav.open(.transcriptEvidence(projectID: project.id, entry(104, in: project)!.transcriptSelection!))
        XCTAssertEqual(nav.meetingID, F.id(3)); XCTAssertEqual(nav.highlightedSegmentID(in: F.id(3)), F.id(5))
        XCTAssertNil(nav.highlightedSegmentID(in: F.id(2)))
    }

    func testHighlightIsOneShotLikeApprovedSelection() {
        var nav = AppShellNavigation()
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        nav.select(.review)
        XCTAssertNil(nav.transcriptSelection); XCTAssertEqual(nav.meetingID, F.id(2), "the meeting stays selected")
        nav.select(.transcripts)
        XCTAssertEqual(nav.meetingPane, .transcript); XCTAssertNil(nav.highlightedSegmentID(in: F.id(2)))
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        nav.open(.init(projectID: project.id, target: .pendingReview))
        XCTAssertNil(nav.transcriptSelection, "a different explicit request replaces the one-shot highlight")
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        nav.selectProject(UUID())
        XCTAssertNil(nav.transcriptSelection)
    }

    func testManualMeetingSwitchNeverCarriesTheHighlight() {
        var nav = AppShellNavigation()
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        nav.meetingID = F.id(3)
        XCTAssertNil(nav.highlightedSegmentID(in: F.id(3)))
        XCTAssertNil(nav.highlightedSegmentID(in: F.id(2)), "the request is bound to the meeting on screen")
        nav.validate(in: [project])
        XCTAssertNil(nav.transcriptSelection)
    }

    func testValidationDropsHighlightWithItsMissingMeeting() {
        var nav = AppShellNavigation()
        nav.open(.transcriptEvidence(projectID: project.id, entry(100, in: project)!.transcriptSelection!))
        var gone = project; gone.meetings.removeFirst()
        nav.validate(in: [gone])
        XCTAssertEqual(nav.projectID, project.id); XCTAssertNil(nav.meetingID); XCTAssertNil(nav.transcriptSelection)
    }

    // MARK: - Identity and pending state survive navigation

    func testNavigationPreservesProposalIdentityPendingStateAndStoredBytes() throws {
        let p = project; let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(p); let ids = entries(p).map(\.id)
        var nav = AppShellNavigation()
        for e in entries(p) {
            nav.open(.transcriptEvidence(projectID: p.id, e.transcriptSelection!))
            nav.validate(in: [p]); nav.select(.review)
        }
        XCTAssertEqual(try encoder.encode(p), before)
        XCTAssertEqual(entries(p).map(\.id), ids)
        XCTAssertEqual(ReviewQueue(project: p).pendingCount, 5)
        XCTAssertEqual(Set(WorkStateInbox.pendingProposals(in: p).map(\.id)), Set(entries(p).map { $0.proposal.id }))
        XCTAssertTrue(entries(p).allSatisfy { isPending($0.proposal) })
    }

    private func isPending(_ proposal: WorkStateProposal) -> Bool {
        switch proposal {
        case .decision(let v): PendingAIProposalPolicy.isPending(v)
        case .actionItem(let v): PendingAIProposalPolicy.isPending(v)
        case .openQuestion(let v): PendingAIProposalPolicy.isPending(v)
        case .agendaItem(let v): PendingAIProposalPolicy.isPending(v)
        }
    }

    func testStoredEvidenceReferenceIsTheOnlyInputToSelection() throws {
        let e = entry(100, in: project)!
        let reference = try XCTUnwrap(e.proposal.evidence)
        XCTAssertEqual(e.transcriptSelection, .init(meetingID: reference.meetingID, segmentID: reference.transcriptSegmentID))
        // The selection carries no time and no text: nothing to fabricate, nothing to fuzzy-match.
        XCTAssertEqual(Mirror(reflecting: e.transcriptSelection!).children.map { $0.label ?? "" }, ["meetingID", "segmentID"])
    }

    func testNewLabelsHaveKoreanAndEnglishResources() {
        for key in ["원문에서 이 발화를 엽니다.", "근거 발화", "검토 근거 발화를 강조 표시했습니다.", "선택한 근거 발화를 찾을 수 없습니다."] {
            XCTAssertEqual(L10n.text(key, language: .ko), key)
            XCTAssertNotEqual(L10n.text(key, language: .en), key)
        }
        XCTAssertEqual(WorkStateEvidenceQuote.label(quote: "q", timestamp: nil), L10n.format("원문 “%@”", "q"))
        XCTAssertEqual(WorkStateEvidenceQuote.label(quote: "q", timestamp: "01:05"), L10n.format("원문 %@ “%@”", "01:05", "q"))
    }
}
#endif
