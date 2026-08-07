import XCTest
@testable import HAENA

/// The one test that really calls OpenAI's transcription endpoint.
///
/// It is opt-in and skips by default, so a normal `xcodebuild test` run — and any CI — costs
/// nothing and touches no network. Every other transcription test drives a stub transport.
///
/// What it proves that fixtures cannot: that the multipart request this app actually builds is
/// accepted by the live endpoint, and that a real `diarized_json` response decodes into our DTOs
/// and maps onto stored `TranscriptSegment`s.
///
/// ## Opting in
///
/// Mirrors `OpenAIWorkStateExtractionLiveTests`, because `xcodebuild` does **not** forward the
/// invoking shell's environment to an app-hosted unit test process — exporting variables in a
/// terminal is not enough on its own. Two local files outside the repository drive this instead:
///
/// 1. `~/.haena-openai-live-key` — the API key, and its existence is itself the opt-in signal.
/// 2. `~/.haena-live-audio-path` — the absolute path of a real recording to send.
///
/// Both are also readable from the process environment (`OPENAI_API_KEY`,
/// `HAENA_LIVE_AUDIO_PATH`, with `HAENA_RUN_LIVE_OPENAI_TESTS=1`) when the test process's
/// environment can be set directly, e.g. from Xcode's scheme.
///
/// **Delete both files as soon as verification is done.** While the key file exists this test is
/// live, so *every* full test run makes a real, billed API call.
///
/// Only a non-sensitive recording may be used here — no real meeting audio may be sent to a
/// provider from a test.
final class OpenAITranscriptionLiveTests: XCTestCase {
    /// Deliberately outside the repository, so a credential can never be committed.
    private static let localKeyFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".haena-openai-live-key")

    /// Also outside the repository: the path points at audio, which must never be committed either.
    private static let localAudioPathFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".haena-live-audio-path")

    private static func trimmedContents(of url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Environment first, then the local file. Returns nil — never a partial or placeholder
    /// value — when neither source holds a usable key.
    private static func resolvedAPIKey(environment: [String: String]) -> String? {
        OpenAIConfiguration.apiKey(from: environment) ?? trimmedContents(of: localKeyFileURL)
    }

    private static func resolvedAudioPath(environment: [String: String]) -> String? {
        if let path = environment["HAENA_LIVE_AUDIO_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return path
        }
        return trimmedContents(of: localAudioPathFileURL)
    }

    func testLiveTranscriptionProducesSegmentsThatCanBeStored() async throws {
        let environment = ProcessInfo.processInfo.environment
        let optedInByEnvironment = environment["HAENA_RUN_LIVE_OPENAI_TESTS"] == "1"
        let hasLocalKeyFile = FileManager.default.fileExists(atPath: Self.localKeyFileURL.path)

        guard optedInByEnvironment || hasLocalKeyFile else {
            throw XCTSkip("""
            Live transcription check is opt-in (it makes a real, billed API call). Enable it by \
            creating ~/.haena-openai-live-key and ~/.haena-live-audio-path, or by setting \
            HAENA_RUN_LIVE_OPENAI_TESTS=1 in the test process's own environment.
            """)
        }
        guard let apiKey = Self.resolvedAPIKey(environment: environment) else {
            throw XCTSkip("No OpenAI credential found in the environment or ~/.haena-openai-live-key; skipping.")
        }
        guard let audioPath = Self.resolvedAudioPath(environment: environment) else {
            throw XCTSkip("No audio path found in HAENA_LIVE_AUDIO_PATH or ~/.haena-live-audio-path; skipping.")
        }

        let file = try AudioFileValidator().validate(URL(fileURLWithPath: audioPath))
        print("[live] audio bytes=\(file.byteSize) name=\(file.fileName)")

        // A throwaway store, so the live run cannot read or write the real Application Support data.
        let directory = try AudioTestSupport.makeTemporaryDirectory(self)
        let assetStore = AudioAssetStore(directoryURL: directory.appendingPathComponent("Audio", isDirectory: true))
        let repository = JSONProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))

        let service = AudioMeetingCaptureService(
            repository: repository,
            provider: OpenAITranscriptionProvider(apiKeyProvider: { apiKey }),
            assetStore: assetStore
        )
        let project = try await service.createProject(name: "Live Transcription Smoke Test")

        let started = Date()
        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "Live smoke test",
            fileURL: file.url
        )
        let elapsed = Date().timeIntervalSince(started)

        // Every assertion the smoke check is meant to make, in one place.
        XCTAssertFalse(meeting.transcriptSegments.isEmpty, "The response must contain at least one segment.")
        XCTAssertTrue(
            meeting.transcriptSegments.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            "No stored segment may have empty text."
        )
        for segment in meeting.transcriptSegments {
            guard let start = segment.startTime, let end = segment.endTime else {
                continue
            }
            XCTAssertGreaterThanOrEqual(start, 0, "A start time may not be negative.")
            XCTAssertGreaterThanOrEqual(end, start, "A segment may not end before it starts.")
        }
        XCTAssertNotNil(meeting.audioAsset, "The stored copy must be recorded on the meeting.")

        // Reported rather than asserted: diarization coming back is what this run is measuring,
        // and `speakerID = nil` is a legitimate outcome the product already handles.
        let timed = meeting.transcriptSegments.filter { $0.startTime != nil && $0.endTime != nil }.count
        let withSpeaker = meeting.transcriptSegments.filter { $0.speakerID != nil }.count
        print("""
        [live] segments=\(meeting.transcriptSegments.count) \
        timed=\(timed) withSpeaker=\(withSpeaker) speakers=\(meeting.participants.count) \
        elapsed=\(String(format: "%.1f", elapsed))s
        """)
        if let first = meeting.transcriptSegments.first {
            print("[live] firstSegment start=\(String(describing: first.startTime)) end=\(String(describing: first.endTime))")
        }
    }
}
