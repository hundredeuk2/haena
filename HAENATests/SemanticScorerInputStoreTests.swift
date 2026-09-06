import Foundation
import XCTest
@testable import HAENA

final class SemanticScorerInputStoreTests: XCTestCase {
    private static let predictionHash = "sha256:" + String(repeating: "a", count: 64)
    private static let otherPredictionHash = "sha256:" + String(repeating: "b", count: 64)
    private static let goldHash = "sha256:" + String(repeating: "c", count: 64)
    private static let otherGoldHash = "sha256:" + String(repeating: "d", count: 64)
    private static let caseID = "SYN-SEM-D01"

    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testAuthorizedDevelopmentInputReadsMetadataBeforePayload() throws {
        let fixture = try makeFixture()
        let recorder = RecordingSemanticScorerFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)
        let indexText = try XCTUnwrap(
            String(contentsOf: fixture.indexURL, encoding: .utf8)
        )

        XCTAssertFalse(indexText.contains("payload_path"))
        XCTAssertFalse(indexText.contains("semantic-scorer-inputs"))

        let authorized = try store.authorize(fixture.request())

        XCTAssertEqual(authorized.caseID, Self.caseID)
        XCTAssertEqual(authorized.split, .development)
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path])

        let input = try store.loadInput(for: authorized)

        XCTAssertEqual(input, fixture.input)
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path, fixture.payloadURL.path])
    }

    func testPendingPrimaryNormalizedAndUnfinishedSecondaryInputsFailBeforePayloadOpen() throws {
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
                false,
                false,
                .secondaryReviewIncomplete
            ),
            (SemanticScorerInputStatus.scorerReady.rawValue, false, true, .inputNotScorerReady),
            (SemanticScorerInputStatus.scorerReady.rawValue, true, false, .secondaryReviewIncomplete),
        ]

        for (status, ready, secondaryComplete, refusal) in cases {
            let fixture = try makeFixture(
                status: status,
                scorerReady: ready,
                secondaryReviewComplete: secondaryComplete
            )
            try assertAuthorizationRefused(refusal, fixture: fixture, request: fixture.request())
        }
    }

    func testSealedAndMissingRuntimeAuthorizationFailWithoutPayloadOpen() throws {
        let sealed = try makeFixture(split: .sealedHoldout)
        try assertAuthorizationRefused(
            .sealedHoldout,
            fixture: sealed,
            request: sealed.request(requestedSplit: .sealedHoldout),
            expectedIndexReads: 0
        )

        let missing = try makeFixture()
        try assertAuthorizationRefused(
            .authorizationMissing,
            fixture: missing,
            request: missing.request(runtimeAuthorization: nil),
            expectedIndexReads: 0
        )
    }

    func testUnknownInputMapAndPolicyVersionsFailBeforePayloadOpen() throws {
        let unknownIndex = try makeFixture(indexSchemaVersion: "haena-semantic-scorer-index-v9")
        try assertAuthorizationRefused(
            .unknownIndexSchemaVersion,
            fixture: unknownIndex,
            request: unknownIndex.request()
        )

        let unknownInput = try makeFixture(inputSchemaVersion: "haena-semantic-scorer-input-v9")
        try assertAuthorizationRefused(
            .unknownInputSchemaVersion,
            fixture: unknownInput,
            request: unknownInput.request()
        )

        let fixture = try makeFixture()
        let unknownMap = SemanticMatchingMap(
            schemaVersion: "haena-semantic-matching-map-v9",
            caseID: Self.caseID,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: Self.goldHash,
            pairs: fixture.matchingMap.pairs
        )
        try assertAuthorizationRefused(
            .unknownMatchingMapVersion,
            fixture: fixture,
            request: fixture.request(matchingMap: unknownMap)
        )

        let unknownPolicy = SemanticMatchingMap(
            policyVersion: "haena-semantic-fuzzy-v9",
            caseID: Self.caseID,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: Self.goldHash,
            pairs: fixture.matchingMap.pairs
        )
        try assertAuthorizationRefused(
            .unknownMatchingPolicyVersion,
            fixture: fixture,
            request: fixture.request(matchingMap: unknownPolicy)
        )
    }

    func testPredictionAndGoldHashMismatchesFailBeforePayloadOpen() throws {
        let fixture = try makeFixture()

        try assertAuthorizationRefused(
            .predictionArtifactHashMismatch,
            fixture: fixture,
            request: fixture.request(predictionArtifactHash: Self.otherPredictionHash)
        )
        try assertAuthorizationRefused(
            .goldInputHashMismatch,
            fixture: fixture,
            request: fixture.request(goldInputHash: Self.otherGoldHash)
        )

        let predictionMap = SemanticMatchingMap(
            caseID: Self.caseID,
            predictionArtifactHash: Self.otherPredictionHash,
            goldInputHash: Self.goldHash,
            pairs: fixture.matchingMap.pairs
        )
        try assertAuthorizationRefused(
            .predictionArtifactHashMismatch,
            fixture: fixture,
            request: fixture.request(matchingMap: predictionMap)
        )

        let goldMap = SemanticMatchingMap(
            caseID: Self.caseID,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: Self.otherGoldHash,
            pairs: fixture.matchingMap.pairs
        )
        try assertAuthorizationRefused(
            .goldInputHashMismatch,
            fixture: fixture,
            request: fixture.request(matchingMap: goldMap)
        )
    }

    func testDanglingPredictionAndGoldReferencesFailBeforePayloadOpen() throws {
        let fixture = try makeFixture()
        let pair = try XCTUnwrap(fixture.matchingMap.pairs.first)
        let danglingPrediction = SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: Self.caseID,
            kind: .actionItem,
            proposalID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        )
        let predictionMap = fixture.map(pairs: [
            SemanticMatchingPair(prediction: danglingPrediction, gold: pair.gold),
        ])
        try assertAuthorizationRefused(
            .danglingPredictionReference,
            fixture: fixture,
            request: fixture.request(matchingMap: predictionMap)
        )

        let danglingGold = SemanticGoldReference(
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            caseID: Self.caseID,
            kind: .actionItem,
            outputID: GoldOutputID(rawValue: "gold-action-unknown")
        )
        let goldMap = fixture.map(pairs: [
            SemanticMatchingPair(prediction: pair.prediction, gold: danglingGold),
        ])
        try assertAuthorizationRefused(
            .danglingGoldReference,
            fixture: fixture,
            request: fixture.request(matchingMap: goldMap)
        )
    }

    func testCrossCaseAndCrossKindPairsFailBeforePayloadOpen() throws {
        let fixture = try makeFixture()
        let pair = try XCTUnwrap(fixture.matchingMap.pairs.first)
        let crossCasePrediction = SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: "SYN-SEM-D02",
            kind: .actionItem,
            proposalID: pair.prediction.proposalID
        )
        try assertAuthorizationRefused(
            .crossCasePair,
            fixture: fixture,
            request: fixture.request(
                matchingMap: fixture.map(pairs: [
                    SemanticMatchingPair(prediction: crossCasePrediction, gold: pair.gold),
                ])
            )
        )

        let crossKindPrediction = SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: Self.caseID,
            kind: .decision,
            proposalID: pair.prediction.proposalID
        )
        try assertAuthorizationRefused(
            .crossKindPair,
            fixture: fixture,
            request: fixture.request(
                availablePredictions: [crossKindPrediction],
                matchingMap: fixture.map(pairs: [
                    SemanticMatchingPair(prediction: crossKindPrediction, gold: pair.gold),
                ])
            )
        )
    }

    func testDuplicatePredictionAndGoldUseFailBeforePayloadOpen() throws {
        let twoGold = Self.outputs(actionIDs: ["gold-action-1", "gold-action-2"])
        let predictionFixture = try makeFixture(outputs: twoGold)
        let prediction = try XCTUnwrap(predictionFixture.availablePredictions.first)
        let gold = predictionFixture.goldReferences
        try assertAuthorizationRefused(
            .duplicatePredictionUse,
            fixture: predictionFixture,
            request: predictionFixture.request(
                matchingMap: predictionFixture.map(pairs: [
                    SemanticMatchingPair(prediction: prediction, gold: gold[0]),
                    SemanticMatchingPair(prediction: prediction, gold: gold[1]),
                ])
            )
        )

        let twoPredictions = [
            prediction,
            SemanticPredictionReference(
                artifactFingerprint: Self.predictionHash,
                caseID: Self.caseID,
                kind: .actionItem,
                proposalID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
            ),
        ]
        let goldFixture = try makeFixture(predictions: twoPredictions)
        let oneGold = try XCTUnwrap(goldFixture.goldReferences.first)
        try assertAuthorizationRefused(
            .duplicateGoldUse,
            fixture: goldFixture,
            request: goldFixture.request(
                matchingMap: goldFixture.map(pairs: [
                    SemanticMatchingPair(prediction: twoPredictions[0], gold: oneGold),
                    SemanticMatchingPair(prediction: twoPredictions[1], gold: oneGold),
                ])
            )
        )
    }

    func testCaseIdentityMismatchFailsBeforePayloadOpen() throws {
        let fixture = try makeFixture()
        let mismatchedMap = SemanticMatchingMap(
            caseID: "SYN-SEM-D02",
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: Self.goldHash,
            pairs: fixture.matchingMap.pairs
        )

        try assertAuthorizationRefused(
            .caseIdentityMismatch,
            fixture: fixture,
            request: fixture.request(matchingMap: mismatchedMap)
        )
    }

    func testSemanticInputAndMatchingMapSerializationAreDeterministic() throws {
        let forwardOutputs = Self.outputs(actionIDs: ["gold-action-1", "gold-action-2"], reverseEvidence: false)
        let reverseOutputs = Self.outputs(actionIDs: ["gold-action-2", "gold-action-1"], reverseEvidence: true)
        let first = Self.input(outputs: forwardOutputs)
        let second = Self.input(outputs: reverseOutputs)

        XCTAssertEqual(
            try SemanticScorerInput.encoder.encode(first),
            try SemanticScorerInput.encoder.encode(second)
        )

        let predictions = [Self.prediction(id: 1), Self.prediction(id: 2)]
        let references = Self.goldReferences(for: first)
        let pairs = [
            SemanticMatchingPair(prediction: predictions[0], gold: references[0]),
            SemanticMatchingPair(prediction: predictions[1], gold: references[1]),
        ]
        let forwardMap = Self.matchingMap(pairs: pairs)
        let reverseMap = Self.matchingMap(pairs: Array(pairs.reversed()))
        XCTAssertEqual(
            try SemanticMatchingMap.encoder.encode(forwardMap),
            try SemanticMatchingMap.encoder.encode(reverseMap)
        )
    }

    func testSemanticInputWireCarriesNoTranscriptTextReviewerNotesOrPaths() throws {
        let data = try SemanticScorerInput.encoder.encode(Self.input(outputs: Self.outputs()))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        for forbidden in ["transcript", "reviewer_note", "output_text", "/Users/"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }

    func testDefaultCLIRejectsScoreWithoutReadingSemanticScorerStore() throws {
        let root = temporaryRoot()
        let recorder = RecordingSemanticScorerFileManager()
        _ = SemanticScorerInputStore(root: root, fileManager: recorder)

        XCTAssertThrowsError(
            try BenchmarkCommandLine.parse([
                "--dataset-root", "synthetic", "--output-dir", "out", "--score",
            ])
        ) { error in
            XCTAssertEqual(error as? BenchmarkCommandLine.ParseError, .unknownFlag("--score"))
        }
        XCTAssertTrue(recorder.accessedPaths.isEmpty)
    }

    private func assertAuthorizationRefused(
        _ expected: SemanticScorerRefusal,
        fixture: Fixture,
        request: SemanticScorerAuthorizationRequest,
        expectedIndexReads: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorder = RecordingSemanticScorerFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)

        XCTAssertThrowsError(try store.authorize(request), file: file, line: line) { error in
            XCTAssertEqual(error as? SemanticScorerRefusal, expected, file: file, line: line)
        }
        XCTAssertEqual(
            recorder.accessedPaths.filter { $0 == fixture.indexURL.path }.count,
            expectedIndexReads,
            file: file,
            line: line
        )
        XCTAssertFalse(
            recorder.accessedPaths.contains(fixture.payloadURL.path),
            "authorization refusal must never open the payload",
            file: file,
            line: line
        )
    }

    private func makeFixture(
        indexSchemaVersion: String = SemanticScorerInputStore.indexSchemaVersion,
        inputSchemaVersion: String = SemanticScorerInput.schemaVersion,
        split: BenchmarkSplit = .development,
        status: String = SemanticScorerInputStatus.scorerReady.rawValue,
        scorerReady: Bool = true,
        secondaryReviewComplete: Bool = true,
        matchingPolicyVersion: String = SemanticMatchingMap.policyVersion,
        outputs: SemanticGoldOutputCollections = SemanticScorerInputStoreTests.outputs(),
        predictions: [SemanticPredictionReference] = [SemanticScorerInputStoreTests.prediction(id: 1)]
    ) throws -> Fixture {
        let root = temporaryRoot()
        let payloadRoot = root.appendingPathComponent("semantic-scorer-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)

        let input = Self.input(
            schemaVersion: inputSchemaVersion,
            split: split,
            status: status == SemanticScorerInputStatus.scorerReady.rawValue ? .scorerReady : .pending,
            scorerReady: scorerReady,
            secondaryReviewComplete: secondaryReviewComplete,
            matchingPolicyVersion: matchingPolicyVersion,
            outputs: outputs
        )
        let goldReferences = Self.goldReferences(for: input)
        let pairs = zip(predictions, goldReferences).map {
            SemanticMatchingPair(prediction: $0.0, gold: $0.1)
        }
        let matchingMap = Self.matchingMap(
            policyVersion: matchingPolicyVersion,
            pairs: pairs
        )
        let entry = SemanticScorerSourceIndexEntry(
            indexSchemaVersion: indexSchemaVersion,
            inputSchemaVersion: inputSchemaVersion,
            benchmark: "meeting-execution-v0",
            caseID: Self.caseID,
            split: split,
            status: status,
            scorerReady: scorerReady,
            secondaryReviewComplete: secondaryReviewComplete,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: Self.goldHash,
            matchingPolicyVersion: matchingPolicyVersion,
            goldReferences: goldReferences
        )

        let indexURL = root.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName)
        let indexEncoder = JSONEncoder()
        indexEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var indexData = try indexEncoder.encode(entry)
        indexData.append(0x0A)
        try indexData.write(to: indexURL)

        let payloadURL = payloadRoot.appendingPathComponent("\(Self.caseID).json")
        try SemanticScorerInput.encoder.encode(input).write(to: payloadURL)

        return Fixture(
            root: root,
            indexURL: indexURL,
            payloadURL: payloadURL,
            input: input,
            availablePredictions: predictions,
            goldReferences: goldReferences,
            matchingMap: matchingMap
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-SemanticScorer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private static func input(
        schemaVersion: String = SemanticScorerInput.schemaVersion,
        split: BenchmarkSplit = .development,
        status: SemanticScorerInputStatus = .scorerReady,
        scorerReady: Bool = true,
        secondaryReviewComplete: Bool = true,
        matchingPolicyVersion: String = SemanticMatchingMap.policyVersion,
        outputs: SemanticGoldOutputCollections
    ) -> SemanticScorerInput {
        SemanticScorerInput(
            schemaVersion: schemaVersion,
            status: status,
            scorerReady: scorerReady,
            secondaryReviewComplete: secondaryReviewComplete,
            benchmark: "meeting-execution-v0",
            caseID: caseID,
            split: split,
            predictionArtifactHash: predictionHash,
            goldInputHash: goldHash,
            matchingPolicyVersion: matchingPolicyVersion,
            outputs: outputs,
            forbiddenInferences: [
                SemanticForbiddenInference(
                    id: "forbidden-1",
                    outputKind: .actionItem,
                    basis: .absenceInWindow,
                    evidenceUtteranceIDs: []
                ),
            ],
            ambiguityPolicy: SemanticAmbiguityPolicy(
                handling: .requireExplicitResolution,
                ambiguityIDs: ["ambiguity-2", "ambiguity-1"]
            )
        )
    }

    private static func outputs(
        actionIDs: [String] = ["gold-action-1"],
        reverseEvidence: Bool = false
    ) -> SemanticGoldOutputCollections {
        SemanticGoldOutputCollections(
            decisions: [],
            actionItems: actionIDs.map { id in
                SemanticGoldOutput(
                    id: GoldOutputID(rawValue: id),
                    evidenceUtteranceIDs: reverseEvidence ? ["SYN.2", "SYN.1"] : ["SYN.1", "SYN.2"],
                    inferenceClass: .explicit,
                    targetSpeakerResponsibility: .targetSpeakerResponsible,
                    assignee: SemanticAssigneeExpectation(
                        scope: .individual,
                        basis: .speakerCommitment,
                        valueReference: "speaker:B",
                        evidenceUtteranceIDs: ["SYN.1"]
                    ),
                    due: SemanticDueExpectation(
                        status: .explicit,
                        value: "2026-09-30",
                        evidenceUtteranceIDs: ["SYN.2"]
                    )
                )
            },
            openQuestions: [],
            nextAgenda: []
        )
    }

    private static func prediction(id: Int) -> SemanticPredictionReference {
        SemanticPredictionReference(
            artifactFingerprint: predictionHash,
            caseID: caseID,
            kind: .actionItem,
            proposalID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
        )
    }

    private static func goldReferences(for input: SemanticScorerInput) -> [SemanticGoldReference] {
        input.outputs.referencesByKind.map { kind, output in
            SemanticGoldReference(
                inputSchemaVersion: input.schemaVersion,
                caseID: input.caseID,
                kind: kind,
                outputID: output.id
            )
        }
    }

    private static func matchingMap(
        policyVersion: String = SemanticMatchingMap.policyVersion,
        pairs: [SemanticMatchingPair]
    ) -> SemanticMatchingMap {
        SemanticMatchingMap(
            policyVersion: policyVersion,
            caseID: caseID,
            predictionArtifactHash: predictionHash,
            goldInputHash: goldHash,
            pairs: pairs
        )
    }
}

private struct Fixture {
    let root: URL
    let indexURL: URL
    let payloadURL: URL
    let input: SemanticScorerInput
    let availablePredictions: [SemanticPredictionReference]
    let goldReferences: [SemanticGoldReference]
    let matchingMap: SemanticMatchingMap

    func request(
        runtimeAuthorization: SemanticScorerRuntimeAuthorization? = .development(),
        requestedSplit: BenchmarkSplit = .development,
        predictionArtifactHash: String = "sha256:" + String(repeating: "a", count: 64),
        goldInputHash: String = "sha256:" + String(repeating: "c", count: 64),
        availablePredictions: [SemanticPredictionReference]? = nil,
        matchingMap: SemanticMatchingMap? = nil
    ) -> SemanticScorerAuthorizationRequest {
        SemanticScorerAuthorizationRequest(
            runtimeAuthorization: runtimeAuthorization,
            requestedSplit: requestedSplit,
            benchmark: "meeting-execution-v0",
            caseID: "SYN-SEM-D01",
            predictionArtifactHash: predictionArtifactHash,
            goldInputHash: goldInputHash,
            availablePredictions: availablePredictions ?? self.availablePredictions,
            matchingMap: matchingMap ?? self.matchingMap
        )
    }

    func map(pairs: [SemanticMatchingPair]) -> SemanticMatchingMap {
        SemanticMatchingMap(
            caseID: "SYN-SEM-D01",
            predictionArtifactHash: "sha256:" + String(repeating: "a", count: 64),
            goldInputHash: "sha256:" + String(repeating: "c", count: 64),
            pairs: pairs
        )
    }
}

private final class RecordingSemanticScorerFileManager: FileManager {
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
}
