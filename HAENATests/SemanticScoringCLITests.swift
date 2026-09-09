import Foundation
import XCTest
@testable import HAENA

final class SemanticScoringCLITests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testExplicitScoreSubcommandWritesOnlyRegressionReport() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-001"])
        let recorder = RecordingSemanticScoringCLIFileManager()

        XCTAssertEqual(
            SemanticScoringCLI.run(arguments: fixture.arguments(), fileManager: recorder),
            SemanticScoringCLI.ExitCode.success
        )

        let data = try Data(contentsOf: fixture.outputFile)
        let report = try SemanticRegressionReport.decoder.decode(
            SemanticRegressionReport.self,
            from: data
        )
        XCTAssertEqual(report.schemaVersion, SemanticRegressionReport.schemaVersion)
        XCTAssertEqual(report.caseReports.map(\.caseID), ["SYN-CLI-001"])
        XCTAssertEqual(recorder.readCount, 5)
        XCTAssertEqual(recorder.payloadReadCount, 1)
        XCTAssertEqual(Set(fixture.allInputURLs).count, recorder.accessedPathSet.count)
    }

    func testMultipleCasesAndReversedSelectionProduceIdenticalBytes() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-002", "SYN-CLI-003"])
        let first = fixture.options(caseIDs: ["SYN-CLI-003", "SYN-CLI-002"])
        _ = try SemanticScoringCLI.execute(options: first)
        let firstBytes = try Data(contentsOf: fixture.outputFile)

        let secondOutput = fixture.root.appendingPathComponent("report-reversed.json")
        let second = fixture.options(
            caseIDs: ["SYN-CLI-002", "SYN-CLI-003"],
            outputFile: secondOutput
        )
        _ = try SemanticScoringCLI.execute(options: second)

        XCTAssertEqual(firstBytes, try Data(contentsOf: secondOutput))
    }

    func testAllDevelopmentRequiresExplicitSelectionAndLoadsMetadataDiscovery() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-004", "SYN-CLI-005"])
        let options = fixture.options(allDevelopment: true)
        let report = try SemanticScoringCLI.execute(options: options)

        XCTAssertEqual(report.caseReports.map(\.caseID), ["SYN-CLI-004", "SYN-CLI-005"])
    }

    func testParserRequiresAuthorizationAndExactlyOneSelectionMode() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-006"])
        let base = fixture.arguments()
        let recorder = RecordingSemanticScoringCLIFileManager()
        let missingAuthorization = base.filter {
            $0 != SemanticScoringCommandLine.authorizeDevelopmentFlag
        }

        XCTAssertThrowsError(try SemanticScoringCommandLine.parse(missingAuthorization)) { error in
            XCTAssertEqual(
                error as? SemanticScoringCommandLine.ParseError,
                .missingRequired(flag: SemanticScoringCommandLine.authorizeDevelopmentFlag)
            )
        }
        XCTAssertEqual(
            SemanticScoringCLI.run(arguments: missingAuthorization, fileManager: recorder),
            SemanticScoringCLI.ExitCode.usage
        )
        XCTAssertEqual(recorder.readCount, 0)
        XCTAssertThrowsError(try SemanticScoringCommandLine.parse(
            removingFlagAndValue(SemanticScoringCommandLine.caseFlag, from: base)
        )) { error in
            XCTAssertEqual(error as? SemanticScoringCommandLine.ParseError, .missingCaseSelection)
        }
        XCTAssertThrowsError(try SemanticScoringCommandLine.parse(
            base + [SemanticScoringCommandLine.allDevelopmentFlag]
        )) { error in
            XCTAssertEqual(error as? SemanticScoringCommandLine.ParseError, .conflictingCaseSelection)
        }
    }

    func testHelpAndLegacyParsingPerformZeroScorerReads() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-007"])
        let recorder = RecordingSemanticScoringCLIFileManager()

        XCTAssertEqual(
            SemanticScoringCLI.run(arguments: ["--help"], fileManager: recorder),
            SemanticScoringCLI.ExitCode.success
        )
        XCTAssertThrowsError(try BenchmarkCommandLine.parse(["--score"])) { error in
            XCTAssertEqual(error as? BenchmarkCommandLine.ParseError, .unknownFlag("--score"))
        }
        XCTAssertEqual(recorder.readCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputFile.path))
    }

    func testSealedRequestRefusesBeforeEveryInputOpen() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-008"])
        let recorder = RecordingSemanticScoringCLIFileManager()
        let options = fixture.options(split: .sealedHoldout)

        try assertCLIRefusal(.sealedSplit) {
            try SemanticScoringCLI.execute(options: options, fileManager: recorder)
        }
        XCTAssertEqual(recorder.readCount, 0)
    }

    func testPendingAndUnfinishedSecondaryRefuseBeforeGoldPayloadOpen() throws {
        let cases: [(String, Bool, Bool, SemanticScorerRefusal)] = [
            (SemanticScorerInputStatus.pending.rawValue, false, false, .pendingInput),
            (
                SemanticScorerInputStatus.primaryNormalizedPendingSecondaryReview.rawValue,
                false,
                false,
                .primaryNormalizedInput
            ),
            (
                SemanticScorerInputStatus.secondaryReviewInProgress.rawValue,
                true,
                false,
                .secondaryReviewIncomplete
            ),
            (SemanticScorerInputStatus.scorerReady.rawValue, false, true, .inputNotScorerReady),
        ]

        for (offset, item) in cases.enumerated() {
            let caseID = "SYN-CLI-01\(offset)"
            let fixture = try makeFixture(
                caseIDs: [caseID],
                status: item.0,
                scorerReady: item.1,
                secondaryReviewComplete: item.2
            )
            let recorder = RecordingSemanticScoringCLIFileManager()

            try assertCLIRefusal(.scorer(item.3)) {
                try SemanticScoringCLI.execute(
                    options: fixture.options(caseIDs: [caseID]),
                    fileManager: recorder
                )
            }
            XCTAssertEqual(recorder.payloadReadCount, 0)
            XCTAssertEqual(recorder.readCount, 4)
        }
    }

    func testUnknownReportAndIndexVersionsFailClosed() throws {
        let reportFixture = try makeFixture(caseIDs: ["SYN-CLI-012"])
        let reportRecorder = RecordingSemanticScoringCLIFileManager()
        try assertCLIRefusal(.unknownReportPolicyVersion) {
            try SemanticScoringCLI.execute(
                options: reportFixture.options(caseIDs: ["SYN-CLI-012"]),
                fileManager: reportRecorder,
                reportPolicy: SemanticScoringReportPolicy(schemaVersion: "report-v999")
            )
        }
        XCTAssertEqual(reportRecorder.readCount, 0)

        let indexFixture = try makeFixture(
            caseIDs: ["SYN-CLI-013"],
            indexSchemaVersion: "index-v999"
        )
        let indexRecorder = RecordingSemanticScoringCLIFileManager()
        try assertCLIRefusal(.scorer(.unknownIndexSchemaVersion)) {
            try SemanticScoringCLI.execute(
                options: indexFixture.options(caseIDs: ["SYN-CLI-013"]),
                fileManager: indexRecorder
            )
        }
        XCTAssertEqual(indexRecorder.payloadReadCount, 0)
    }

    func testUnknownInputMapAndObservationVersionsFailClosed() throws {
        let unknownInput = try makeFixture(
            caseIDs: ["SYN-CLI-014"],
            inputSchemaVersion: "input-v999"
        )
        try assertCLIRefusal(.scorer(.unknownInputSchemaVersion)) {
            try SemanticScoringCLI.execute(
                options: unknownInput.options(caseIDs: ["SYN-CLI-014"])
            )
        }

        let unknownMap = try makeFixture(caseIDs: ["SYN-CLI-015"])
        try unknownMap.rewriteMap(caseID: "SYN-CLI-015") { map in
            SemanticMatchingMap(
                schemaVersion: "map-v999",
                caseID: map.caseID,
                predictionArtifactHash: map.predictionArtifactHash,
                goldInputHash: map.goldInputHash,
                pairs: map.pairs
            )
        }
        try assertCLIRefusal(.scorer(.unknownMatchingMapVersion)) {
            try SemanticScoringCLI.execute(
                options: unknownMap.options(caseIDs: ["SYN-CLI-015"])
            )
        }

        let unknownObservation = try makeFixture(caseIDs: ["SYN-CLI-016"])
        try unknownObservation.rewriteObservations(caseID: "SYN-CLI-016") { set in
            SemanticPredictionMetricObservationSet(
                schemaVersion: "observations-v999",
                observations: set.observations
            )
        }
        try assertCLIRefusal(.scorer(.unknownPredictionObservationVersion)) {
            try SemanticScoringCLI.execute(
                options: unknownObservation.options(caseIDs: ["SYN-CLI-016"])
            )
        }
    }

    func testPredictionAndGoldRawByteHashMismatchesAreRefused() throws {
        let prediction = try makeFixture(caseIDs: ["SYN-CLI-017"])
        try appendWhitespace(to: prediction.predictionURL("SYN-CLI-017"))
        try assertCLIRefusal(.scorer(.predictionArtifactHashMismatch)) {
            try SemanticScoringCLI.execute(
                options: prediction.options(caseIDs: ["SYN-CLI-017"])
            )
        }

        let gold = try makeFixture(caseIDs: ["SYN-CLI-018"])
        try appendWhitespace(to: gold.payloadURL("SYN-CLI-018"))
        try assertCLIRefusal(.scorer(.payloadHashMismatch)) {
            try SemanticScoringCLI.execute(options: gold.options(caseIDs: ["SYN-CLI-018"]))
        }
    }

    func testArtifactCaseBenchmarkAndSplitMismatchesStopBeforeMapOpen() throws {
        let mutations: [(String, String, String)] = [
            ("SYN-CLI-019", "case_id", "OTHER-CASE"),
            ("SYN-CLI-020", "benchmark", "other-benchmark"),
            ("SYN-CLI-021", "split", BenchmarkSplit.sealedHoldout.rawValue),
        ]
        for item in mutations {
            let fixture = try makeFixture(caseIDs: [item.0])
            try fixture.rewritePredictionJSON(caseID: item.0) { object in
                object[item.1] = item.2
            }
            let recorder = RecordingSemanticScoringCLIFileManager()
            try assertCLIRefusal(.predictionIdentityMismatch) {
                try SemanticScoringCLI.execute(
                    options: fixture.options(caseIDs: [item.0]),
                    fileManager: recorder
                )
            }
            XCTAssertEqual(recorder.readCount, 1)
        }
    }

    func testMissingDuplicateAndCrossCaseMatchingMapsAreRefused() throws {
        let missing = try makeFixture(caseIDs: ["SYN-CLI-022"])
        try FileManager.default.removeItem(at: missing.mapURL("SYN-CLI-022"))
        try assertCLIRefusal(.matchingMapFileNotFound) {
            try SemanticScoringCLI.execute(options: missing.options(caseIDs: ["SYN-CLI-022"]))
        }

        let duplicate = try makeFixture(caseIDs: ["SYN-CLI-023"])
        try duplicate.rewriteMap(caseID: "SYN-CLI-023") { map in
            SemanticMatchingMap(
                caseID: map.caseID,
                predictionArtifactHash: map.predictionArtifactHash,
                goldInputHash: map.goldInputHash,
                pairs: map.pairs + map.pairs
            )
        }
        try assertCLIRefusal(.scorer(.duplicatePredictionUse)) {
            try SemanticScoringCLI.execute(
                options: duplicate.options(caseIDs: ["SYN-CLI-023"])
            )
        }

        let crossCase = try makeFixture(caseIDs: ["SYN-CLI-024"])
        try crossCase.rewriteMap(caseID: "SYN-CLI-024") { map in
            let original = map.pairs[0]
            let badGold = SemanticGoldReference(
                inputSchemaVersion: original.gold.inputSchemaVersion,
                caseID: "OTHER-CASE",
                kind: original.gold.kind,
                outputID: original.gold.outputID
            )
            return SemanticMatchingMap(
                caseID: map.caseID,
                predictionArtifactHash: map.predictionArtifactHash,
                goldInputHash: map.goldInputHash,
                pairs: [.init(prediction: original.prediction, gold: badGold)]
            )
        }
        try assertCLIRefusal(.scorer(.crossCasePair)) {
            try SemanticScoringCLI.execute(
                options: crossCase.options(caseIDs: ["SYN-CLI-024"])
            )
        }
    }

    func testMissingDuplicateAndExtraObservationsAreRefused() throws {
        let scenarios: [(String, SemanticScorerRefusal, ([SemanticPredictionMetricObservation]) -> [SemanticPredictionMetricObservation])] = [
            ("SYN-CLI-025", .missingPredictionObservation, { _ in [] }),
            ("SYN-CLI-026", .duplicatePredictionObservation, { [$0[0], $0[0]] }),
            ("SYN-CLI-027", .additionalPredictionObservation, { observations in
                let original = observations[0]
                let extraReference = SemanticPredictionReference(
                    artifactFingerprint: original.predictionReference.artifactFingerprint,
                    caseID: original.predictionReference.caseID,
                    kind: original.predictionReference.kind,
                    proposalID: UUID(uuidString: "00000000-0000-4000-8000-000000009999")!
                )
                let extra = SemanticPredictionMetricObservation(
                    predictionReference: extraReference,
                    evidence: original.evidence,
                    targetResponsibility: original.targetResponsibility,
                    assignee: original.assignee,
                    due: original.due
                )
                return observations + [extra]
            }),
        ]
        for scenario in scenarios {
            let fixture = try makeFixture(caseIDs: [scenario.0])
            try fixture.rewriteObservations(caseID: scenario.0) { set in
                SemanticPredictionMetricObservationSet(
                    observations: scenario.2(set.observations)
                )
            }
            try assertCLIRefusal(.scorer(scenario.1)) {
                try SemanticScoringCLI.execute(
                    options: fixture.options(caseIDs: [scenario.0])
                )
            }
        }
    }

    func testExistingOutputAndSecondRunNeverOverwriteBytes() throws {
        let existing = try makeFixture(caseIDs: ["SYN-CLI-028"])
        let original = Data("existing-report-sentinel".utf8)
        try original.write(to: existing.outputFile)
        let recorder = RecordingSemanticScoringCLIFileManager()
        try assertCLIRefusal(.outputExists) {
            try SemanticScoringCLI.execute(
                options: existing.options(caseIDs: ["SYN-CLI-028"]),
                fileManager: recorder
            )
        }
        XCTAssertEqual(try Data(contentsOf: existing.outputFile), original)
        XCTAssertEqual(recorder.readCount, 0)

        let second = try makeFixture(caseIDs: ["SYN-CLI-029"])
        _ = try SemanticScoringCLI.execute(options: second.options(caseIDs: ["SYN-CLI-029"]))
        let firstReport = try Data(contentsOf: second.outputFile)
        try assertCLIRefusal(.outputExists) {
            try SemanticScoringCLI.execute(options: second.options(caseIDs: ["SYN-CLI-029"]))
        }
        XCTAssertEqual(try Data(contentsOf: second.outputFile), firstReport)
    }

    func testFailureInLaterCaseLeavesNoFinalOrPartialReport() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-030", "SYN-CLI-031"])
        try appendWhitespace(to: fixture.payloadURL("SYN-CLI-031"))

        try assertCLIRefusal(.scorer(.payloadHashMismatch)) {
            try SemanticScoringCLI.execute(
                options: fixture.options(caseIDs: ["SYN-CLI-030", "SYN-CLI-031"])
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outputFile.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testPathTraversalAndOutputInsideInputRootAreRefusedWithoutReads() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-032"])
        let traversal = fixture.options(caseIDs: ["../SYN-CLI-032"])
        let traversalRecorder = RecordingSemanticScoringCLIFileManager()
        try assertCLIRefusal(.invalidIdentity) {
            try SemanticScoringCLI.execute(options: traversal, fileManager: traversalRecorder)
        }
        XCTAssertEqual(traversalRecorder.readCount, 0)

        let collisionOutput = fixture.predictionDirectory.appendingPathComponent("report.json")
        let collision = fixture.options(
            caseIDs: ["SYN-CLI-032"],
            outputFile: collisionOutput
        )
        let collisionRecorder = RecordingSemanticScoringCLIFileManager()
        try assertCLIRefusal(.outputInsideInputRoot) {
            try SemanticScoringCLI.execute(options: collision, fileManager: collisionRecorder)
        }
        XCTAssertEqual(collisionRecorder.readCount, 0)
    }

    func testReportContainsNoPayloadTextPathCredentialOrReviewerTripwire() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-033"])
        _ = try SemanticScoringCLI.execute(options: fixture.options(caseIDs: ["SYN-CLI-033"]))
        let output = try XCTUnwrap(String(data: Data(contentsOf: fixture.outputFile), encoding: .utf8))

        for forbidden in SemanticScoringCLIFixture.privacyTripwires {
            XCTAssertFalse(output.contains(forbidden), "report leaked \(forbidden)")
        }
        XCTAssertFalse(output.contains(fixture.root.path))
    }

    func testSuccessfulRunDoesNotMutateAnyInputAndConstructsNoNetworkSurface() throws {
        let fixture = try makeFixture(caseIDs: ["SYN-CLI-034"])
        let before = try Dictionary(uniqueKeysWithValues: fixture.allInputURLs.map {
            ($0, SemanticSHA256Digest.rawBytes(try Data(contentsOf: $0)))
        })

        _ = try SemanticScoringCLI.execute(options: fixture.options(caseIDs: ["SYN-CLI-034"]))

        let after = try Dictionary(uniqueKeysWithValues: fixture.allInputURLs.map {
            ($0, SemanticSHA256Digest.rawBytes(try Data(contentsOf: $0)))
        })
        XCTAssertEqual(after, before)
        XCTAssertFalse(SemanticScoringCLI.implementationDependencyNames.contains("provider"))
        XCTAssertFalse(SemanticScoringCLI.implementationDependencyNames.contains("network"))
    }

    private func makeFixture(
        caseIDs: [String],
        status: String = SemanticScorerInputStatus.scorerReady.rawValue,
        scorerReady: Bool = true,
        secondaryReviewComplete: Bool = true,
        indexSchemaVersion: String = SemanticScorerInputStore.indexSchemaVersion,
        inputSchemaVersion: String = SemanticScorerInput.schemaVersion
    ) throws -> SemanticScoringCLIFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HAENA-Semantic-CLI-\(UUID().uuidString)",
            isDirectory: true
        )
        temporaryRoots.append(root)
        return try SemanticScoringCLIFixture(
            root: root,
            caseIDs: caseIDs,
            status: status,
            scorerReady: scorerReady,
            secondaryReviewComplete: secondaryReviewComplete,
            indexSchemaVersion: indexSchemaVersion,
            inputSchemaVersion: inputSchemaVersion
        )
    }

    private func assertCLIRefusal(
        _ expected: SemanticScoringCLIRefusal,
        operation: () throws -> Void
    ) throws {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? SemanticScoringCLIRefusal, expected)
        }
    }

    private func appendWhitespace(to url: URL) throws {
        var data = try Data(contentsOf: url)
        data.append(0x20)
        try data.write(to: url)
    }

    private func removingFlagAndValue(_ flag: String, from arguments: [String]) -> [String] {
        var result = arguments
        if let index = result.firstIndex(of: flag) {
            result.remove(at: index)
            if index < result.count { result.remove(at: index) }
        }
        return result
    }
}

private final class RecordingSemanticScoringCLIFileManager: FileManager {
    private let lock = NSLock()
    private var paths: [String] = []

    var accessedPaths: [String] {
        lock.withLock { paths }
    }

    var accessedPathSet: Set<String> { Set(accessedPaths) }
    var readCount: Int { accessedPaths.count }
    var payloadReadCount: Int {
        accessedPaths.filter { $0.contains("/semantic-scorer-inputs/") }.count
    }

    override func contents(atPath path: String) -> Data? {
        lock.withLock { paths.append(path) }
        return super.contents(atPath: path)
    }
}

private struct SemanticScoringCLIFixture {
    static let benchmark = "meeting-execution-v0"
    static let privacyTripwires = [
        "PRIVATE_TRANSCRIPT_SENTINEL",
        "PRIVATE_TITLE_SENTINEL",
        "PRIVATE_REVIEWER_NOTE_SENTINEL",
        "/Users/private/secret/path",
        "sk-private-key-sentinel",
    ]

    let root: URL
    let scorerRoot: URL
    let predictionDirectory: URL
    let matchingMapDirectory: URL
    let observationDirectory: URL
    let outputFile: URL
    let caseIDs: [String]

    init(
        root: URL,
        caseIDs: [String],
        status: String,
        scorerReady: Bool,
        secondaryReviewComplete: Bool,
        indexSchemaVersion: String,
        inputSchemaVersion: String
    ) throws {
        self.root = root
        scorerRoot = root.appendingPathComponent("scorer", isDirectory: true)
        predictionDirectory = root.appendingPathComponent("predictions", isDirectory: true)
        matchingMapDirectory = root.appendingPathComponent("maps", isDirectory: true)
        observationDirectory = root.appendingPathComponent("observations", isDirectory: true)
        outputFile = root.appendingPathComponent("semantic-report.json")
        self.caseIDs = caseIDs

        let payloadDirectory = scorerRoot.appendingPathComponent(
            "semantic-scorer-inputs",
            isDirectory: true
        )
        for directory in [
            scorerRoot,
            payloadDirectory,
            predictionDirectory,
            matchingMapDirectory,
            observationDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var entries: [SemanticScorerSourceIndexEntry] = []
        for caseID in caseIDs {
            let proposalID = BenchmarkIdentity.proposalID(
                benchmark: Self.benchmark,
                caseID: caseID,
                ordinal: 0
            )
            let artifact = PredictionArtifact(
                benchmark: Self.benchmark,
                caseID: caseID,
                split: .development,
                datasetSchemaVersion: "synthetic-dataset-v0.1",
                sourceCaseHash: "sha256:" + String(repeating: "1", count: 64),
                extractionSchemaVersion: "synthetic-extraction-v0.1",
                promptRevision: Self.privacyTripwires[2],
                gitRevision: "synthetic-git-revision",
                provider: Self.privacyTripwires[4],
                modelID: Self.privacyTripwires[1],
                runMode: "offline_stub",
                executedAt: Date(timeIntervalSince1970: 0),
                scoring: BenchmarkScoring(reason: "human_review_pending"),
                inputSummary: .init(
                    utteranceCount: 1,
                    participantCount: 0,
                    speakerLabels: [],
                    unknownSpeakerUtteranceCount: 0
                ),
                raw: [],
                mapped: [
                    BenchmarkMappedProposal(
                        ordinal: 0,
                        kind: .decision,
                        id: proposalID,
                        text: Self.privacyTripwires[0],
                        confidence: 1,
                        evidenceSegmentID: BenchmarkIdentity.segmentID(
                            benchmark: Self.benchmark,
                            caseID: caseID,
                            utteranceID: "SYN.1"
                        ),
                        evidenceUtteranceID: "SYN.1",
                        evidenceQuote: Self.privacyTripwires[3],
                        status: "proposed"
                    ),
                ],
                rejected: []
            )
            let artifactData = try PredictionArtifact.encoder.encode(artifact)
            try artifactData.write(to: predictionURL(caseID))
            let fingerprint = PredictionArtifactFingerprint.rawArtifactBytes(artifactData)

            let goldOutput = SemanticGoldOutput(
                id: GoldOutputID(rawValue: "gold-1"),
                evidenceUtteranceIDs: ["SYN.1"],
                inferenceClass: .explicit,
                targetSpeakerResponsibility: .noResponsibilityAssigned
            )
            let input = SemanticScorerInput(
                status: .scorerReady,
                scorerReady: true,
                secondaryReviewComplete: true,
                benchmark: Self.benchmark,
                caseID: caseID,
                split: .development,
                predictionArtifactHash: fingerprint.rawValue,
                matchingPolicyVersion: SemanticMatchingMap.policyVersion,
                outputs: .init(
                    decisions: [goldOutput],
                    actionItems: [],
                    openQuestions: [],
                    nextAgenda: []
                ),
                forbiddenInferences: [],
                ambiguityPolicy: .init(
                    handling: .excludeFromMetrics,
                    ambiguityIDs: []
                )
            )
            let payloadData = try SemanticScorerInput.encoder.encode(input)
            try payloadData.write(to: payloadURL(caseID))
            let goldHash = SemanticSHA256Digest.rawBytes(payloadData)

            let predictionReference = SemanticPredictionReference(
                artifactFingerprint: fingerprint.rawValue,
                caseID: caseID,
                kind: .decision,
                proposalID: proposalID
            )
            let goldReference = SemanticGoldReference(
                inputSchemaVersion: SemanticScorerInput.schemaVersion,
                caseID: caseID,
                kind: .decision,
                outputID: goldOutput.id
            )
            let map = SemanticMatchingMap(
                caseID: caseID,
                predictionArtifactHash: fingerprint.rawValue,
                goldInputHash: goldHash,
                pairs: [.init(prediction: predictionReference, gold: goldReference)]
            )
            try SemanticMatchingMap.encoder.encode(map).write(to: mapURL(caseID))

            let observation = SemanticPredictionMetricObservation(
                predictionReference: predictionReference,
                evidence: .init(state: .known, utteranceIDs: ["SYN.1"]),
                targetResponsibility: .noResponsibilityAssigned,
                assignee: .init(state: .absent),
                due: .init(status: .absent)
            )
            try SemanticPredictionMetricObservationSet.encoder.encode(
                SemanticPredictionMetricObservationSet(observations: [observation])
            ).write(to: observationURL(caseID))

            entries.append(
                SemanticScorerSourceIndexEntry(
                    indexSchemaVersion: indexSchemaVersion,
                    inputSchemaVersion: inputSchemaVersion,
                    benchmark: Self.benchmark,
                    caseID: caseID,
                    split: .development,
                    status: status,
                    scorerReady: scorerReady,
                    secondaryReviewComplete: secondaryReviewComplete,
                    predictionArtifactHash: fingerprint.rawValue,
                    goldInputHash: goldHash,
                    matchingPolicyVersion: SemanticMatchingMap.policyVersion,
                    goldReferences: [goldReference]
                )
            )
        }
        try writeIndex(entries)
    }

    var allInputURLs: [URL] {
        [scorerRoot.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName)]
            + caseIDs.flatMap {
                [predictionURL($0), mapURL($0), observationURL($0), payloadURL($0)]
            }
    }

    func arguments() -> [String] {
        let caseArguments = caseIDs.flatMap { [SemanticScoringCommandLine.caseFlag, $0] }
        return baseArguments(outputFile: outputFile)
            + caseArguments
            + [SemanticScoringCommandLine.authorizeDevelopmentFlag]
    }

    func options(
        caseIDs: [String]? = nil,
        allDevelopment: Bool = false,
        split: BenchmarkSplit = .development,
        outputFile: URL? = nil
    ) -> SemanticScoringCommandLine.Options {
        SemanticScoringCommandLine.Options(
            scorerRoot: scorerRoot.path,
            predictionDirectory: predictionDirectory.path,
            matchingMapDirectory: matchingMapDirectory.path,
            observationDirectory: observationDirectory.path,
            outputFile: (outputFile ?? self.outputFile).path,
            benchmark: Self.benchmark,
            split: split,
            selection: allDevelopment
                ? .allDevelopment
                : .caseIDs(caseIDs ?? self.caseIDs),
            developmentScoringAuthorized: true
        )
    }

    func predictionURL(_ caseID: String) -> URL {
        predictionDirectory.appendingPathComponent(
            caseID + SemanticScoringArtifactStore.predictionSuffix
        )
    }

    func mapURL(_ caseID: String) -> URL {
        matchingMapDirectory.appendingPathComponent(
            caseID + SemanticScoringArtifactStore.matchingMapSuffix
        )
    }

    func observationURL(_ caseID: String) -> URL {
        observationDirectory.appendingPathComponent(
            caseID + SemanticScoringArtifactStore.observationSuffix
        )
    }

    func payloadURL(_ caseID: String) -> URL {
        scorerRoot.appendingPathComponent("semantic-scorer-inputs/\(caseID).json")
    }

    func rewriteMap(
        caseID: String,
        transform: (SemanticMatchingMap) -> SemanticMatchingMap
    ) throws {
        let original = try SemanticMatchingMap.decoder.decode(
            SemanticMatchingMap.self,
            from: Data(contentsOf: mapURL(caseID))
        )
        try SemanticMatchingMap.encoder.encode(transform(original)).write(to: mapURL(caseID))
    }

    func rewriteObservations(
        caseID: String,
        transform: (SemanticPredictionMetricObservationSet) -> SemanticPredictionMetricObservationSet
    ) throws {
        let original = try JSONDecoder().decode(
            SemanticPredictionMetricObservationSet.self,
            from: Data(contentsOf: observationURL(caseID))
        )
        try SemanticPredictionMetricObservationSet.encoder.encode(transform(original))
            .write(to: observationURL(caseID))
    }

    func rewritePredictionJSON(
        caseID: String,
        transform: (inout [String: Any]) -> Void
    ) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: predictionURL(caseID)))
                as? [String: Any]
        )
        transform(&object)
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: predictionURL(caseID))
    }

    private func baseArguments(outputFile: URL) -> [String] {
        [
            SemanticScoringCommandLine.scorerRootFlag, scorerRoot.path,
            SemanticScoringCommandLine.predictionDirectoryFlag, predictionDirectory.path,
            SemanticScoringCommandLine.matchingMapDirectoryFlag, matchingMapDirectory.path,
            SemanticScoringCommandLine.observationDirectoryFlag, observationDirectory.path,
            SemanticScoringCommandLine.outputFileFlag, outputFile.path,
            SemanticScoringCommandLine.benchmarkFlag, Self.benchmark,
        ]
    }

    private func writeIndex(_ entries: [SemanticScorerSourceIndexEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries.sorted(by: { $0.caseID < $1.caseID }) {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(
            to: scorerRoot.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName)
        )
    }
}

private extension SemanticScoringCLI {
    /// Compile-time dependency audit: this explicit entry point has no provider or transport input.
    static let implementationDependencyNames: Set<String> = [
        String(describing: SemanticScoringCommandLine.self),
        String(describing: SemanticScoringArtifactStore.self),
        String(describing: SemanticRegressionReport.self),
    ]
}
