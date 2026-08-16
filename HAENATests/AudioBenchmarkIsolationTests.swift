import Foundation
import XCTest
@testable import HAENA

final class AudioBenchmarkIsolationTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testDiscoveryReadsOnlyMetadataIndexAndNeverManifest() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )

        let entries = try store.sourceIndexEntries()

        XCTAssertEqual(entries.map(\.caseID), ["ARV0-D01", "ARV0-H01"])
        XCTAssertEqual(recorder.accessedPaths, [fixture.datasetRoot.appendingPathComponent("source-index.jsonl").path])
        XCTAssertFalse(recorder.accessedPaths.contains { $0.hasSuffix("manifest.jsonl") })
    }

    func testDevelopmentFlowReadsNoHoldoutGoldOrWAV() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )

        let development = try store.authorizedEntries(for: .development)
        XCTAssertEqual(development.map(\.caseID), ["ARV0-D01"])
        let entry = try XCTUnwrap(development.first)
        _ = try store.caseData(for: entry)
        _ = try store.sourceAssetData(relativePath: "wav/development.wav", for: entry)

        let paths = recorder.accessedPaths
        XCTAssertEqual(paths.filter { $0.hasSuffix("source-index.jsonl") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("ARV0-D01.json") }.count, 1)
        XCTAssertEqual(paths.filter { $0.hasSuffix("development.wav") }.count, 1)
        XCTAssertFalse(paths.contains { $0.hasSuffix("manifest.jsonl") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("ARV0-H01.json") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("holdout.wav") })
    }

    func testWholeSealedRequestIsRefusedBeforeIndexReadAndOutputCreation() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(datasetRoot: fixture.datasetRoot, fileManager: recorder)
        let output = fixture.root.appendingPathComponent("forbidden-output", isDirectory: true)

        XCTAssertThrowsError(try store.authorizedEntries(for: .sealedHoldout)) { error in
            XCTAssertEqual(error as? AudioBenchmarkIsolationError, .sealedHoldoutLocked)
        }
        XCTAssertTrue(recorder.accessedPaths.isEmpty, "sealed split admission must perform zero reads")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "refusal must not create output")
    }

    func testExplicitSealedCaseRefusalCarriesNoCaseIdentifierAndReadsNoCase() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(datasetRoot: fixture.datasetRoot, fileManager: recorder)

        XCTAssertThrowsError(try store.authorizedEntries(for: .caseIDs(["ARV0-H01"]))) { error in
            XCTAssertEqual(error as? AudioBenchmarkIsolationError, .sealedHoldoutLocked)
            XCTAssertFalse(String(describing: error).contains("ARV0-H01"))
        }
        XCTAssertEqual(recorder.accessedPaths.filter { $0.hasSuffix("source-index.jsonl") }.count, 1)
        XCTAssertFalse(recorder.accessedPaths.contains { $0.hasSuffix("ARV0-H01.json") })
    }

    func testIndexRejectsTranscriptAndEveryAdditionalKey() throws {
        for forbidden in [
            "\"transcript\":[{\"text\":\"sealed\"}]",
            "\"speaker_mapping\":{}",
            "\"gold\":{}",
            "\"source_audio_path\":\"wav/secret.wav\"",
            "\"unexpected\":true",
        ] {
            let line = indexLine(caseID: "ARV0-D01", split: "development")
                .dropLast() + ",\(forbidden)}"
            let fixture = try makeFixture(indexText: String(line))
            let store = AudioBenchmarkCaseStore(datasetRoot: fixture.datasetRoot)

            XCTAssertThrowsError(try store.sourceIndexEntries(), "forbidden key: \(forbidden)") { error in
                XCTAssertEqual(error as? AudioBenchmarkIsolationError, .malformedSourceIndexLine(lineNumber: 1))
            }
        }
    }

    func testIndexRejectsTraversalAbsoluteAndMismatchedCasePaths() throws {
        for path in ["../gold/ARV0-D01.json", "/tmp/ARV0-D01.json", "gold/ARV0-H01.json"] {
            let fixture = try makeFixture(indexText: indexLine(
                caseID: "ARV0-D01",
                split: "development",
                casePath: path
            ))
            let store = AudioBenchmarkCaseStore(datasetRoot: fixture.datasetRoot)

            XCTAssertThrowsError(try store.sourceIndexEntries(), "unsafe path: \(path)") { error in
                XCTAssertEqual(error as? AudioBenchmarkIsolationError, .malformedSourceIndexLine(lineNumber: 1))
            }
        }
    }

    func testIndexRejectsUnboundedOrNonFiniteReviewMetadata() throws {
        for status in ["", "human_review_pending", String(repeating: "sealed transcript ", count: 100)] {
            let line = indexLine(caseID: "ARV0-D01", split: "development")
                .replacingOccurrences(of: "source_aligned_label", with: status)
            let fixture = try makeFixture(indexText: line)

            XCTAssertThrowsError(try AudioBenchmarkCaseStore(datasetRoot: fixture.datasetRoot).sourceIndexEntries()) {
                XCTAssertEqual(
                    $0 as? AudioBenchmarkIsolationError,
                    .malformedSourceIndexLine(lineNumber: 1)
                )
            }
        }
    }

    func testSourceAssetTraversalIsRejectedBeforeAnyAssetRead() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )
        let entry = try XCTUnwrap(try store.authorizedEntries(for: .development).first)
        let before = recorder.accessedPaths

        for path in ["../holdout.wav", "/tmp/holdout.wav", "wav/../../holdout.wav", "wav\\holdout.wav"] {
            XCTAssertThrowsError(try store.sourceAssetData(relativePath: path, for: entry)) { error in
                XCTAssertEqual(error as? AudioBenchmarkIsolationError, .invalidRelativePath)
            }
        }
        XCTAssertEqual(recorder.accessedPaths, before)
    }

    func testSourceAssetSymlinkCannotEscapeAuthorizedRoot() throws {
        let fixture = try makeFixture()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("must-not-be-read".utf8).write(to: outside.appendingPathComponent("outside.wav"))
        let link = fixture.sourceRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )
        let entry = try XCTUnwrap(try store.authorizedEntries(for: .development).first)
        let before = recorder.accessedPaths

        XCTAssertThrowsError(try store.sourceAssetData(relativePath: "linked/outside.wav", for: entry)) {
            XCTAssertEqual($0 as? AudioBenchmarkIsolationError, .invalidRelativePath)
        }
        XCTAssertEqual(recorder.accessedPaths, before)
    }

    func testRawSealedIndexEntryDoesNotProduceAnAuthorizedCapability() throws {
        let fixture = try makeFixture()
        let recorder = RecordingAudioBenchmarkFileManager()
        let store = AudioBenchmarkCaseStore(
            datasetRoot: fixture.datasetRoot,
            sourceAssetRoot: fixture.sourceRoot,
            fileManager: recorder
        )
        let raw = try store.sourceIndexEntries()
        XCTAssertEqual(raw.filter { $0.split == .sealedHoldout }.map(\.caseID), ["ARV0-H01"])
        let readsAfterDiscovery = recorder.accessedPaths

        XCTAssertThrowsError(try store.authorizedEntries(for: .caseIDs(["ARV0-H01"]))) { error in
            XCTAssertEqual(error as? AudioBenchmarkIsolationError, .sealedHoldoutLocked)
        }
        XCTAssertEqual(
            Array(recorder.accessedPaths.dropFirst(readsAfterDiscovery.count)),
            [fixture.datasetRoot.appendingPathComponent("source-index.jsonl").path]
        )
        XCTAssertFalse(recorder.accessedPaths.contains { $0.hasSuffix("ARV0-H01.json") })
        XCTAssertFalse(recorder.accessedPaths.contains { $0.hasSuffix("holdout.wav") })
    }

    private func makeFixture(indexText: String? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-AudioIsolation-\(UUID().uuidString)", isDirectory: true)
        let datasetRoot = root.appendingPathComponent("audio-robustness-v0", isDirectory: true)
        let goldRoot = datasetRoot.appendingPathComponent("gold", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let wavRoot = sourceRoot.appendingPathComponent("wav", isDirectory: true)
        try FileManager.default.createDirectory(at: goldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wavRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let index = indexText ?? [
            indexLine(caseID: "ARV0-D01", split: "development"),
            indexLine(caseID: "ARV0-H01", split: "sealed_holdout"),
        ].joined(separator: "\n")
        try Data((index + "\n").utf8).write(to: datasetRoot.appendingPathComponent("source-index.jsonl"))
        try Data("must-not-be-read".utf8).write(to: datasetRoot.appendingPathComponent("manifest.jsonl"))
        try Data("{\"source\":\"development\"}".utf8)
            .write(to: goldRoot.appendingPathComponent("ARV0-D01.json"))
        try Data("{\"source\":\"holdout\"}".utf8)
            .write(to: goldRoot.appendingPathComponent("ARV0-H01.json"))
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wavRoot.appendingPathComponent("development.wav"))
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: wavRoot.appendingPathComponent("holdout.wav"))
        return Fixture(root: root, datasetRoot: datasetRoot, sourceRoot: sourceRoot)
    }

    private func indexLine(
        caseID: String,
        split: String,
        casePath: String? = nil
    ) -> String {
        """
        {"schema_version":"haena-benchmark-v0.1","benchmark":"audio-robustness-v0","case_id":"\(caseID)","split":"\(split)","review_status":"source_aligned_label","case_path":"\(casePath ?? "gold/\(caseID).json")"}
        """
    }
}

private struct Fixture {
    let root: URL
    let datasetRoot: URL
    let sourceRoot: URL
}

private final class RecordingAudioBenchmarkFileManager: FileManager {
    private let lock = NSLock()
    private var paths: [String] = []

    var accessedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override func contents(atPath path: String) -> Data? {
        lock.lock()
        paths.append(path)
        lock.unlock()
        return super.contents(atPath: path)
    }

    override func fileExists(atPath path: String) -> Bool {
        lock.lock()
        paths.append(path)
        lock.unlock()
        return super.fileExists(atPath: path)
    }
}
