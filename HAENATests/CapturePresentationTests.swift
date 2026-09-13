#if DEBUG
import XCTest
@testable import HAENA

@MainActor
final class CapturePresentationTests: XCTestCase {
    private struct Context {
        let seed: CaptureLifecycleUITestSeed
        let repository: CaptureLifecycleUITestRepository
        let text: TextMeetingCaptureService
        let audio: AudioMeetingCaptureService
        let extraction: WorkStateExtractionService
        let file: URL
    }

    private func context(_ scenario: CaptureLifecycleUITestSeed.Scenario = .success) throws -> Context {
        let seed = CaptureLifecycleUITestSeed(scenario: scenario)
        let repository = CaptureLifecycleUITestRepository(seed: seed)
        let state = try seed.audioState()
        let file = try XCTUnwrap(state.selectedFile?.url)
        let directory = file.deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Context(seed: seed, repository: repository, text: TextMeetingCaptureService(repository: repository),
                       audio: AudioMeetingCaptureService(repository: repository,
                           provider: CaptureLifecycleUITestTranscriber(failFirst: scenario == .transcriptionFailure),
                           assetStore: AudioAssetStore(directoryURL: directory.appendingPathComponent("copies"))),
                       extraction: WorkStateExtractionService(repository: repository,
                           extractor: CaptureLifecycleUITestExtractor(scenario: scenario, repository: repository)), file: file)
    }

    private func save(_ source: MeetingSourceType, _ c: Context,
                      progress: (@MainActor @Sendable (CaptureProgressPhase) -> Void)? = nil) async throws -> Meeting {
        if source == .pastedText {
            return try await c.text.saveTextMeeting(projectID: c.seed.project.id, title: CaptureLifecycleUITestSeed.title,
                transcript: CaptureLifecycleUITestSeed.transcript, onProgress: progress)
        }
        return try await c.audio.importAudioMeeting(projectID: c.seed.project.id, title: CaptureLifecycleUITestSeed.title,
                                                     fileURL: c.file, sourceType: source, onProgress: progress)
    }

    private func assertSinglePending(_ c: Context, meeting: Meeting) async throws {
        let loaded = try await c.repository.project(id: meeting.projectID)
        let project = try XCTUnwrap(loaded)
        XCTAssertEqual(project.meetings, [meeting])
        XCTAssertEqual(WorkStateInbox.pendingProposals(in: project).count, 4)
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
        XCTAssertEqual(project.openQuestions.count, 1)
        XCTAssertEqual(project.nextAgenda.count, 1)
        XCTAssertEqual(project.decisions[0].status, .proposed)
        XCTAssertEqual(project.actionItems[0].status, .proposed)
        XCTAssertNil(project.actionItems[0].assigneeID)
        XCTAssertNil(project.actionItems[0].dueDate)
    }

    func testProductionDraftDefaultsRemainEmpty() {
        XCTAssertNil(AudioCaptureInitialState.empty.selectedProjectID)
        XCTAssertNil(AudioCaptureInitialState.empty.selectedFile)
        XCTAssertEqual(AudioCaptureInitialState.empty.meetingTitle, "")
        XCTAssertEqual(PastedTranscriptInitialState(), .empty)
    }

    func testFiniteSeedRequiresExplicitUIOptInAndIgnoresRawContent() {
        for env in [[:], ["HAENA_UI_TEST_CAPTURE_LIFECYCLE": "success"],
                    ["HAENA_UI_TESTING": "1"], ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_CAPTURE_LIFECYCLE": "unknown"]] {
            XCTAssertNil(CaptureLifecycleUITestSeed.select(environment: env))
        }
        let seed = CaptureLifecycleUITestSeed.select(environment: ["HAENA_UI_TESTING": "1",
            "HAENA_UI_TEST_CAPTURE_LIFECYCLE": "success", "transcript": "ignored", "path": "ignored"])
        XCTAssertEqual(seed?.pastedState.transcript, CaptureLifecycleUITestSeed.transcript)
        XCTAssertEqual(seed?.project.meetings, [])
    }

    func testPhaseIdentifiersAreFiniteAndNoPreSavePhaseClaimsSaved() {
        XCTAssertEqual(Set(CaptureProgressPhase.allCases.map(\.accessibilityIdentifier)).count, CaptureProgressPhase.allCases.count)
        for phase in [CaptureProgressPhase.ready, .preparing, .validating, .saving, .copyingAudio, .transcribing] {
            XCTAssertFalse(phase.localizationKey.contains("저장되었습니다"))
        }
    }

    func testPasteSaveProgressAndPreservation() async throws {
        let c = try context(); var phases: [CaptureProgressPhase] = []
        let meeting = try await save(.pastedText, c, progress: { phases.append($0) })
        XCTAssertEqual(phases, [.validating, .saving])
        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: c.repository)
        XCTAssertEqual(outcome.preservation, .meetingAndTranscript)
        XCTAssertNil(meeting.audioAsset)
        XCTAssertEqual(outcome.pendingCounts?.total, 0)
    }

    func testBothAudioSourcesPreserveOnlyAfterCanonicalSave() async throws {
        for source in [MeetingSourceType.audioFile, .microphone] {
            let c = try context(); var phases: [CaptureProgressPhase] = []
            let meeting = try await save(source, c, progress: { phases.append($0) })
            XCTAssertEqual(phases, [.validating, .copyingAudio, .transcribing, .saving])
            let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: c.repository)
            XCTAssertEqual(outcome.preservation, .meetingAudioAndTranscript)
            XCTAssertTrue(FileManager.default.fileExists(atPath: c.audio.assetStore.url(for: try XCTUnwrap(meeting.audioAsset)).path))
        }
    }

    func testValidationFailureCreatesNoMeetingOrResultForAllPaths() async throws {
        for source in [MeetingSourceType.pastedText, .audioFile, .microphone] {
            let c = try context(); var phases: [CaptureProgressPhase] = []
            do {
                if source == .pastedText {
                    _ = try await c.text.saveTextMeeting(projectID: nil, title: "draft", transcript: "draft", onProgress: { phases.append($0) })
                } else {
                    _ = try await c.audio.importAudioMeeting(projectID: nil, title: "draft", fileURL: c.file,
                                                              sourceType: source, onProgress: { phases.append($0) })
                }
                XCTFail("Must fail")
            } catch {}
            XCTAssertEqual(phases, [.validating])
            let project = try await c.repository.project(id: c.seed.project.id)
            XCTAssertEqual(project, c.seed.project)
            let writes = await c.repository.meetingWrites
            XCTAssertEqual(writes, 0)
        }
    }

    func testRepositorySaveFailureNeverBecomesCompletionAndRetryCreatesOneMeeting() async throws {
        for source in [MeetingSourceType.pastedText, .audioFile, .microphone] {
            let c = try context(.preSaveFailure); var phases: [CaptureProgressPhase] = []
            do { _ = try await save(source, c, progress: { phases.append($0) }); XCTFail("Must fail") } catch {}
            XCTAssertEqual(phases.last, .saving)
            let before = try await c.repository.project(id: c.seed.project.id)
            XCTAssertEqual(before, c.seed.project)
            let meeting = try await save(source, c)
            let after = try await c.repository.project(id: c.seed.project.id)
            XCTAssertEqual(after?.meetings, [meeting])
            XCTAssertEqual(after?.actionItems, [])
        }
    }

    func testTranscriptionFailureKeepsOnlyAudioAndNoMeetingForBothAudioPaths() async throws {
        for source in [MeetingSourceType.audioFile, .microphone] {
            let c = try context(.transcriptionFailure); var phases: [CaptureProgressPhase] = []
            do { _ = try await save(source, c, progress: { phases.append($0) }); XCTFail("Must fail") }
            catch { XCTAssertEqual(error as? AudioMeetingCaptureError, .transcriptionFailed(.timedOut)) }
            XCTAssertEqual(phases, [.validating, .copyingAudio, .transcribing])
            let project = try await c.repository.project(id: c.seed.project.id)
            XCTAssertEqual(project, c.seed.project)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: c.file.deletingLastPathComponent().appendingPathComponent("copies"), includingPropertiesForKeys: nil).count, 1)
            let meeting = try await save(source, c)
            let after = try await c.repository.project(id: c.seed.project.id)
            XCTAssertEqual(after?.meetings, [meeting])
        }
    }

    func testAnalysisRetryPreservesExactMeetingAndAllFourKindsStayPendingForAllPaths() async throws {
        for source in [MeetingSourceType.pastedText, .audioFile, .microphone] {
            let c = try context(.analysisFailure)
            let meeting = try await save(source, c)
            do { _ = try await c.extraction.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID); XCTFail("Must fail") } catch {}
            let failed = await CaptureOutcome.make(for: meeting, notice: CaptureFailureCopy.extraction(WorkStateExtractionError.timedOut), repository: c.repository)
            XCTAssertEqual(failed.preservation, source == .pastedText ? .meetingAndTranscript : .meetingAudioAndTranscript)
            XCTAssertEqual(failed.pendingCounts?.total, 0)
            let retry = MeetingReanalysisService(repository: c.repository, extraction: c.extraction)
            _ = try await retry.reanalyse(meetingID: meeting.id, projectID: meeting.projectID)
            try await assertSinglePending(c, meeting: meeting)
            do { _ = try await retry.reanalyse(meetingID: meeting.id, projectID: meeting.projectID); XCTFail("Second retry must refuse") }
            catch { XCTAssertEqual(error as? MeetingReanalysisRefused, .init(reason: .alreadyAnalysed)) }
            try await assertSinglePending(c, meeting: meeting)
        }
    }

    func testCountReadFailureDoesNotInventZeroAndResultsRemainReachableForAllPaths() async throws {
        for source in [MeetingSourceType.pastedText, .audioFile, .microphone] {
            let c = try context(); let meeting = try await save(source, c)
            _ = try await c.extraction.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            await c.repository.failNextRead()
            let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: c.repository)
            XCTAssertNil(outcome.counts); XCTAssertNil(outcome.pendingCounts)
            XCTAssertEqual(outcome.destination.meetingID, meeting.id)
            XCTAssertEqual(outcome.preservation, source == .pastedText ? .meetingAndTranscript : .meetingAudioAndTranscript)
            try await assertSinglePending(c, meeting: meeting)
        }
    }

    func testReviewedAndProcessedResultsNeverAppearInUnapprovedCounts() async throws {
        let c = try context(); let meeting = try await save(.pastedText, c)
        _ = try await c.extraction.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
        let loaded = try await c.repository.project(id: meeting.projectID)
        var project = try XCTUnwrap(loaded)
        project.decisions[0].status = .confirmed
        project.actionItems[0].status = .completed
        project.openQuestions[0].status = .resolved
        project.nextAgenda[0].status = .dismissed
        try await c.repository.save(project)
        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: c.repository)
        XCTAssertEqual(outcome.counts?.total, 4)
        XCTAssertEqual(outcome.pendingCounts?.total, 0)
    }

    func testMissingMeetingCannotReportKnownZeroCounts() async throws {
        let c = try context(); let meeting = try await save(.pastedText, c)
        try await c.repository.save(c.seed.project)
        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: c.repository)
        XCTAssertNil(outcome.counts); XCTAssertNil(outcome.pendingCounts)
    }

    func testPreservationUsesArtifactsNotSourceType() async throws {
        let c = try context(); var meeting = try await save(.audioFile, c)
        XCTAssertEqual(CapturePreservation(saved: meeting), .meetingAudioAndTranscript)
        meeting.transcriptSegments = []
        XCTAssertEqual(CapturePreservation(saved: meeting), .meetingAndAudio)
        meeting.audioAsset = nil
        XCTAssertEqual(CapturePreservation(saved: meeting), .meetingOnly)
        meeting.sourceType = .pastedText
        XCTAssertEqual(CapturePreservation(saved: meeting), .meetingOnly)
    }

    func testCancelRecordingDoesNotCreateMeetingOrApproval() async throws {
        let c = try context(); let recorder = DeterministicMeetingAudioRecorder()
        let file = c.file.deletingLastPathComponent().appendingPathComponent("cancelled.wav")
        try await recorder.startRecording(to: file)
        await recorder.cancelRecording()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let project = try await c.repository.project(id: c.seed.project.id)
        XCTAssertEqual(project, c.seed.project)
    }

    func testAllSharedLabelsAndFailureReasonsAreLocalizedInBothLanguages() {
        let errors: [WorkStateExtractionError] = [.missingCredential, .credentialInteractionRequired, .credentialUnavailable,
            .unauthorized, .rateLimited, .timedOut, .refused, .malformedResponse]
        let keys = CaptureProgressPhase.allCases.map(\.localizationKey)
            + CapturePreservation.allCases.map(\.localizationKey)
            + [CapturePresentationCopy.candidates, CapturePresentationCopy.approvalNotice, CapturePresentationCopy.countsUnavailable]
            + errors.map(CaptureFailureCopy.extraction)
        for key in keys {
            XCTAssertEqual(L10n.text(key, language: .ko), key)
            let english = L10n.text(key, language: .en)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(english, key)
        }
    }
}
#endif
