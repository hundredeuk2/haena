import Foundation
import XCTest
@testable import HAENA

/// Returns a canned transcription (or throws a canned error) without touching a network, and
/// records what it was asked to transcribe.
///
/// An `actor` because the capture service calls it across suspension points and tests read the
/// recorded requests afterwards.
actor StubTranscriptionProvider: TranscriptionProvider {
    enum Outcome: Sendable {
        case success([TranscriptionSegment])
        case failure(TranscriptionError)
    }

    private let outcome: Outcome
    private(set) var receivedRequests: [TranscriptionRequest] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    nonisolated var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            fileTranscription: true,
            segmentTimestamps: true,
            speakerDiarization: true,
            wordTimestamps: false,
            maximumFileBytes: AudioFileValidator.maximumFileBytes
        )
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        receivedRequests.append(request)
        switch outcome {
        case .failure(let error):
            throw error
        case .success(let segments):
            return TranscriptionResult(
                segments: segments,
                metadata: ModelRunMetadata(
                    provider: .openAI,
                    modelID: "stub-transcribe",
                    completedAt: TestFixtures.fixedDate
                )
            )
        }
    }
}

/// Shared helpers for audio-import tests: a throwaway directory per test, and real files on disk
/// (rather than a mocked `FileManager`) so validation and copying are exercised for real.
enum AudioTestSupport {
    /// Creates a temp directory and registers its removal as a test teardown block.
    static func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENAAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    static func writeFile(
        named name: String,
        byteCount: Int,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: byteCount).write(to: url)
        return url
    }

    static func segment(
        _ text: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        speaker: String? = nil
    ) -> TranscriptionSegment {
        TranscriptionSegment(text: text, startTime: start, endTime: end, speakerLabel: speaker)
    }

    static func project(id: UUID = TestFixtures.projectID, meetings: [Meeting] = []) -> Project {
        Project(
            id: id,
            name: "HAE.NA",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: meetings,
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    /// Hands out a fixed sequence of UUIDs so a test can assert on exact identifiers instead of
    /// whatever `UUID()` produced.
    final class IDSequence: @unchecked Sendable {
        private var index = 0
        private let lock = NSLock()

        func next() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            index += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
    }
}
