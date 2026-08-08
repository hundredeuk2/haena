import XCTest
@testable import HAENA

/// Covers the recorder contract and the temporary-file rules through the deterministic
/// implementation, so every branch runs on a machine with no microphone and no permission prompt.
final class MeetingAudioRecorderTests: XCTestCase {
    private var scratch: RecordingScratchStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = try AudioTestSupport.makeTemporaryDirectory(self)
        scratch = RecordingScratchStore(directoryURL: directory.appendingPathComponent("Recordings", isDirectory: true))
    }

    private func destination() throws -> URL {
        try scratch.makeDestination(fileExtension: "wav")
    }

    // MARK: - Permission

    func testAuthorizedRecorderStartsWithoutAsking() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        let status = await recorder.authorizationStatus()
        XCTAssertEqual(status, .authorized)

        try await recorder.startRecording(to: try destination())
        let started = await recorder.startCount
        XCTAssertEqual(started, 1)
    }

    func testUndeterminedPermissionBecomesAuthorizedWhenGranted() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .permissionNotDetermined(grantWhenAsked: true))

        var status = await recorder.authorizationStatus()
        XCTAssertEqual(status, .notDetermined)

        let granted = await recorder.requestAuthorization()
        status = await recorder.authorizationStatus()

        XCTAssertTrue(granted)
        XCTAssertEqual(status, .authorized)
        try await recorder.startRecording(to: try destination())
    }

    func testUndeterminedPermissionBecomesDeniedWhenRefused() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .permissionNotDetermined(grantWhenAsked: false))

        let granted = await recorder.requestAuthorization()
        let status = await recorder.authorizationStatus()

        XCTAssertFalse(granted)
        XCTAssertEqual(status, .denied)
        await assertThrows(.permissionDenied) {
            try await recorder.startRecording(to: try self.destination())
        }
    }

    func testDeniedPermissionBlocksRecording() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .permissionDenied)
        await assertThrows(.permissionDenied) {
            try await recorder.startRecording(to: try self.destination())
        }
        let started = await recorder.startCount
        XCTAssertEqual(started, 0)
    }

    /// Restricted is reported separately from denied: the user cannot fix it in System Settings,
    /// so telling them to go there would be wrong.
    func testRestrictedPermissionIsReportedDistinctly() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .permissionRestricted)
        await assertThrows(.permissionRestricted) {
            try await recorder.startRecording(to: try self.destination())
        }
    }

    // MARK: - Devices and failures

    func testMissingInputDeviceIsReported() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .noInputDevice)
        await assertThrows(.noInputDevice) {
            try await recorder.startRecording(to: try self.destination())
        }
    }

    func testStartFailureIsReportedAndLeavesNoRecording() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .startFails)
        await assertThrows(.startFailed) {
            try await recorder.startRecording(to: try self.destination())
        }
        await assertThrows(.notRecording) {
            _ = try await recorder.stopRecording()
        }
    }

    /// A start that failed must not leave the recorder wedged — the user can press again.
    func testRecorderRecoversAfterAFailedStart() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .permissionNotDetermined(grantWhenAsked: false))
        await assertThrows(.permissionDenied) {
            try await recorder.startRecording(to: try self.destination())
        }

        _ = await recorder.requestAuthorization()
        let status = await recorder.authorizationStatus()
        XCTAssertEqual(status, .denied, "A refusal stands until the user changes it themselves.")
    }

    // MARK: - Duplicate calls

    func testSecondStartIsRejectedWhileRecording() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        try await recorder.startRecording(to: try destination())

        await assertThrows(.alreadyRecording) {
            try await recorder.startRecording(to: try self.destination())
        }
        let started = await recorder.startCount
        XCTAssertEqual(started, 1)
    }

    func testSecondStopIsRejected() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        try await recorder.startRecording(to: try destination())
        _ = try await recorder.stopRecording()

        await assertThrows(.notRecording) {
            _ = try await recorder.stopRecording()
        }
        let stopped = await recorder.stopCount
        XCTAssertEqual(stopped, 1)
    }

    func testStopWithoutStartIsRejected() async {
        let recorder = DeterministicMeetingAudioRecorder()
        await assertThrows(.notRecording) {
            _ = try await recorder.stopRecording()
        }
    }

    // MARK: - Produced file

    func testStopProducesAFileTheImportValidatorAccepts() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        let url = try destination()
        try await recorder.startRecording(to: url)
        let recorded = try await recorder.stopRecording()

        XCTAssertEqual(recorded.fileURL, url)
        XCTAssertGreaterThan(recorded.byteSize, 0)
        XCTAssertEqual(recorded.duration, 2)

        // The same gate an imported file passes, so a recording cannot enter on easier terms.
        let validated = try AudioFileValidator().validate(recorded.fileURL)
        XCTAssertEqual(validated.byteSize, recorded.byteSize)
    }

    func testEmptyRecordingIsReportedRatherThanHandedOn() async throws {
        let recorder = DeterministicMeetingAudioRecorder(behavior: .producesEmptyRecording)
        try await recorder.startRecording(to: try destination())

        await assertThrows(.noAudioCaptured) {
            _ = try await recorder.stopRecording()
        }
    }

    func testCancelRemovesTheRecordingAndAllowsStartingAgain() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        let url = try destination()
        try await recorder.startRecording(to: url)

        await recorder.cancelRecording()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await recorder.startRecording(to: try destination())
    }

    /// Teardown paths call this unconditionally, so it must not be an error when nothing is running.
    func testCancelWithoutRecordingIsHarmless() async {
        let recorder = DeterministicMeetingAudioRecorder()
        await recorder.cancelRecording()
        let cancels = await recorder.cancelCount
        XCTAssertEqual(cancels, 1)
    }

    // MARK: - Scratch store

    /// A predictable name would leak the meeting title and let two recordings collide.
    func testDestinationsAreUUIDBasedAndUnique() throws {
        let first = try scratch.makeDestination(fileExtension: "m4a")
        let second = try scratch.makeDestination(fileExtension: "m4a")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".m4a"))
        let stem = first.deletingPathExtension().lastPathComponent
        XCTAssertNotNil(UUID(uuidString: stem), "The name must be a bare UUID: \(stem)")
    }

    func testScratchDirectoryIsSeparateFromTheManagedAudioStore() {
        XCTAssertNotEqual(
            RecordingScratchStore.defaultDirectoryURL().standardizedFileURL,
            AudioAssetStore.defaultDirectoryURL().standardizedFileURL,
            "An abandoned recording must never sit where a meeting's audio lives."
        )
    }

    func testRemoveAllClearsLeftoverRecordings() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        let url = try destination()
        try await recorder.startRecording(to: url)
        _ = try await recorder.stopRecording()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        scratch.removeAll()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "The launch-time cleanup must clear what a crashed session left behind."
        )
    }

    func testRemovingAnAlreadyMissingFileIsHarmless() throws {
        scratch.remove(try destination())
    }

    // MARK: - File extension honesty

    /// The caller must take the extension from the recorder rather than assume one: a `.m4a`
    /// holding WAV bytes passes extension-based validation and then confuses whatever opens it.
    func testRecorderDeclaresAnExtensionMatchingWhatItWrites() async throws {
        let recorder = DeterministicMeetingAudioRecorder()
        XCTAssertEqual(recorder.fileExtension, "wav")
        XCTAssertEqual(AVFoundationMeetingAudioRecorder().fileExtension, "m4a")

        let url = try scratch.makeDestination(fileExtension: recorder.fileExtension)
        try await recorder.startRecording(to: url)
        let recorded = try await recorder.stopRecording()

        XCTAssertEqual(recorded.fileURL.pathExtension, "wav")
        // The bytes really are a RIFF/WAVE container, not just a name.
        let header = try Data(contentsOf: recorded.fileURL).prefix(12)
        XCTAssertEqual(header.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(header.suffix(4), Data("WAVE".utf8))
    }

    /// Both extensions the recorders declare must be ones the import path already accepts.
    func testDeclaredExtensionsAreAcceptedByTheImportValidator() {
        XCTAssertTrue(AudioFileValidator.supportedExtensions.contains(AVFoundationMeetingAudioRecorder().fileExtension))
        XCTAssertTrue(AudioFileValidator.supportedExtensions.contains(DeterministicMeetingAudioRecorder().fileExtension))
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: MeetingAudioRecorderError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as MeetingAudioRecorderError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but got \(error).", file: file, line: line)
        }
    }
}
