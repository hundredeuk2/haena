import XCTest
@testable import HAENA

/// Covers what the user actually sees once a voice is confirmed: the transcript, the assignee
/// choices, the project status screen, and the Markdown export must all agree, while the stored
/// work state itself stays exactly as it was.
final class SpeakerConfirmationDisplayTests: XCTestCase {
    private static let speakerOneID = UUID(uuidString: "33333333-0000-0000-0000-000000000001")!
    private static let speakerTwoID = UUID(uuidString: "33333333-0000-0000-0000-000000000002")!
    private static let patrickID = UUID(uuidString: "33333333-0000-0000-0000-0000000000AA")!
    private static let segmentOneID = UUID(uuidString: "33333333-0000-0000-0000-0000000000B1")!
    private static let segmentTwoID = UUID(uuidString: "33333333-0000-0000-0000-0000000000B2")!

    /// A meeting where both diarized voices have been confirmed as one person, Patrick.
    private static func confirmedMeeting() -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "주간 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .audioFile,
            participants: [
                Participant(id: speakerOneID, displayName: "Speaker 1", linkedUserID: nil, speakerLabel: "A"),
                Participant(id: speakerTwoID, displayName: "Speaker 2", linkedUserID: nil, speakerLabel: "B"),
                Participant(id: patrickID, displayName: "Patrick", linkedUserID: nil, speakerLabel: nil)
            ],
            transcriptSegments: [
                TranscriptSegment(
                    id: segmentOneID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: speakerOneID,
                    text: "우리는 2월 출시로 가기로 했습니다.",
                    startTime: 0,
                    endTime: 4
                ),
                TranscriptSegment(
                    id: segmentTwoID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: speakerTwoID,
                    text: "지표 정의는 아직 정하지 못했습니다.",
                    startTime: 4,
                    endTime: 8
                )
            ],
            createdAt: TestFixtures.fixedDate,
            speakerResolutions: [
                SpeakerResolution(
                    anonymousParticipantID: speakerOneID,
                    providerSpeakerLabel: "A",
                    resolvedParticipantID: patrickID
                ),
                SpeakerResolution(
                    anonymousParticipantID: speakerTwoID,
                    providerSpeakerLabel: "B",
                    resolvedParticipantID: patrickID
                )
            ]
        )
    }

    private static func unconfirmedMeeting() -> Meeting {
        var meeting = confirmedMeeting()
        meeting.speakerResolutions = []
        meeting.participants.removeAll { $0.id == patrickID }
        return meeting
    }

    // MARK: - Transcript

    func testConfirmedVoiceShowsThePersonsNameOnEverySegment() {
        let meeting = Self.confirmedMeeting()
        for segment in meeting.transcriptSegments {
            XCTAssertEqual(TranscriptSpeakerDisplay.label(for: segment, in: meeting), "Patrick")
        }
    }

    func testUnconfirmedVoiceStillShowsTheProviderLabel() {
        let meeting = Self.unconfirmedMeeting()
        XCTAssertEqual(
            TranscriptSpeakerDisplay.label(for: meeting.transcriptSegments[0], in: meeting),
            "A"
        )
    }

    // MARK: - Rosters

    func testAssignableChoicesCollapseTwoVoicesIntoOnePerson() {
        XCTAssertEqual(Self.confirmedMeeting().assignableParticipants.map(\.displayName), ["Patrick"])
    }

    /// The lookup roster keeps ids so a reference stored against an anonymous speaker still
    /// resolves — it must not silently become "미지정".
    func testDisplayRosterKeepsAnonymousIdsButShowsTheConfirmedName() {
        let roster = Self.confirmedMeeting().displayRoster
        XCTAssertEqual(
            WorkStateDisplay.assigneeName(Self.speakerOneID, participants: roster),
            "Patrick"
        )
        XCTAssertEqual(
            WorkStateDisplay.assigneeName(Self.patrickID, participants: roster),
            "Patrick"
        )
    }

    func testUnconfirmedMeetingOffersItsAnonymousSpeakersAsChoices() {
        XCTAssertEqual(
            Self.unconfirmedMeeting().assignableParticipants.map(\.displayName),
            ["Speaker 1", "Speaker 2"]
        )
    }

    /// Somebody the user typed in is only offered once a voice actually points at them.
    func testUnlinkedPersonIsNotOfferedAsAnAssignee() {
        var meeting = Self.confirmedMeeting()
        meeting.speakerResolutions = []
        XCTAssertEqual(meeting.assignableParticipants.map(\.displayName), ["Speaker 1", "Speaker 2"])
    }

    func testPastedParticipantReferencedByStoredSegmentIsOfferedAsAnAssignee() {
        let participantID = UUID()
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "붙여넣기 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [
                Participant(
                    id: participantID,
                    displayName: "참석자 A",
                    linkedUserID: nil,
                    speakerLabel: nil
                )
            ],
            transcriptSegments: [
                TranscriptSegment(
                    id: Self.segmentOneID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: participantID,
                    sourceSpeakerLabel: "A",
                    text: "제가 맡겠습니다.",
                    startTime: nil,
                    endTime: nil
                ),
                TranscriptSegment(
                    id: Self.segmentTwoID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: nil,
                    sourceSpeakerLabel: "C",
                    text: "미연결 발언입니다.",
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )

        XCTAssertEqual(meeting.assignableParticipants.map(\.displayName), ["참석자 A"])
        XCTAssertEqual(
            TranscriptSpeakerDisplay.label(for: meeting.transcriptSegments[0], in: meeting),
            "참석자 A"
        )
        XCTAssertEqual(
            TranscriptSpeakerDisplay.label(for: meeting.transcriptSegments[1], in: meeting),
            "C"
        )
    }

    // MARK: - Markdown export

    func testMarkdownExportUsesTheConfirmedName() {
        var project = AudioTestSupport.project(meetings: [Self.confirmedMeeting()])
        project.actionItems = [
            ActionItem(
                id: UUID(),
                projectID: TestFixtures.projectID,
                meetingID: TestFixtures.meetingID,
                title: "지표 정의 초안",
                details: nil,
                // Stored against the anonymous voice, which is what extraction could have matched
                // before anyone was confirmed.
                assigneeID: Self.speakerOneID,
                dueDate: nil,
                status: .confirmed,
                evidence: nil,
                confidence: Confidence(0.9),
                createdAt: TestFixtures.fixedDate,
                updatedAt: TestFixtures.fixedDate
            )
        ]

        let markdown = ProjectMarkdownRenderer().render(
            project: project,
            summary: ProjectStatusSummary.complete(project: project, referenceDate: TestFixtures.fixedDate),
            generatedAt: TestFixtures.fixedDate
        )

        XCTAssertTrue(markdown.contains("Patrick"), "The export must show the confirmed name.")
        XCTAssertFalse(markdown.contains("Speaker 1"), "The anonymous label must not survive into the export.")
    }

    // MARK: - Work state is untouched

    func testConfirmingNeverAssignsAnUnassignedTask() {
        let meeting = Self.confirmedMeeting()
        let roster = meeting.displayRoster
        XCTAssertNil(
            WorkStateDisplay.assigneeName(nil, participants: roster),
            "An unassigned task must stay unassigned no matter who has been confirmed."
        )
        XCTAssertEqual(WorkStateDisplay.assigneeLabel(nil, participants: roster), "담당자 미지정")
    }

    /// An assignee id that matches nobody must not start resolving to a confirmed person.
    func testUnknownAssigneeIDStillResolvesToNobody() {
        let roster = Self.confirmedMeeting().displayRoster
        XCTAssertNil(WorkStateDisplay.assigneeName(UUID(), participants: roster))
    }
}
