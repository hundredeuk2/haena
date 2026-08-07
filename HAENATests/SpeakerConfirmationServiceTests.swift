import XCTest
@testable import HAENA

/// Covers the guarantee the feature rests on: confirming a voice changes who a segment is
/// attributed to and nothing else, and never reaches another meeting.
final class SpeakerConfirmationServiceTests: XCTestCase {
    private var repository: InMemoryProjectRepository!
    private var ids: AudioTestSupport.IDSequence!

    private static let speakerOneID = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let speakerTwoID = UUID(uuidString: "11111111-0000-0000-0000-000000000002")!
    private static let otherMeetingID = UUID(uuidString: "22222222-0000-0000-0000-000000000001")!
    private static let otherSpeakerID = UUID(uuidString: "22222222-0000-0000-0000-000000000002")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        repository = InMemoryProjectRepository()
        ids = AudioTestSupport.IDSequence()
    }

    private func makeService() -> SpeakerConfirmationService {
        let ids = self.ids!
        return SpeakerConfirmationService(
            repository: repository,
            now: { TestFixtures.laterDate },
            makeID: { ids.next() }
        )
    }

    // MARK: - Fixtures

    private static func speaker(_ id: UUID, _ name: String, label: String) -> Participant {
        Participant(id: id, displayName: name, linkedUserID: nil, speakerLabel: label)
    }

    private static func segment(
        _ text: String,
        speakerID: UUID?,
        start: TimeInterval?,
        meetingID: UUID = TestFixtures.meetingID
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            meetingID: meetingID,
            speakerID: speakerID,
            text: text,
            startTime: start,
            endTime: start.map { $0 + 2 }
        )
    }

    /// Two diarized voices, with utterances of varying length so representative selection is
    /// actually exercised.
    private static func meeting() -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "주간 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .audioFile,
            participants: [
                speaker(speakerOneID, "Speaker 1", label: "A"),
                speaker(speakerTwoID, "Speaker 2", label: "B")
            ],
            transcriptSegments: [
                segment("네.", speakerID: speakerOneID, start: 0),
                segment("우리는 2월 출시로 가기로 했습니다.", speakerID: speakerOneID, start: 2),
                segment("지표 정의는 아직 정하지 못했습니다.", speakerID: speakerOneID, start: 6),
                segment("그럼 다음 주에 확정하죠.", speakerID: speakerOneID, start: 10),
                segment("확인했습니다. 제가 정리해서 공유하겠습니다.", speakerID: speakerTwoID, start: 14),
                segment("", speakerID: speakerTwoID, start: 18)
            ],
            createdAt: TestFixtures.fixedDate
        )
    }

    /// A separate meeting with its own `Speaker 1` — different participant, different UUID.
    private static func otherMeeting() -> Meeting {
        Meeting(
            id: otherMeetingID,
            projectID: TestFixtures.projectID,
            title: "다른 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .audioFile,
            participants: [speaker(otherSpeakerID, "Speaker 1", label: "A")],
            transcriptSegments: [
                segment("다른 회의 발언입니다.", speakerID: otherSpeakerID, start: 0, meetingID: otherMeetingID)
            ],
            createdAt: TestFixtures.fixedDate
        )
    }

    private func seed(meetings: [Meeting] = [SpeakerConfirmationServiceTests.meeting()]) async throws {
        try await repository.save(AudioTestSupport.project(meetings: meetings))
    }

    private func storedMeeting(_ id: UUID = TestFixtures.meetingID) async throws -> Meeting {
        let project = try await repository.project(id: TestFixtures.projectID)
        return try XCTUnwrap(project?.meetings.first { $0.id == id })
    }

    // MARK: - Selecting unconfirmed speakers

    func testListsEveryDiarizedVoiceAsUnconfirmedInitially() async throws {
        try await seed()
        let overview = try await makeService().overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )

        XCTAssertEqual(overview.unconfirmed.map(\.displayName), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(overview.unconfirmed.first?.providerSpeakerLabel, "A")
        XCTAssertEqual(overview.unconfirmed.first?.utteranceCount, 4)
    }

    func testAlreadyConfirmedSpeakerIsExcluded() async throws {
        try await seed()
        let service = makeService()
        _ = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let overview = try await service.overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        XCTAssertEqual(overview.unconfirmed.map(\.displayName), ["Speaker 2"])
    }

    /// A meeting with no diarization — pasted text — must not offer anything to confirm.
    func testMeetingWithoutDiarizedSpeakersHasNothingToConfirm() async throws {
        let textMeeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "붙여넣은 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [Self.segment("내용", speakerID: nil, start: nil)],
            createdAt: TestFixtures.fixedDate
        )
        try await seed(meetings: [textMeeting])

        let overview = try await makeService().overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        XCTAssertTrue(overview.unconfirmed.isEmpty)
    }

    // MARK: - Representative utterances

    func testRepresentativeUtterancesAreCappedAtThreeAndInSpokenOrder() async throws {
        try await seed()
        let overview = try await makeService().overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        let speaker = try XCTUnwrap(overview.unconfirmed.first)

        XCTAssertEqual(speaker.representativeUtterances.count, 3)
        let starts = speaker.representativeUtterances.compactMap(\.startTime)
        XCTAssertEqual(starts, starts.sorted(), "Utterances must stay in the order they were spoken.")
    }

    /// Filler like "네." is a poor way to recognise someone, so substantial lines come first —
    /// but the order shown is still chronological.
    func testSubstantialUtterancesArePreferredOverFiller() async throws {
        try await seed()
        let overview = try await makeService().overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        let texts = try XCTUnwrap(overview.unconfirmed.first).representativeUtterances.map(\.text)

        XCTAssertFalse(texts.contains("네."), "Filler must be skipped while longer lines exist.")
        XCTAssertEqual(texts, [
            "우리는 2월 출시로 가기로 했습니다.",
            "지표 정의는 아직 정하지 못했습니다.",
            "그럼 다음 주에 확정하죠."
        ])
    }

    func testEmptyUtterancesAreNeverOffered() async throws {
        try await seed()
        let overview = try await makeService().overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        let second = try XCTUnwrap(overview.unconfirmed.last)

        XCTAssertEqual(second.utteranceCount, 2, "The blank line still counts as an utterance.")
        XCTAssertEqual(second.representativeUtterances.map(\.text), ["확인했습니다. 제가 정리해서 공유하겠습니다."])
    }

    /// Nothing but filler is still better than showing no context at all.
    func testFillerIsUsedWhenNothingSubstantialExists() {
        let onlyFiller = [
            Self.segment("네.", speakerID: Self.speakerOneID, start: 0),
            Self.segment("맞아요.", speakerID: Self.speakerOneID, start: 2)
        ]
        let chosen = SpeakerConfirmationService.representativeUtterances(from: onlyFiller)
        XCTAssertEqual(chosen.map(\.text), ["네.", "맞아요."])
    }

    // MARK: - Linking

    func testLinkToNewParticipantCreatesThemAndConfirmsTheVoice() async throws {
        try await seed()
        let project = try await makeService().link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "  Patrick  ",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let meeting = try XCTUnwrap(project.meetings.first)
        let resolution = try XCTUnwrap(meeting.resolution(forSpeakerID: Self.speakerOneID))
        let resolved = try XCTUnwrap(
            meeting.participants.first { $0.id == resolution.resolvedParticipantID }
        )

        XCTAssertEqual(resolved.displayName, "Patrick", "The name must be trimmed.")
        XCTAssertNil(resolved.speakerLabel, "A person the user named is not a diarized voice.")
        XCTAssertEqual(resolution.providerSpeakerLabel, "A", "The provider's label stays traceable.")
    }

    func testLinkToExistingParticipantReusesThatIdentity() async throws {
        try await seed()
        let service = makeService()
        let afterFirst = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let patrickID = try XCTUnwrap(
            afterFirst.meetings.first?.resolution(forSpeakerID: Self.speakerOneID)?.resolvedParticipantID
        )

        let afterSecond = try await service.link(
            speakerID: Self.speakerTwoID,
            toExistingParticipant: patrickID,
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let meeting = try XCTUnwrap(afterSecond.meetings.first)

        XCTAssertEqual(
            meeting.resolution(forSpeakerID: Self.speakerTwoID)?.resolvedParticipantID,
            patrickID,
            "Two voices must be able to point at one person."
        )
        XCTAssertEqual(meeting.transcriptSegments.count, 6, "No segment may be merged or removed.")
        XCTAssertEqual(meeting.assignableParticipants.map(\.displayName), ["Patrick"])
    }

    func testBlankNameIsRejected() async throws {
        try await seed()
        await assertThrows(.nameMissing) {
            _ = try await self.makeService().link(
                speakerID: Self.speakerOneID,
                toNewParticipantNamed: "   ",
                meetingID: TestFixtures.meetingID,
                projectID: TestFixtures.projectID
            )
        }
        let meeting = try await storedMeeting()
        XCTAssertTrue(meeting.speakerResolutions.isEmpty)
        XCTAssertEqual(meeting.participants.count, 2, "No participant may be created for a blank name.")
    }

    func testUnlinkReturnsTheVoiceToUnconfirmed() async throws {
        try await seed()
        let service = makeService()
        _ = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let project = try await service.unlink(
            speakerID: Self.speakerOneID,
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let meeting = try XCTUnwrap(project.meetings.first)
        XCTAssertTrue(meeting.speakerResolutions.isEmpty)
        XCTAssertEqual(meeting.unconfirmedSpeakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
    }

    func testRelinkingReplacesRatherThanAccumulates() async throws {
        try await seed()
        let service = makeService()
        _ = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let project = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "민수",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let meeting = try XCTUnwrap(project.meetings.first)
        XCTAssertEqual(meeting.speakerResolutions.count, 1)
        XCTAssertEqual(meeting.confirmedParticipant(for: Self.speakerOneID)?.displayName, "민수")
    }

    // MARK: - Not-found handling

    func testUnknownProjectMeetingSpeakerAndParticipantAreReported() async throws {
        try await seed()
        let service = makeService()

        await assertThrows(.projectNotFound) {
            _ = try await service.overview(projectID: UUID(), meetingID: TestFixtures.meetingID)
        }
        await assertThrows(.meetingNotFound) {
            _ = try await service.overview(projectID: TestFixtures.projectID, meetingID: UUID())
        }
        await assertThrows(.speakerNotFound) {
            _ = try await service.link(
                speakerID: UUID(),
                toNewParticipantNamed: "Patrick",
                meetingID: TestFixtures.meetingID,
                projectID: TestFixtures.projectID
            )
        }
        await assertThrows(.participantNotFound) {
            _ = try await service.link(
                speakerID: Self.speakerOneID,
                toExistingParticipant: UUID(),
                meetingID: TestFixtures.meetingID,
                projectID: TestFixtures.projectID
            )
        }
    }

    /// A person the user named is not itself a voice, so it cannot be confirmed as one.
    func testNonDiarizedParticipantCannotBeTreatedAsASpeaker() async throws {
        try await seed()
        let service = makeService()
        let project = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let patrickID = try XCTUnwrap(
            project.meetings.first?.resolution(forSpeakerID: Self.speakerOneID)?.resolvedParticipantID
        )

        await assertThrows(.speakerNotFound) {
            _ = try await service.unlink(
                speakerID: patrickID,
                meetingID: TestFixtures.meetingID,
                projectID: TestFixtures.projectID
            )
        }
    }

    // MARK: - Isolation and immutability

    func testConfirmingOneMeetingLeavesTheOtherMeetingsSpeakerOneAlone() async throws {
        try await seed(meetings: [Self.meeting(), Self.otherMeeting()])
        _ = try await makeService().link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let other = try await storedMeeting(Self.otherMeetingID)
        XCTAssertTrue(other.speakerResolutions.isEmpty)
        XCTAssertEqual(other.unconfirmedSpeakers.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(other.participants.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(
            TranscriptSpeakerDisplay.label(for: other.transcriptSegments[0], in: other),
            "A",
            "The other meeting's Speaker 1 must be untouched."
        )
    }

    func testConfirmingDoesNotAlterTranscriptTextOrTimings() async throws {
        try await seed()
        let before = try await storedMeeting()
        _ = try await makeService().link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let after = try await storedMeeting()

        XCTAssertEqual(after.transcriptSegments, before.transcriptSegments)
    }

    func testConfirmingDoesNotTouchWorkStateItems() async throws {
        var project = AudioTestSupport.project(meetings: [Self.meeting()])
        let item = ActionItem(
            id: UUID(),
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "지표 정의 초안",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .confirmed,
            evidence: nil,
            confidence: Confidence(0.9),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
        project.actionItems = [item]
        try await repository.save(project)

        let updated = try await makeService().link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        XCTAssertEqual(updated.actionItems, [item], "Confirming a speaker must not assign or restate work.")
        XCTAssertNil(updated.actionItems.first?.assigneeID, "An unassigned task must stay unassigned.")
    }

    // MARK: - Persistence

    func testResolutionSurvivesAReloadThroughANewRepository() async throws {
        let directory = try AudioTestSupport.makeTemporaryDirectory(self)
        let fileURL = directory.appendingPathComponent("projects.json")
        let fileRepository = JSONProjectRepository(fileURL: fileURL)
        try await fileRepository.save(AudioTestSupport.project(meetings: [Self.meeting()]))

        let service = SpeakerConfirmationService(repository: fileRepository)
        _ = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let reopened = JSONProjectRepository(fileURL: fileURL)
        let loaded = try await reopened.project(id: TestFixtures.projectID)
        let meeting = try XCTUnwrap(loaded?.meetings.first)

        XCTAssertEqual(meeting.confirmedParticipant(for: Self.speakerOneID)?.displayName, "Patrick")
        XCTAssertEqual(meeting.unconfirmedSpeakers.map(\.displayName), ["Speaker 2"])
    }

    /// Meetings stored before this feature existed have no `speakerResolutions` key at all.
    func testMeetingJSONWithoutSpeakerResolutionsStillDecodes() throws {
        let json = """
        {"id":"\(TestFixtures.meetingID.uuidString)","projectID":"\(TestFixtures.projectID.uuidString)",
         "title":"이전 회의","occurredAt":0,"sourceType":"audioFile","participants":[],
         "transcriptSegments":[],"createdAt":0}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        XCTAssertTrue(meeting.speakerResolutions.isEmpty)
        XCTAssertTrue(meeting.unconfirmedSpeakers.isEmpty)
    }

    func testSaveFailureLeavesStoredDataUnchanged() async throws {
        try await seed()
        let failing = FailingProjectRepository(wrapping: repository)
        let service = SpeakerConfirmationService(repository: failing)

        await assertThrows(.repositoryFailure) {
            _ = try await service.link(
                speakerID: Self.speakerOneID,
                toNewParticipantNamed: "Patrick",
                meetingID: TestFixtures.meetingID,
                projectID: TestFixtures.projectID
            )
        }

        let meeting = try await storedMeeting()
        XCTAssertTrue(meeting.speakerResolutions.isEmpty)
        XCTAssertEqual(meeting.participants.count, 2)
    }

    // MARK: - Candidates

    func testCandidatesOfferConfirmedPeopleFromThisMeetingAndNamesFromOthers() async throws {
        try await seed(meetings: [Self.meeting(), Self.otherMeeting()])
        let service = makeService()

        _ = try await service.link(
            speakerID: Self.otherSpeakerID,
            toNewParticipantNamed: "민수",
            meetingID: Self.otherMeetingID,
            projectID: TestFixtures.projectID
        )
        _ = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "Patrick",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )

        let overview = try await service.overview(
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID
        )
        let patrick = try XCTUnwrap(overview.candidates.first { $0.displayName == "Patrick" })
        let minsu = try XCTUnwrap(overview.candidates.first { $0.displayName == "민수" })

        XCTAssertNotNil(patrick.existingParticipantID, "Someone already in this meeting can be reused directly.")
        XCTAssertNil(minsu.existingParticipantID, "A name from another meeting is a suggestion, not a shared identity.")
    }

    /// Choosing a name known from elsewhere must create this meeting's own participant.
    func testLinkingToANameFromAnotherMeetingDoesNotShareIdentity() async throws {
        try await seed(meetings: [Self.meeting(), Self.otherMeeting()])
        let service = makeService()
        let other = try await service.link(
            speakerID: Self.otherSpeakerID,
            toNewParticipantNamed: "민수",
            meetingID: Self.otherMeetingID,
            projectID: TestFixtures.projectID
        )
        let otherMinsuID = try XCTUnwrap(
            other.meetings.first { $0.id == Self.otherMeetingID }?
                .resolution(forSpeakerID: Self.otherSpeakerID)?.resolvedParticipantID
        )

        let updated = try await service.link(
            speakerID: Self.speakerOneID,
            toNewParticipantNamed: "민수",
            meetingID: TestFixtures.meetingID,
            projectID: TestFixtures.projectID
        )
        let thisMinsuID = try XCTUnwrap(
            updated.meetings.first { $0.id == TestFixtures.meetingID }?
                .resolution(forSpeakerID: Self.speakerOneID)?.resolvedParticipantID
        )

        XCTAssertNotEqual(thisMinsuID, otherMinsuID, "Same name must not mean same identity across meetings.")
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: SpeakerConfirmationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as SpeakerConfirmationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but got \(error).", file: file, line: line)
        }
    }
}

/// Reads succeed, writes fail — the shape of a full disk or a permissions problem.
private struct FailingProjectRepository: ProjectRepository {
    let wrapped: any ProjectRepository

    init(wrapping wrapped: any ProjectRepository) {
        self.wrapped = wrapped
    }

    struct SaveFailed: Error {}

    func save(_ project: Project) async throws {
        throw SaveFailed()
    }

    func project(id: UUID) async throws -> Project? {
        try await wrapped.project(id: id)
    }

    func allProjects() async throws -> [Project] {
        try await wrapped.allProjects()
    }

    func delete(id: UUID) async throws {
        try await wrapped.delete(id: id)
    }
}
