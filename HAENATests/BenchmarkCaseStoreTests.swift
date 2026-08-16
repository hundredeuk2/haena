import XCTest
@testable import HAENA

/// Corpus loading, and the one place where the sealed-holdout lock has to be real.
///
/// The central test in this file is
/// `testALockedHoldoutCaseFailsIdenticallyWhenItsFileHasBeenDeleted`. A gate that merely happened
/// to fail because a file was missing, or that ran after the read, would look exactly like a
/// working gate in every other test. So the lock is proved twice over: the case file is deleted
/// before the request, and a recording `FileManager` asserts that nothing ever asked for it.
final class BenchmarkCaseStoreTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func syntheticDataset(
        development: [String] = ["SYN-D1", "SYN-D2"],
        sealedHoldout: [String] = ["SYN-H1", "SYN-H2"]
    ) throws -> URL {
        let root = try BenchmarkFixtures.writeTemporaryDataset(
            developmentCaseIDs: development,
            sealedHoldoutCaseIDs: sealedHoldout
        )
        temporaryRoots.append(root)
        return root
    }

    /// A dataset root with a hand-written source index and no `cases/` directory, for the index
    /// parsing paths that must fail before any case file is involved.
    private func datasetRoot(sourceIndexText: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-BenchmarkCaseStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        if let sourceIndexText {
            try Data(sourceIndexText.utf8).write(to: root.appendingPathComponent("source-index.jsonl"))
        }
        return root
    }

    private static func sourceIndexLine(_ caseID: String, split: String) -> String {
        """
        {"case_id": "\(caseID)", "split": "\(split)", "benchmark": "meeting-execution-v0", \
        "schema_version": "haena-benchmark-v0.1", "review_status": "human_review_pending", \
        "case_path": "cases/\(caseID).json"}
        """
    }

    /// Built by decoding rather than by a memberwise initializer, so this suite depends only on
    /// the manifest wire format.
    private func sourceIndexEntry(_ caseID: String, split: String) throws -> BenchmarkSourceIndexEntry {
        try JSONDecoder().decode(
            BenchmarkSourceIndexEntry.self,
            from: Data(Self.sourceIndexLine(caseID, split: split).utf8)
        )
    }

    private func unlockedPolicy() -> BenchmarkAccessPolicy {
        var policy = BenchmarkAccessPolicy()
        policy.unlockedSealedHoldout = true
        return policy
    }

    private func assertLocked<T>(
        _ caseIDs: [String],
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? BenchmarkAccessError,
                .sealedHoldoutLocked(caseIDs: caseIDs),
                "expected a sealed-holdout refusal, got \(error)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Discovery

    func testTheSourceIndexIsReadWholeAndSplitsAreDecoded() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        let entries = try store.sourceIndexEntries()

        XCTAssertEqual(entries.map(\.caseID), ["SYN-D1", "SYN-D2", "SYN-H1", "SYN-H2"])
        XCTAssertEqual(
            entries.filter { $0.split == .development }.map(\.caseID),
            ["SYN-D1", "SYN-D2"]
        )
        XCTAssertEqual(
            entries.filter { $0.split == .sealedHoldout }.map(\.caseID),
            ["SYN-H1", "SYN-H2"]
        )
    }

    func testBlankSourceIndexLinesAreSkippedRatherThanTreatedAsMalformed() throws {
        let text = """
        \(Self.sourceIndexLine("SYN-D1", split: "development"))

        \(Self.sourceIndexLine("SYN-D2", split: "development"))

        """
        let store = BenchmarkCaseStore(datasetRoot: try datasetRoot(sourceIndexText: text))

        XCTAssertEqual(try store.sourceIndexEntries().map(\.caseID), ["SYN-D1", "SYN-D2"])
    }

    func testSourceIndexRejectsTranscriptOrAnyOtherNonMetadataField() throws {
        let line = Self.sourceIndexLine("SYN-D1", split: "development")
            .replacingOccurrences(of: "}", with: ", \"transcript\": [{\"text\": \"sealed\"}]}")
        let store = BenchmarkCaseStore(datasetRoot: try datasetRoot(sourceIndexText: line))

        XCTAssertThrowsError(try store.sourceIndexEntries()) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .malformedSourceIndexLine(lineNumber: 1))
        }
    }

    func testSourceIndexRejectsACasePathThatDoesNotMatchTheCaseID() throws {
        let line = Self.sourceIndexLine("SYN-D1", split: "development")
            .replacingOccurrences(of: "cases/SYN-D1.json", with: "cases/SYN-H1.json")
        let store = BenchmarkCaseStore(datasetRoot: try datasetRoot(sourceIndexText: line))

        XCTAssertThrowsError(try store.sourceIndexEntries()) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .malformedSourceIndexLine(lineNumber: 1))
        }
    }

    func testEntriesForASplitReturnOnlyThatSplit() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        XCTAssertEqual(try store.entries(in: .development).map(\.caseID), ["SYN-D1", "SYN-D2"])
    }

    func testEntriesForExplicitIDsKeepTheRequestedOrder() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        let entries = try store.entries(caseIDs: ["SYN-D2", "SYN-D1"])

        XCTAssertEqual(entries.map(\.caseID), ["SYN-D2", "SYN-D1"])
    }

    func testAnUnknownCaseIDIsRejectedByName() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        XCTAssertThrowsError(try store.entries(caseIDs: ["SYN-D1", "MEV0-999"])) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .unknownCaseID("MEV0-999"))
        }
    }

    // MARK: - The sealed-holdout lock

    func testRequestingTheSealedSplitUnderTheDefaultPolicyFails() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        assertLocked([], try store.entries(in: .sealedHoldout))
    }

    func testNamingASealedCaseUnderTheDefaultPolicyFails() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())

        assertLocked(["SYN-H1"], try store.entries(caseIDs: ["SYN-H1"]))
        assertLocked(["SYN-H2"], try store.entries(caseIDs: ["SYN-D1", "SYN-H2"]))
    }

    /// The load path re-checks rather than trusting that discovery already did. A
    /// `BenchmarkSourceIndexEntry` is an ordinary value a caller can build or hold on to, so the
    /// guarantee has to be enforced at the moment of the read.
    func testPreparingASealedCaseUnderTheDefaultPolicyFailsEvenWhenTheEntryIsHandedInDirectly() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())
        let entry = try sourceIndexEntry("SYN-H1", split: "sealed_holdout")

        assertLocked(["SYN-H1"], try store.prepared(entry))
    }

    /// The test the whole gate exists for.
    ///
    /// The sealed case file is deleted first, so a gate that ran *after* the read would report a
    /// missing file rather than a lock — and the control below shows the store really does report a
    /// missing file when that is what happened. A recording `FileManager` then proves the stronger
    /// statement: the file was not merely unreadable, it was never asked for.
    func testALockedHoldoutCaseFailsIdenticallyWhenItsFileHasBeenDeleted() throws {
        let root = try syntheticDataset()
        let sealedFile = root.appendingPathComponent("cases/SYN-H1.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sealedFile.path),
            "the fixture must have written the file this test deletes"
        )
        try FileManager.default.removeItem(at: sealedFile)

        let recorder = RecordingBenchmarkFileManager()
        let store = BenchmarkCaseStore(datasetRoot: root, fileManager: recorder)

        assertLocked(["SYN-H1"], try store.entries(caseIDs: ["SYN-H1"]))
        assertLocked(["SYN-H1"], try store.prepared(try sourceIndexEntry("SYN-H1", split: "sealed_holdout")))
        assertLocked([], try store.entries(in: .sealedHoldout))

        let accessed = recorder.accessedPaths
        XCTAssertFalse(
            accessed.contains { $0.hasSuffix("SYN-H1.json") },
            "a locked case file must never be opened; the store asked for \(accessed)"
        )
        XCTAssertTrue(
            accessed.allSatisfy { $0.hasSuffix("source-index.jsonl") },
            "discovery may read the transcript-free index and nothing else; the store asked for \(accessed)"
        )
        XCTAssertFalse(accessed.isEmpty, "the recorder must be wired in, or this proves nothing")
    }

    /// The control for the test above: when a *development* case file is missing, the store says so.
    /// Without this, "the sealed request failed" would be consistent with the lock doing nothing.
    func testAMissingDevelopmentCaseFileIsReportedAsAMissingFileNotAsALock() throws {
        let root = try syntheticDataset()
        try FileManager.default.removeItem(at: root.appendingPathComponent("cases/SYN-D1.json"))
        let store = BenchmarkCaseStore(datasetRoot: root)
        let entry = try XCTUnwrap(try store.entries(in: .development).first)

        XCTAssertThrowsError(try store.prepared(entry)) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .caseFileNotFound(caseID: "SYN-D1"))
        }
    }

    /// Unlocking is verified against a synthetic dataset only. The real corpus's holdout stays
    /// sealed: this suite must never be the thing that spends it.
    func testAnUnlockedPolicyReadsSealedCasesFromASyntheticDataset() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset(), policy: unlockedPolicy())

        let entries = try store.entries(in: .sealedHoldout)
        XCTAssertEqual(entries.map(\.caseID), ["SYN-H1", "SYN-H2"])

        let prepared = try store.prepared(try XCTUnwrap(entries.first))
        XCTAssertEqual(prepared.caseID, "SYN-H1")
        XCTAssertEqual(prepared.split, .sealedHoldout)
        XCTAssertGreaterThan(prepared.utteranceCount, 0)
    }

    // MARK: - Loading

    func testPreparingADevelopmentCaseCarriesTheCorpusIdentityThrough() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())
        let entry = try XCTUnwrap(try store.entries(caseIDs: ["SYN-D1"]).first)

        let prepared = try store.prepared(entry)

        XCTAssertEqual(prepared.caseID, "SYN-D1")
        XCTAssertEqual(prepared.split, .development)
        XCTAssertEqual(prepared.benchmark, "meeting-execution-v0")
        XCTAssertEqual(prepared.datasetSchemaVersion, "haena-benchmark-v0.1")
        XCTAssertTrue(
            prepared.sourceCaseHash.hasPrefix("sha256:"),
            "the artifact has to be able to name the exact bytes it was produced from"
        )
        XCTAssertEqual(prepared.utteranceCount, prepared.extractionInput.excerpts.count)
    }

    func testSourceIndexSplitOverridesAStaleEmbeddedCaseSplit() throws {
        let root = try syntheticDataset(development: ["SYN-D1"], sealedHoldout: [])
        let caseURL = root.appendingPathComponent("cases/SYN-D1.json")
        let staleBytes = try XCTUnwrap(FileManager.default.contents(atPath: caseURL.path))
        let staleText = try XCTUnwrap(String(data: staleBytes, encoding: .utf8))
            .replacingOccurrences(of: "\"split\": \"development\"", with: "\"split\": \"sealed_holdout\"")
        try Data(staleText.utf8).write(to: caseURL)

        let store = BenchmarkCaseStore(datasetRoot: root)
        let entry = try XCTUnwrap(try store.entries(in: .development).first)

        XCTAssertEqual(try store.prepared(entry).split, .development)
    }

    func testForgedDevelopmentEntryCannotOpenAnIndexedSealedCase() throws {
        let root = try syntheticDataset(development: [], sealedHoldout: ["SYN-H1"])
        let recorder = RecordingBenchmarkFileManager()
        let store = BenchmarkCaseStore(datasetRoot: root, fileManager: recorder)
        let forged = try sourceIndexEntry("SYN-H1", split: "development")

        assertLocked(["SYN-H1"], try store.prepared(forged))
        XCTAssertFalse(recorder.accessedPaths.contains { $0.hasSuffix("SYN-H1.json") })
    }

    /// The same bytes must prepare to the same thing every time, or a "reproducible" artifact is
    /// only reproducible within one process run.
    func testPreparingTheSameCaseTwiceProducesTheSameValue() throws {
        let store = BenchmarkCaseStore(datasetRoot: try syntheticDataset())
        let entry = try XCTUnwrap(try store.entries(caseIDs: ["SYN-D1"]).first)

        XCTAssertEqual(try store.prepared(entry), try store.prepared(entry))
    }

    // MARK: - Malformed inputs

    /// Path-independent by design: this payload can end up in a log or a CI transcript, and the
    /// dataset lives under the operator's home directory.
    func testAMissingSourceIndexIsReportedWithoutAnyFilesystemPath() throws {
        let store = BenchmarkCaseStore(datasetRoot: try datasetRoot(sourceIndexText: nil))

        XCTAssertThrowsError(try store.sourceIndexEntries()) { error in
            guard case .sourceIndexNotFound(let payload)? = error as? BenchmarkCaseStoreError else {
                return XCTFail("expected sourceIndexNotFound, got \(error)")
            }
            XCTAssertEqual(payload, "source-index.jsonl")
            XCTAssertFalse(payload.contains("/"), "the payload must not carry a path")
            XCTAssertFalse(String(describing: error).contains("/Users/"))
        }
    }

    func testAMalformedSourceIndexLineIsReportedByItsOneBasedLineNumber() throws {
        let text = """
        \(Self.sourceIndexLine("SYN-D1", split: "development"))
        {"case_id": "SYN-D2"}
        \(Self.sourceIndexLine("SYN-D3", split: "development"))
        """
        let store = BenchmarkCaseStore(datasetRoot: try datasetRoot(sourceIndexText: text))

        XCTAssertThrowsError(try store.sourceIndexEntries()) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .malformedSourceIndexLine(lineNumber: 2))
        }
    }

    /// A decoding failure must not become a transcript-carrying error value on its way up.
    func testAMalformedCaseFileIsReportedByCaseIDWithoutQuotingItsContent() throws {
        let root = try syntheticDataset()
        let secret = "이 문장은 오류 값에 실려 나가면 안 됩니다"
        try Data("{\"schema_version\": \"\(secret)\"".utf8)
            .write(to: root.appendingPathComponent("cases/SYN-D1.json"))
        let store = BenchmarkCaseStore(datasetRoot: root)
        let entry = try XCTUnwrap(try store.entries(caseIDs: ["SYN-D1"]).first)

        XCTAssertThrowsError(try store.prepared(entry)) { error in
            XCTAssertEqual(error as? BenchmarkCaseStoreError, .malformedCaseFile(caseID: "SYN-D1"))
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }

    // MARK: - The real corpus

    /// The corpus is local-only (`/data/` is gitignored), so this skips rather than fails where it
    /// is absent. Where it is present, it is the only check that the manifest this harness was
    /// written against is the manifest that exists.
    ///
    /// Nothing here opens a sealed-holdout case file. The sealed split is exercised only through
    /// the lock, which fails before any read.
    func testTheRealCorpusHasSixteenDevelopmentAndEightSealedCases() throws {
        let store = try realCorpusStore()

        let entries = try store.sourceIndexEntries()
        XCTAssertEqual(entries.count, 24)
        XCTAssertEqual(try store.entries(in: .development).count, 16)
        XCTAssertEqual(entries.filter { $0.split == .sealedHoldout }.count, 8)
        XCTAssertTrue(
            entries.allSatisfy { $0.benchmark == "meeting-execution-v0" && $0.schemaVersion == "haena-benchmark-v0.1" },
            "the harness only understands haena-benchmark-v0.1 of meeting-execution-v0"
        )

        assertLocked([], try store.entries(in: .sealedHoldout))
    }

    /// One real development case loaded end to end, so the loader is checked against real corpus
    /// bytes and not only against the synthetic fixture that was written to please it.
    func testARealDevelopmentCaseLoads() throws {
        let store = try realCorpusStore()
        let entry = try XCTUnwrap(try store.entries(in: .development).first)

        let prepared = try store.prepared(entry)

        XCTAssertEqual(prepared.split, .development)
        XCTAssertEqual(prepared.caseID, entry.caseID)
        XCTAssertGreaterThan(prepared.utteranceCount, 0)
        XCTAssertGreaterThan(prepared.meeting.participants.count, 0)
        XCTAssertTrue(
            prepared.isGoldPending,
            "every case starts at human_review_pending; anything else means gold arrived and this harness needs revisiting"
        )
    }

    /// The repository root is derived from `#filePath` because `xcodebuild` does not forward shell
    /// environment variables to the test host, so an environment variable could not carry it. No
    /// path is committed by this: the literal is expanded at compile time.
    private func realCorpusStore() throws -> BenchmarkCaseStore {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repositoryRoot
            .appendingPathComponent("data/benchmarks/haena-v0/meeting-execution-v0", isDirectory: true)

        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("source-index.jsonl").path) else {
            throw XCTSkip("The meeting-execution-v0 corpus is local-only and is not present here.")
        }
        return BenchmarkCaseStore(datasetRoot: root)
    }
}

// MARK: - Recording file manager

/// Records every path the store asks the filesystem for.
///
/// This is what turns "the locked case failed" into "the locked case was never opened". It works
/// only because `BenchmarkCaseStore` reads through its injected `FileManager` rather than through
/// `Data(contentsOf:)`, which would bypass any observer.
///
/// No `Sendable` annotation: `FileManager` declares that conformance unavailable, and a subclass
/// inherits it. The static state is guarded by a lock because `URLSession` and `XCTest` can both
/// call in from other threads.
final class RecordingBenchmarkFileManager: FileManager {
    private let lock = NSLock()
    private var paths: [String] = []

    var accessedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    private func record(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    override func contents(atPath path: String) -> Data? {
        record(path)
        return super.contents(atPath: path)
    }

    override func fileExists(atPath path: String) -> Bool {
        record(path)
        return super.fileExists(atPath: path)
    }
}
