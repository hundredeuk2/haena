import XCTest
@testable import HAENA

/// End to end from a deterministic recording to a stored meeting, over the real JSON repository
/// with the network boundary stubbed. This is the flow the "녹음 시작" button drives.
final class MicrophoneRecordingIntegrationTests: XCTestCase {
    private var supportDirectory: URL!
    private var scratch: RecordingScratchStore!
    private var assetStore: AudioAssetStore!
    private var repository: JSONProjectRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        supportDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        scratch = RecordingScratchStore(
            directoryURL: supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
        )
        assetStore = AudioAssetStore(directoryURL: supportDirectory.appendingPathComponent("Audio", isDirectory: true))
        repository = JSONProjectRepository(fileURL: supportDirectory.appendingPathComponent("projects.json"))
    }

    private static let transcript = [
        AudioTestSupport.segment("녹음으로 만든 회의입니다.", start: 0, end: 3, speaker: "speaker_1"),
        AudioTestSupport.segment("두 번째 발언입니다.", start: 3, end: 6, speaker: "speaker_2")
    ]

    private func makeCaptureService(
        _ outcome: StubTranscriptionProvider.Outcome = .success(MicrophoneRecordingIntegrationTests.transcript)
    ) -> AudioMeetingCaptureService {
        AudioMeetingCaptureService(
            repository: repository,
            provider: StubTranscriptionProvider(outcome),
            assetStore: assetStore
        )
    }

    /// Start → stop → a file the import path accepts, exactly as the recording screen does it.
    private func record(
        _ recorder: DeterministicMeetingAudioRecorder = DeterministicMeetingAudioRecorder()
    ) async throws -> RecordedAudio {
        let destination = try scratch.makeDestination(fileExtension: "wav")
        try await recorder.startRecording(to: destination)
        return try await recorder.stopRecording()
    }

    // MARK: - Hand-off to the existing pipeline

    func testRecordingBecomesAMicrophoneMeetingWithItsTranscript() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()

        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "주간 회의 녹음",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )

        XCTAssertEqual(meeting.sourceType, .microphone, "A recording must not be filed as an imported file.")
        XCTAssertEqual(meeting.transcriptSegments.count, 2)
        XCTAssertEqual(meeting.participants.count, 2)
        XCTAssertNotNil(meeting.audioAsset)

        // Reloaded through a new repository instance: the meeting really reached disk.
        let reopened = JSONProjectRepository(fileURL: supportDirectory.appendingPathComponent("projects.json"))
        let loaded = try await reopened.project(id: project.id)
        let stored = try XCTUnwrap(loaded?.meetings.first)
        XCTAssertEqual(stored, meeting)
    }

    func testWorkStateExtractionRunsOverARecordedMeeting() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()
        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "녹음 회의",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )

        let report = try await WorkStateExtractionService(
            repository: repository,
            extractor: DeterministicWorkStateExtractor()
        ).extractAndApply(meetingID: meeting.id, projectID: project.id)

        XCTAssertGreaterThan(report.storedCount, 0)
    }

    func testRecordingCanBeAttachedToAnExistingProject() async throws {
        let service = makeCaptureService()
        let existing = try await service.createProject(name: "기존 프로젝트")
        let recorded = try await record()

        _ = try await service.importAudioMeeting(
            projectID: existing.id,
            title: "녹음",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )

        let loaded = try await repository.project(id: existing.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(stored.meetings.count, 1)
        XCTAssertEqual(stored.meetings.first?.sourceType, .microphone)
    }

    // MARK: - Temporary file ownership

    /// The capture service copies before it transcribes, so the recording exists in two places
    /// only for the duration of the call — after which the scratch copy is redundant.
    func testAudioIsCopiedIntoTheManagedStoreSoTheScratchFileCanGo() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()

        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "녹음",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )
        let asset = try XCTUnwrap(meeting.audioAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetStore.url(for: asset).path))

        // What the screen does once the hand-off succeeded.
        scratch.remove(recorded.fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.fileURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: assetStore.url(for: asset).path),
            "Deleting the scratch copy must not touch the meeting's audio."
        )
    }

    /// A failed transcription keeps the managed copy for a retry, matching the file-import policy.
    func testFailedTranscriptionSavesNoMeetingAndKeepsTheManagedCopy() async throws {
        let service = makeCaptureService(.failure(.rateLimited))
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()

        do {
            _ = try await service.importAudioMeeting(
                projectID: project.id,
                title: "녹음",
                fileURL: recorded.fileURL,
                sourceType: .microphone
            )
            XCTFail("Expected the transcription to fail.")
        } catch {
            XCTAssertEqual(error as? AudioMeetingCaptureError, .transcriptionFailed(.rateLimited))
        }

        let loaded = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertTrue(stored.meetings.isEmpty, "A failed recording must leave no partial meeting.")

        let managed = try FileManager.default.contentsOfDirectory(
            atPath: supportDirectory.appendingPathComponent("Audio").path
        )
        XCTAssertEqual(managed.count, 1, "The managed copy stays so the user can retry.")
    }

    /// Abandoning the recording must leave the project completely untouched.
    func testCancellingAfterRecordingCreatesNothing() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()

        // What the screen does when the sheet closes without transcribing.
        scratch.remove(recorded.fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recorded.fileURL.path))
        let loaded = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertTrue(stored.meetings.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: supportDirectory.appendingPathComponent("Audio").path),
            "Nothing may reach the managed store until the user confirms."
        )
    }

    // MARK: - No regression in the existing entry points

    func testImportedFileMeetingsAreStillFiledAsAudioFile() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "혼합 프로젝트")
        let recorded = try await record()
        let imported = try AudioTestSupport.writeFile(
            named: "meeting.m4a",
            byteCount: 512,
            in: try AudioTestSupport.makeTemporaryDirectory(self)
        )

        _ = try await service.importAudioMeeting(
            projectID: project.id,
            title: "불러온 회의",
            fileURL: imported
        )
        _ = try await service.importAudioMeeting(
            projectID: project.id,
            title: "녹음 회의",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )

        let loaded = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(
            Set(stored.meetings.map(\.sourceType)),
            [.audioFile, .microphone],
            "The default must stay .audioFile for every existing caller."
        )
    }

    func testPastedTextFlowIsUnaffected() async throws {
        let textService = TextMeetingCaptureService(repository: repository)
        let project = try await textService.createProject(name: "텍스트 프로젝트")
        let meeting = try await textService.saveTextMeeting(
            projectID: project.id,
            title: "붙여넣은 회의",
            transcript: "내용"
        )
        XCTAssertEqual(meeting.sourceType, .pastedText)
    }

    func testDeletingARecordedMeetingRemovesItsStoredAudio() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "녹음 프로젝트")
        let recorded = try await record()
        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "녹음",
            fileURL: recorded.fileURL,
            sourceType: .microphone
        )
        let asset = try XCTUnwrap(meeting.audioAsset)

        try await ProjectDeletionService(repository: repository, assetStore: assetStore)
            .deleteMeeting(meetingID: meeting.id, fromProjectID: project.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assetStore.url(for: asset).path))
    }
}

/// The build configuration the microphone depends on. A missing usage description is not a
/// warning at runtime — macOS terminates the process — so it is asserted rather than assumed.
final class MicrophoneConfigurationTests: XCTestCase {
    /// The repository, located from this source file so the assertions target the checked-in
    /// generated files rather than whatever the test bundle happens to embed.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMicrophoneUsageDescriptionIsPresentAndNotEmpty() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("HAENA/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let description = try XCTUnwrap(
            plist["NSMicrophoneUsageDescription"] as? String,
            "Required: without it macOS terminates the app the first time it opens the microphone."
        )
        XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testAudioInputEntitlementIsDeclared() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("HAENA/HAENA.entitlements"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["com.apple.security.device.audio-input"] as? Bool, true)
    }

    /// The deterministic recorder exists for tests, and selecting it in a shipped build would mean
    /// a user pressing record and getting silence. The decision has exactly one input.
    func testDeterministicComponentsAreOnlyChosenUnderUITesting() {
        XCTAssertTrue(AppComponentSelection.isUITesting(["HAENA_UI_TESTING": "1"]))
        XCTAssertFalse(AppComponentSelection.isUITesting([:]), "A normal launch must get the real recorder.")
        XCTAssertFalse(AppComponentSelection.isUITesting(["HAENA_UI_TESTING": "0"]))
        XCTAssertFalse(AppComponentSelection.isUITesting(["HAENA_UI_TESTING": ""]))
        XCTAssertFalse(
            AppComponentSelection.isUITesting(ProcessInfo.processInfo.environment),
            "This unit-test run is not a UI-test launch."
        )
    }

    func testRecoveryProcessAssemblyRequiresStrictSystemTemporaryRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-recovery-contract-test", isDirectory: true)
        let accepted = try XCTUnwrap(try TransitionApplyRecoveryProcessTestConfiguration.load(
            environment: [
                "HAENA_RECOVERY_PROCESS_TESTING": "1",
                "HAENA_RECOVERY_PROCESS_TEST_ROOT": temporaryRoot.path,
                "HAENA_RECOVERY_PROCESS_TEST_CRASH_POINT": "after_project_marker"
            ]
        ))
        XCTAssertEqual(
            accepted.rootURL.path,
            temporaryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(accepted.crashCheckpoint, .projectAndMarkerStored)

        XCTAssertThrowsError(try TransitionApplyRecoveryProcessTestConfiguration.load(
            environment: [
                "HAENA_RECOVERY_PROCESS_TESTING": "1",
                "HAENA_RECOVERY_PROCESS_TEST_ROOT": "/var/haena-recovery-test"
            ]
        )) { error in
            XCTAssertEqual(
                error as? TransitionApplyRecoveryProcessTestConfiguration.ConfigurationError,
                .rootOutsideSystemTemporaryDirectory
            )
        }
        XCTAssertThrowsError(try TransitionApplyRecoveryProcessTestConfiguration.load(
            environment: [
                "HAENA_RECOVERY_PROCESS_TESTING": "1",
                "HAENA_RECOVERY_PROCESS_TEST_ROOT": temporaryRoot.path,
                "HAENA_RECOVERY_PROCESS_TEST_CRASH_POINT": "unknown"
            ]
        ))
        XCTAssertNil(try TransitionApplyRecoveryProcessTestConfiguration.load(environment: [:]))
    }
}
