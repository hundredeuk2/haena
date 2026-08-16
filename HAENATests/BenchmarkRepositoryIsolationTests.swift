import XCTest
@testable import HAENA

/// A benchmark run touches nothing outside itself.
///
/// Two failures would be silent and expensive, so both are asserted directly rather than argued
/// from the code's shape alone:
///
/// 1. **It must not write into the user's projects.** The harness drives the same extraction seam
///    the app drives, and the app's version of that flow saves. A run that quietly appended
///    twenty-four benchmark meetings to `projects.json` would look like a successful run.
/// 2. **It must not reach the network.** The default run is offline, and "offline" has to mean zero
///    requests, not "no requests we expected".
///
/// The network half is enforced by a globally registered `URLProtocol` that records and fails every
/// request it sees, plus a structural check — see
/// `testNothingInTheOfflineRunHoldsATransportOrASession` for why the interceptor alone is not the
/// whole guarantee.
final class BenchmarkRepositoryIsolationTests: XCTestCase {
    private static let fixedNow = Date(timeIntervalSince1970: 0)

    private var temporaryRoots: [URL] = []

    override func setUp() {
        super.setUp()
        RecordingBlockingURLProtocol.reset()
        URLProtocol.registerClass(RecordingBlockingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingBlockingURLProtocol.self)
        RecordingBlockingURLProtocol.reset()
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: - Running the harness

    private func syntheticDataset() throws -> URL {
        let root = try BenchmarkFixtures.writeTemporaryDataset(
            developmentCaseIDs: ["SYN-D1", "SYN-D2", "SYN-D3"],
            sealedHoldoutCaseIDs: ["SYN-H1"]
        )
        temporaryRoots.append(root)
        return root
    }

    /// Discovery, loading, extraction, mapping and artifact construction — the whole path a real
    /// run takes, minus only the CLI's argument parsing and file writing.
    @discardableResult
    private func runWholeDevelopmentSplit(
        datasetRoot: URL,
        fileManager: FileManager = .default
    ) async throws -> BenchmarkRunReport {
        let store = BenchmarkCaseStore(datasetRoot: datasetRoot, fileManager: fileManager)
        let entries = try store.entries(in: .development)
        let prepared = try entries.map { try store.prepared($0) }
        XCTAssertFalse(prepared.isEmpty, "a run over zero cases would prove nothing")

        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.fixedNow })
        let (report, outcomes) = await runner.run(prepared, options: BenchmarkFixtures.runOptions)

        XCTAssertEqual(report.caseCount, prepared.count)
        XCTAssertEqual(outcomes.count, prepared.count)
        return report
    }

    private func realCorpusRoot() throws -> URL {
        // `#filePath` rather than an environment variable: `xcodebuild` does not forward the shell
        // environment to the test host. The literal is expanded at compile time, so no path is
        // committed by this file.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("data/benchmarks/haena-v0/meeting-execution-v0", isDirectory: true)

        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("source-index.jsonl").path) else {
            throw XCTSkip("The meeting-execution-v0 corpus is local-only and is not present here.")
        }
        return root
    }

    // MARK: - The interceptor must be capable of failing

    /// Without this, "zero requests were recorded" would also be the result if the interceptor were
    /// never consulted at all.
    ///
    /// The probe targets `127.0.0.1:1`, so even a total interception failure produces an immediate
    /// local connection refusal rather than a packet leaving the machine.
    func testTheInterceptorRecordsAndFailsARequestThatIsActuallyMade() async throws {
        let probe = URL(string: "http://127.0.0.1:1/benchmark-guard-probe")!

        do {
            _ = try await URLSession.shared.data(from: probe)
            XCTFail("the interceptor must fail every request it sees")
        } catch {
            XCTAssertEqual(
                (error as? URLError)?.code,
                .notConnectedToInternet,
                "the failure must be the interceptor's, not a real connection failure"
            )
        }

        XCTAssertEqual(RecordingBlockingURLProtocol.recordedURLs, [probe.absoluteString])
    }

    // MARK: - Zero requests

    func testAWholeDevelopmentRunOverASyntheticDatasetMakesNoRequest() async throws {
        let report = try await runWholeDevelopmentSplit(datasetRoot: try syntheticDataset())

        XCTAssertEqual(report.runMode, BenchmarkProviderSelection.offlineStub.runMode)
        XCTAssertEqual(
            RecordingBlockingURLProtocol.recordedURLs,
            [],
            "an offline run must make no request at all"
        )
    }

    /// Recording the complete discovery/load/extraction path proves the sealed discovery boundary:
    /// development may read its own case files and the metadata index, but never the transcript
    /// manifest or any holdout case file.
    func testAWholeDevelopmentRunReadsNoManifestOrHoldoutCaseFile() async throws {
        let root = try syntheticDataset()
        let recorder = RecordingBenchmarkFileManager()

        let report = try await runWholeDevelopmentSplit(datasetRoot: root, fileManager: recorder)

        XCTAssertEqual(report.caseCount, 3)
        let accessed = recorder.accessedPaths
        XCTAssertEqual(accessed.filter { $0.hasSuffix("source-index.jsonl") }.count, 1)
        XCTAssertFalse(accessed.contains { $0.hasSuffix("manifest.jsonl") }, "manifest access must be zero: \(accessed)")
        XCTAssertFalse(accessed.contains { $0.hasSuffix("SYN-H1.json") }, "holdout case access must be zero: \(accessed)")
        for caseID in ["SYN-D1", "SYN-D2", "SYN-D3"] {
            XCTAssertEqual(accessed.filter { $0.hasSuffix("\(caseID).json") }.count, 1)
        }
    }

    /// The same run over the real corpus's sixteen development cases. The sealed holdout is not
    /// touched: `entries(in: .development)` is the only discovery call, and the default policy would
    /// refuse the other split anyway.
    func testAWholeDevelopmentRunOverTheRealCorpusMakesNoRequest() async throws {
        let report = try await runWholeDevelopmentSplit(datasetRoot: try realCorpusRoot())

        XCTAssertEqual(report.caseCount, 16)
        XCTAssertEqual(RecordingBlockingURLProtocol.recordedURLs, [])
    }

    /// The interceptor covers `URLSession.shared` but *not* a session built from its own
    /// `URLSessionConfiguration` — which is exactly what `URLSessionHTTPTransport` builds. So the
    /// offline guarantee rests on a second, structural fact: there is no transport and no session
    /// anywhere in the object graph an offline run assembles, and therefore nothing that could make
    /// the request the interceptor would have missed.
    func testNothingInTheOfflineRunHoldsATransportOrASession() throws {
        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.fixedNow })

        assertHoldsNoNetworkingOrStorage(runner, label: "BenchmarkRunner")
        assertHoldsNoNetworkingOrStorage(BenchmarkStubExtractor(), label: "BenchmarkStubExtractor")
        assertHoldsNoNetworkingOrStorage(
            BenchmarkCaseStore(datasetRoot: URL(fileURLWithPath: "/nonexistent")),
            label: "BenchmarkCaseStore"
        )
    }

    // MARK: - The user's projects

    /// The proof by absence, stated as a test: a runner that held a repository could write to it,
    /// and no assertion about one particular run would rule that out for the next one.
    func testTheRunnerHoldsNoProjectRepository() {
        let runner = BenchmarkRunner(extractor: BenchmarkStubExtractor(), now: { Self.fixedNow })

        for child in Mirror(reflecting: runner).children {
            XCTAssertFalse(
                child.value is any ProjectRepository,
                "\(child.label ?? "<unlabelled>") is a ProjectRepository"
            )
        }
    }

    func testAnInMemoryRepositoryIsUnchangedByAWholeHarnessRun() async throws {
        let repository = InMemoryProjectRepository()
        let first = ExtractionFixtures.project(with: [ExtractionFixtures.meeting()])
        let second = ExtractionFixtures.project(
            with: [],
            id: UUID(uuidString: "44000000-0000-0000-0000-000000000001")!
        )
        try await repository.save(first)
        try await repository.save(second)

        let before = try await repository.allProjects().sorted { $0.id.uuidString < $1.id.uuidString }

        try await runWholeDevelopmentSplit(datasetRoot: try syntheticDataset())

        let after = try await repository.allProjects().sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(after, before, "a benchmark run must leave the user's projects untouched")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(
            after.flatMap(\.meetings).map(\.id),
            before.flatMap(\.meetings).map(\.id),
            "no synthetic benchmark meeting may have been added"
        )
    }

    /// The on-disk form of the same guarantee: not merely equal values, but identical bytes. A
    /// repository that had been re-serialized — even to exactly the same content — would mean
    /// something wrote to it.
    func testAJSONRepositoryFileIsByteIdenticalAfterAWholeHarnessRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-BenchmarkIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryRoots.append(directory)

        let fileURL = directory.appendingPathComponent("projects.json")
        let repository = JSONProjectRepository(fileURL: fileURL)
        try await repository.save(ExtractionFixtures.project(with: [ExtractionFixtures.meeting()]))

        let before = try Data(contentsOf: fileURL)

        try await runWholeDevelopmentSplit(datasetRoot: try syntheticDataset())

        XCTAssertEqual(try Data(contentsOf: fileURL), before, "projects.json was rewritten by a benchmark run")

        let reloaded = try await JSONProjectRepository(fileURL: fileURL).allProjects()
        XCTAssertEqual(reloaded.count, 1)
    }

    /// The harness must not create the app's real project store either. Only the file's existence
    /// and modification date are inspected; its contents are never read.
    func testTheAppsOwnProjectStoreIsNeitherCreatedNorTouched() async throws {
        let url = JSONProjectRepository.defaultFileURL()
        let before = Self.modificationDate(of: url)

        try await runWholeDevelopmentSplit(datasetRoot: try syntheticDataset())

        XCTAssertEqual(
            Self.modificationDate(of: url),
            before,
            "a benchmark run reached the app's own projects.json"
        )
    }

    /// Nil when the file is absent, which is itself the assertion on a machine that has never run
    /// the app: absent before, absent after.
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Shared assertions

    /// Reflects one level down and rejects anything that could store or transmit: the value is a
    /// small struct, so one level is its whole surface.
    private func assertHoldsNoNetworkingOrStorage(
        _ value: Any,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for child in Mirror(reflecting: value).children {
            let name = child.label ?? "<unlabelled>"
            let typeName = String(describing: type(of: child.value))
            for forbidden in ["URLSession", "URLRequest", "HTTPTransport", "Repository", "Credential"] {
                XCTAssertFalse(
                    typeName.contains(forbidden),
                    "\(label).\(name) has type \(typeName), which contains \(forbidden)",
                    file: file,
                    line: line
                )
            }
            XCTAssertFalse(child.value is any HTTPTransport, "\(label).\(name) is an HTTPTransport", file: file, line: line)
            XCTAssertFalse(child.value is any ProjectRepository, "\(label).\(name) is a ProjectRepository", file: file, line: line)
        }
    }
}

// MARK: - Network interceptor

/// Records every request the URL loading system offers it and fails all of them.
///
/// Registered globally in `setUp` and removed in `tearDown`, so it cannot outlive this suite and
/// affect an unrelated test. Note the limit measured directly rather than assumed: a globally
/// registered protocol is consulted for `URLSession.shared`, but *not* for a session created from
/// its own `URLSessionConfiguration`. That is why the offline guarantee is asserted structurally as
/// well as observationally.
final class RecordingBlockingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [String] = []

    static var recordedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    static func reset() {
        lock.lock()
        urls = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        urls.append(request.url?.absoluteString ?? "<no url>")
        lock.unlock()
        // Claiming the request is what stops it: no socket is opened for a request this protocol
        // handles.
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
