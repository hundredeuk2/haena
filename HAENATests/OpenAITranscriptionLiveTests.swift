import XCTest
@testable import HAENA

/// Opt-in smoke check against the real transcription endpoint.
///
/// **Skipped by default and never run in CI**: it makes a real, billed API call and needs an
/// audio file the repository does not contain. It exists so that when a key and a recording are
/// available, verifying the adapter against the live API is one command rather than a new test to
/// write — the request shape and the `diarized_json` response mapping are currently verified only
/// against fixtures.
final class OpenAITranscriptionLiveTests: XCTestCase {
    /// Point this at a real recording, e.g.
    /// `HAENA_LIVE_AUDIO_PATH=~/Desktop/00_code/haena-voice-bench/samples/S5.m4a`.
    private static let audioPathEnvironmentKey = "HAENA_LIVE_AUDIO_PATH"
    private static let optInEnvironmentKey = "HAENA_RUN_LIVE_OPENAI_TESTS"

    func testLiveTranscriptionProducesSegmentsThatCanBeStored() async throws {
        let environment = ProcessInfo.processInfo.environment

        guard environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip("""
            Live transcription check is opt-in (it makes a real, billed API call). Enable it with \
            \(Self.optInEnvironmentKey)=1 and \(Self.audioPathEnvironmentKey)=/path/to/audio.m4a.
            """)
        }
        guard let apiKey = OpenAIConfiguration.apiKey(from: environment) else {
            throw XCTSkip("No OPENAI_API_KEY in the environment; skipping.")
        }
        guard let audioPath = environment[Self.audioPathEnvironmentKey] else {
            throw XCTSkip("Set \(Self.audioPathEnvironmentKey) to a real recording; skipping.")
        }

        let file = try AudioFileValidator().validate(URL(fileURLWithPath: audioPath))

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
        let meeting = try await service.importAudioMeeting(
            projectID: project.id,
            title: "Live smoke test",
            fileURL: file.url
        )

        XCTAssertFalse(meeting.transcriptSegments.isEmpty)
        XCTAssertNotNil(meeting.audioAsset)
        print("[live] segments=\(meeting.transcriptSegments.count) speakers=\(meeting.participants.count)")
    }
}
