import XCTest
@testable import HAENA

/// Covers the two things the deterministic player cannot answer: whether the real AVFoundation
/// adapter reads an actual file correctly, and whether a meeting recorded from the microphone is
/// offered exactly what an imported one is.
///
/// The real adapter is exercised for loading only — opening a file, reporting its length, and
/// rejecting one that is missing, empty, or not audio. It is never asked to `play()` here: sound
/// coming out of the machine running the tests is left to the manual check, deliberately.
final class MeetingAudioPlaybackBoundaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try AudioTestSupport.makeTemporaryDirectory(self)
    }

    /// A real, well-formed WAV, synthesized rather than bundled — the same bytes the deterministic
    /// recorder produces, so what is loaded here is what a recording actually looks like.
    private func writeRealAudioFile(seconds: TimeInterval = 1.5) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try DeterministicMeetingAudioRecorder.silentWAVData(seconds: seconds, sampleRate: 44_100)
            .write(to: url, options: .atomic)
        return url
    }

    // MARK: - The real adapter

    func testRealPlayerLoadsAStoredRecordingAndReportsItsLength() async throws {
        let url = try writeRealAudioFile(seconds: 1.5)
        let player = AVFoundationMeetingAudioPlayer()

        let duration = try await player.load(url)

        XCTAssertEqual(duration, 1.5, accuracy: 0.05)
        let time = await player.currentTime()
        let playing = await player.isPlaying()
        XCTAssertEqual(time, 0)
        XCTAssertFalse(playing)
    }

    /// The meeting still names a stored copy, but the file went away — deleted by hand, or lost
    /// with the container. The app has to say so rather than fail as a decoding problem.
    func testRealPlayerReportsAMissingFileAsMissing() async {
        let url = directory.appendingPathComponent("nothing-here.m4a")
        let player = AVFoundationMeetingAudioPlayer()

        await assertLoadFails(.fileMissing, player: player, url: url)
    }

    func testRealPlayerRejectsAFileThatIsNotAudio() async throws {
        let url = try AudioTestSupport.writeFile(named: "corrupt.m4a", byteCount: 4_096, in: directory)
        let player = AVFoundationMeetingAudioPlayer()

        await assertLoadFails(.unreadableAudio, player: player, url: url)
    }

    /// A truncated recording can still open on some codecs. Zero playable length is treated as
    /// unreadable so the UI never offers a play button that could not do anything.
    func testRealPlayerRejectsAnEmptyFile() async throws {
        let url = directory.appendingPathComponent("empty.wav")
        try Data().write(to: url)
        let player = AVFoundationMeetingAudioPlayer()

        await assertLoadFails(.unreadableAudio, player: player, url: url)
    }

    /// Teardown paths call these unconditionally, including on a player that never loaded.
    func testRealPlayerControlsAreHarmlessBeforeAnythingIsLoaded() async {
        let player = AVFoundationMeetingAudioPlayer()
        await player.pause()
        await player.seekToStart()
        await player.stop()

        let time = await player.currentTime()
        let playing = await player.isPlaying()
        XCTAssertEqual(time, 0)
        XCTAssertFalse(playing)
    }

    // MARK: - One path for both input methods

    /// The whole point of the change: a microphone recording and an imported file resolve to the
    /// same stored copy through the same function, so neither can be offered a different player.
    func testMicrophoneAndImportedMeetingsResolveTheSameStoredFile() {
        let store = AudioAssetStore(directoryURL: directory)
        let asset = Self.asset()

        let recorded = Self.meeting(sourceType: .microphone, asset: asset)
        let imported = Self.meeting(sourceType: .audioFile, asset: asset)

        let recordedURL = MeetingAudioPlayback.fileURL(for: recorded, in: store)
        let importedURL = MeetingAudioPlayback.fileURL(for: imported, in: store)

        XCTAssertNotNil(recordedURL)
        XCTAssertEqual(recordedURL, importedURL)
        XCTAssertEqual(recordedURL, store.url(for: asset))
    }

    func testMeetingsWithNoStoredAudioGetNoPlayer() {
        let store = AudioAssetStore(directoryURL: directory)

        let pasted = Self.meeting(sourceType: .pastedText, asset: nil)
        XCTAssertNil(MeetingAudioPlayback.fileURL(for: pasted, in: store))

        // The recording was deleted but the transcript remains — a meeting, just not a playable one.
        let audioless = Self.meeting(sourceType: .microphone, asset: nil)
        XCTAssertNil(MeetingAudioPlayback.fileURL(for: audioless, in: store))

        // No store wired in at all (previews, and call sites that predate audio import).
        XCTAssertNil(MeetingAudioPlayback.fileURL(for: Self.meeting(sourceType: .audioFile, asset: Self.asset()), in: nil))
    }

    /// A recording that reached the app the other way must not resolve somewhere else on disk.
    func testTheResolvedFileIsTheAppsOwnStoredCopy() throws {
        let store = AudioAssetStore(directoryURL: directory)
        let source = try writeRealAudioFile()
        let validated = try AudioFileValidator().validate(source)
        let asset = try store.store(validated, id: TestFixtures.meetingID, importedAt: TestFixtures.fixedDate)

        let meeting = Self.meeting(sourceType: .microphone, asset: asset)
        let url = MeetingAudioPlayback.fileURL(for: meeting, in: store)

        XCTAssertEqual(url?.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertNotEqual(url, source, "Playback must read the app's copy, never the user's original.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(url).path))
    }

    // MARK: - Transcript actions do not depend on how the audio arrived

    /// Copy and export are driven by the transcript, so a microphone meeting offers them on exactly
    /// the same terms as an imported one — and produces the same document apart from the one line
    /// that names the input method.
    func testMicrophoneMeetingExportsTheSameTranscriptDocumentAsAnImportedOne() {
        let recorded = Self.meeting(sourceType: .microphone, asset: Self.asset())
        let imported = Self.meeting(sourceType: .audioFile, asset: Self.asset())

        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(recorded))
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(imported))

        let renderer = MeetingTranscriptMarkdownRenderer()
        let recordedMarkdown = renderer.render(meeting: recorded)
        let importedMarkdown = renderer.render(meeting: imported)

        XCTAssertEqual(
            recordedMarkdown.components(separatedBy: "## 전사").last,
            importedMarkdown.components(separatedBy: "## 전사").last,
            "The transcript itself must not vary with how the audio arrived."
        )
        XCTAssertTrue(recordedMarkdown.contains("- 입력 방식: \(MeetingSourceTypeDisplay.label(for: .microphone))"))
        XCTAssertEqual(
            MeetingTranscriptMarkdownRenderer.filename(for: recorded),
            MeetingTranscriptMarkdownRenderer.filename(for: imported)
        )
    }

    /// Nothing about playback may change what the exports contain.
    func testPlaybackDoesNotAlterTheExportedDocuments() {
        let meeting = Self.meeting(sourceType: .microphone, asset: Self.asset())
        let markdown = MeetingTranscriptMarkdownRenderer().render(meeting: meeting)

        XCTAssertFalse(markdown.contains(Self.asset().storedFileName), "No internal file name may leak.")
        XCTAssertFalse(markdown.contains("재생"))

        let project = AudioTestSupport.project(meetings: [meeting])
        let projectMarkdown = ProjectMarkdownRenderer().render(
            project: project,
            summary: ProjectStatusSummary.complete(project: project, referenceDate: TestFixtures.fixedDate),
            generatedAt: TestFixtures.fixedDate
        )
        XCTAssertFalse(projectMarkdown.contains("## 전사"))
        XCTAssertFalse(projectMarkdown.contains(Self.asset().storedFileName))
    }

    // MARK: - Fixtures

    private static func asset() -> AudioAsset {
        AudioAsset(
            id: UUID(uuidString: "77777777-0000-0000-0000-000000000001")!,
            storedFileName: "77777777-0000-0000-0000-000000000001.m4a",
            originalFileName: "회의 녹음.m4a",
            byteSize: 176_128,
            importedAt: TestFixtures.fixedDate
        )
    }

    private static func meeting(sourceType: MeetingSourceType, asset: AudioAsset?) -> Meeting {
        Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "제품 점검 회의",
            occurredAt: TestFixtures.fixedDate,
            sourceType: sourceType,
            participants: [],
            transcriptSegments: [
                TranscriptSegment(
                    id: UUID(uuidString: "77777777-0000-0000-0000-0000000000AA")!,
                    meetingID: TestFixtures.meetingID,
                    speakerID: nil,
                    text: "오늘 배포 일정을 먼저 확인하겠습니다.",
                    startTime: 3,
                    endTime: 11
                )
            ],
            createdAt: TestFixtures.fixedDate,
            audioAsset: asset
        )
    }

    private func assertLoadFails(
        _ expected: MeetingAudioPlayerError,
        player: AVFoundationMeetingAudioPlayer,
        url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await player.load(url)
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as MeetingAudioPlayerError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but got \(error).", file: file, line: line)
        }
    }
}
