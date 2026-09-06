import Foundation
import XCTest
@testable import HAENA

final class SemanticScoringAccountingTests: XCTestCase {
    private static let caseID = "SYN-ACCOUNT-D01"
    private static let predictionFingerprint = PredictionArtifactFingerprint.rawArtifactBytes(
        Data("synthetic-accounting-prediction-artifact".utf8)
    )
    private static var predictionHash: String { predictionFingerprint.rawValue }

    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testZeroOutputsProduceFourZeroLedgers() throws {
        let fixture = try makeFixture(outputs: outputs(), predictions: [], pairs: [])
        let result = try account(fixture)

        XCTAssertEqual(result.matchedPairs, [])
        XCTAssertEqual(result.unmatchedPredictions, [])
        XCTAssertEqual(result.unmatchedGold, [])
        XCTAssertEqual(result.declaredDuplicates, [])
        XCTAssertEqual(result.ledgers.count, 4)
        for ledger in result.ledgers {
            XCTAssertEqual(ledger.goldTotal, 0)
            XCTAssertEqual(ledger.predictionTotal, 0)
            XCTAssertEqual(ledger.truePositive, 0)
            XCTAssertEqual(ledger.falsePositive, 0)
            XCTAssertEqual(ledger.falseNegative, 0)
            XCTAssertEqual(ledger.duplicatePredictionCount, 0)
            XCTAssertTrue(ledger.satisfiesAccountingInvariants)
        }
    }

    func testEachOutputKindAccountsPerfectMatchIndependently() throws {
        let gold = [
            goldReference(.decision, "gold-decision-1"),
            goldReference(.actionItem, "gold-action-1"),
            goldReference(.openQuestion, "gold-question-1"),
            goldReference(.nextAgenda, "gold-agenda-1"),
        ]
        let predictions = SemanticScoringOutputKind.allCases.enumerated().map {
            prediction($0.offset + 1, kind: $0.element)
        }
        let fixture = try makeFixture(
            outputs: outputs(
                decisions: ["gold-decision-1"],
                actions: ["gold-action-1"],
                questions: ["gold-question-1"],
                agenda: ["gold-agenda-1"]
            ),
            predictions: predictions,
            pairs: zip(predictions, gold).map {
                SemanticMatchingPair(prediction: $0.0, gold: $0.1)
            }
        )

        let result = try account(fixture)

        XCTAssertEqual(result.matchedPairs.count, 4)
        XCTAssertEqual(result.ledgers.map(\.kind), SemanticScoringOutputKind.allCases)
        for ledger in result.ledgers {
            assertLedger(ledger, gold: 1, predictions: 1, tp: 1, fp: 0, fn: 0, duplicates: 0)
        }
    }

    func testMissingPredictionIsFalseNegative() throws {
        let fixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [],
            pairs: []
        )

        let result = try account(fixture)
        let ledger = try XCTUnwrap(result.ledgers.first { $0.kind == .actionItem })

        assertLedger(ledger, gold: 1, predictions: 0, tp: 0, fp: 0, fn: 1, duplicates: 0)
        XCTAssertEqual(result.unmatchedGold, [goldReference(.actionItem, "gold-action-1")])
    }

    func testExtraPredictionIsFalsePositive() throws {
        let extra = prediction(1, kind: .actionItem)
        let fixture = try makeFixture(outputs: outputs(), predictions: [extra], pairs: [])

        let result = try account(fixture)
        let ledger = try XCTUnwrap(result.ledgers.first { $0.kind == .actionItem })

        assertLedger(ledger, gold: 0, predictions: 1, tp: 0, fp: 1, fn: 0, duplicates: 0)
        XCTAssertEqual(result.unmatchedPredictions, [extra])
    }

    func testExplicitDuplicateCountsAsFalsePositiveAndDuplicate() throws {
        let canonical = prediction(1, kind: .actionItem)
        let duplicate = prediction(2, kind: .actionItem)
        let gold = goldReference(.actionItem, "gold-action-1")
        let declaration = SemanticDuplicatePredictionDeclaration(
            duplicate: duplicate,
            canonical: canonical
        )
        let fixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, duplicate],
            pairs: [SemanticMatchingPair(prediction: canonical, gold: gold)],
            duplicatePredictions: [declaration]
        )

        let result = try account(fixture)
        let ledger = try XCTUnwrap(result.ledgers.first { $0.kind == .actionItem })

        assertLedger(ledger, gold: 1, predictions: 2, tp: 1, fp: 1, fn: 0, duplicates: 1)
        XCTAssertEqual(result.unmatchedPredictions, [duplicate])
        XCTAssertEqual(result.declaredDuplicates, [declaration])
        let mapBytes = try SemanticMatchingMap.encoder.encode(fixture.matchingMap)
        XCTAssertTrue(String(decoding: mapBytes, as: UTF8.self).contains("duplicate_predictions"))
        XCTAssertEqual(
            try SemanticMatchingMap.decoder.decode(SemanticMatchingMap.self, from: mapBytes),
            fixture.matchingMap
        )
    }

    func testUndeclaredSecondExactIdentityIsFalsePositiveButNotDuplicate() throws {
        let canonical = prediction(1, kind: .actionItem)
        let unpaired = prediction(2, kind: .actionItem)
        let fixture = try makeFixture(
            mapSchemaVersion: SemanticMatchingMap.schemaVersion,
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, unpaired],
            pairs: [
                SemanticMatchingPair(
                    prediction: canonical,
                    gold: goldReference(.actionItem, "gold-action-1")
                ),
            ]
        )

        let result = try account(fixture)
        let ledger = try XCTUnwrap(result.ledgers.first { $0.kind == .actionItem })

        assertLedger(ledger, gold: 1, predictions: 2, tp: 1, fp: 1, fn: 0, duplicates: 0)
    }

    func testMultipleDuplicatesMayReferenceOnePairedCanonical() throws {
        let canonical = prediction(1, kind: .decision)
        let duplicateA = prediction(2, kind: .decision)
        let duplicateB = prediction(3, kind: .decision)
        let fixture = try makeFixture(
            outputs: outputs(decisions: ["gold-decision-1"]),
            predictions: [duplicateB, canonical, duplicateA],
            pairs: [
                SemanticMatchingPair(
                    prediction: canonical,
                    gold: goldReference(.decision, "gold-decision-1")
                ),
            ],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateB, canonical: canonical),
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateA, canonical: canonical),
            ]
        )

        let result = try account(fixture)
        let ledger = try XCTUnwrap(result.ledgers.first { $0.kind == .decision })

        assertLedger(ledger, gold: 1, predictions: 3, tp: 1, fp: 2, fn: 0, duplicates: 2)
    }

    func testDanglingAndSelfDuplicateDeclarationsAreRefusedBeforePayloadOpen() throws {
        let canonical = prediction(1, kind: .actionItem)
        let dangling = prediction(99, kind: .actionItem)
        let base = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical],
            pairs: [
                SemanticMatchingPair(
                    prediction: canonical,
                    gold: goldReference(.actionItem, "gold-action-1")
                ),
            ],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: dangling, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.danglingDuplicatePredictionReference, fixture: base)

        let selfDuplicate = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical],
            pairs: [
                SemanticMatchingPair(
                    prediction: canonical,
                    gold: goldReference(.actionItem, "gold-action-1")
                ),
            ],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: canonical, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.selfDuplicateDeclaration, fixture: selfDuplicate)
    }

    func testCrossCaseAndCrossKindDuplicateDeclarationsAreRefusedBeforePayloadOpen() throws {
        let canonical = prediction(1, kind: .actionItem)
        let crossCase = SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: "SYN-ACCOUNT-D02",
            kind: .actionItem,
            proposalID: uuid(2)
        )
        let crossCaseFixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: crossCase, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.crossCaseDuplicateDeclaration, fixture: crossCaseFixture)

        let decision = prediction(2, kind: .decision)
        let crossKindFixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, decision],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: decision, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.crossKindDuplicateDeclaration, fixture: crossKindFixture)
    }

    func testCrossArtifactDuplicateDeclarationIsRefusedBeforePayloadOpen() throws {
        let canonical = prediction(1, kind: .actionItem)
        let otherFingerprint = PredictionArtifactFingerprint.rawArtifactBytes(Data("other".utf8))
        let otherArtifact = SemanticPredictionReference(
            artifactFingerprint: otherFingerprint.rawValue,
            caseID: Self.caseID,
            kind: .actionItem,
            proposalID: uuid(2)
        )
        let fixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: otherArtifact, canonical: canonical),
            ]
        )

        try assertAuthorizationRefused(.predictionArtifactHashMismatch, fixture: fixture)
    }

    func testPairedDuplicateAndUnpairedCanonicalAreRefusedBeforePayloadOpen() throws {
        let canonical = prediction(1, kind: .actionItem)
        let duplicate = prediction(2, kind: .actionItem)
        let pairedDuplicate = try makeFixture(
            outputs: outputs(actions: ["gold-action-1", "gold-action-2"]),
            predictions: [canonical, duplicate],
            pairs: [
                pair(canonical, .actionItem, "gold-action-1"),
                pair(duplicate, .actionItem, "gold-action-2"),
            ],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicate, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.duplicatePredictionIsPaired, fixture: pairedDuplicate)

        let unpairedCanonical = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, duplicate],
            pairs: [],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicate, canonical: canonical),
            ]
        )
        try assertAuthorizationRefused(.duplicateCanonicalNotPaired, fixture: unpairedCanonical)
    }

    func testDuplicateOfDuplicateAndCycleAreRefusedBeforePayloadOpen() throws {
        let canonical = prediction(1, kind: .actionItem)
        let duplicateA = prediction(2, kind: .actionItem)
        let duplicateB = prediction(3, kind: .actionItem)
        let chain = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, duplicateA, duplicateB],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateA, canonical: canonical),
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateB, canonical: duplicateA),
            ]
        )
        try assertAuthorizationRefused(.duplicateOfDuplicate, fixture: chain)

        let cycle = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, duplicateA, duplicateB],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateA, canonical: duplicateB),
                SemanticDuplicatePredictionDeclaration(duplicate: duplicateB, canonical: duplicateA),
            ]
        )
        try assertAuthorizationRefused(.duplicateOfDuplicate, fixture: cycle)
    }

    func testRepeatedAndConflictingDuplicateDeclarationsAreRefusedBeforePayloadOpen() throws {
        let canonicalA = prediction(1, kind: .actionItem)
        let canonicalB = prediction(2, kind: .actionItem)
        let duplicate = prediction(3, kind: .actionItem)
        let declaration = SemanticDuplicatePredictionDeclaration(
            duplicate: duplicate,
            canonical: canonicalA
        )
        let repeated = try makeFixture(
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonicalA, duplicate],
            pairs: [pair(canonicalA, .actionItem, "gold-action-1")],
            duplicatePredictions: [declaration, declaration]
        )
        try assertAuthorizationRefused(.duplicateDeclarationRepeated, fixture: repeated)

        let conflicting = try makeFixture(
            outputs: outputs(actions: ["gold-action-1", "gold-action-2"]),
            predictions: [canonicalA, canonicalB, duplicate],
            pairs: [
                pair(canonicalA, .actionItem, "gold-action-1"),
                pair(canonicalB, .actionItem, "gold-action-2"),
            ],
            duplicatePredictions: [
                declaration,
                SemanticDuplicatePredictionDeclaration(duplicate: duplicate, canonical: canonicalB),
            ]
        )
        try assertAuthorizationRefused(.duplicateDeclarationConflict, fixture: conflicting)
    }

    func testConflictingOneToOnePairsAreRefusedBeforePayloadOpen() throws {
        let prediction = prediction(1, kind: .actionItem)
        let fixture = try makeFixture(
            outputs: outputs(actions: ["gold-action-1", "gold-action-2"]),
            predictions: [prediction],
            pairs: [
                pair(prediction, .actionItem, "gold-action-1"),
                pair(prediction, .actionItem, "gold-action-2"),
            ]
        )

        try assertAuthorizationRefused(.duplicatePredictionUse, fixture: fixture)
    }

    func testV01RemainsPairOnlyAndOmitsDuplicateField() throws {
        let canonical = prediction(1, kind: .actionItem)
        let extra = prediction(2, kind: .actionItem)
        let fixture = try makeFixture(
            mapSchemaVersion: SemanticMatchingMap.schemaVersion,
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, extra],
            pairs: [pair(canonical, .actionItem, "gold-action-1")]
        )

        let mapData = try SemanticMatchingMap.encoder.encode(fixture.matchingMap)
        let mapJSON = try XCTUnwrap(String(data: mapData, encoding: .utf8))
        XCTAssertFalse(mapJSON.contains("duplicate_predictions"))
        XCTAssertEqual(
            try SemanticMatchingMap.decoder.decode(SemanticMatchingMap.self, from: mapData),
            fixture.matchingMap
        )

        let result = try account(fixture)
        XCTAssertEqual(result.declaredDuplicates, [])
        XCTAssertEqual(
            result.ledgers.first { $0.kind == .actionItem }?.duplicatePredictionCount,
            0
        )
    }

    func testV01CannotCarryDuplicateDeclarations() throws {
        let canonical = prediction(1, kind: .actionItem)
        let duplicate = prediction(2, kind: .actionItem)
        let fixture = try makeFixture(
            mapSchemaVersion: SemanticMatchingMap.schemaVersion,
            outputs: outputs(actions: ["gold-action-1"]),
            predictions: [canonical, duplicate],
            pairs: [pair(canonical, .actionItem, "gold-action-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicate, canonical: canonical),
            ]
        )

        try assertAuthorizationRefused(.duplicateDeclarationsUnsupported, fixture: fixture)
    }

    func testInputOrderDoesNotChangeResultOrSerializedBytes() throws {
        let canonical = prediction(1, kind: .actionItem)
        let duplicateA = prediction(2, kind: .actionItem)
        let duplicateB = prediction(3, kind: .actionItem)
        let decision = prediction(4, kind: .decision)
        let pairs = [
            pair(canonical, .actionItem, "gold-action-1"),
            pair(decision, .decision, "gold-decision-1"),
        ]
        let duplicates = [
            SemanticDuplicatePredictionDeclaration(duplicate: duplicateA, canonical: canonical),
            SemanticDuplicatePredictionDeclaration(duplicate: duplicateB, canonical: canonical),
        ]
        let first = try makeFixture(
            outputs: outputs(decisions: ["gold-decision-1"], actions: ["gold-action-1"]),
            predictions: [duplicateB, decision, canonical, duplicateA],
            pairs: Array(pairs.reversed()),
            duplicatePredictions: Array(duplicates.reversed())
        )
        let second = try makeFixture(
            outputs: outputs(decisions: ["gold-decision-1"], actions: ["gold-action-1"]),
            predictions: [canonical, duplicateA, duplicateB, decision],
            pairs: pairs,
            duplicatePredictions: duplicates
        )

        let firstResult = try account(first)
        let secondResult = try account(second)
        let firstBytes = try SemanticAccountingResult.encoder.encode(firstResult)

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstBytes, try SemanticAccountingResult.encoder.encode(secondResult))
        XCTAssertEqual(firstBytes, try SemanticAccountingResult.encoder.encode(firstResult))
        XCTAssertEqual(
            try JSONDecoder().decode(SemanticAccountingResult.self, from: firstBytes),
            firstResult
        )
    }

    func testAllLedgersSatisfyIntegerAccountingInvariants() throws {
        let paired = prediction(1, kind: .openQuestion)
        let duplicate = prediction(2, kind: .openQuestion)
        let extra = prediction(3, kind: .nextAgenda)
        let fixture = try makeFixture(
            outputs: outputs(
                decisions: ["gold-decision-1"],
                questions: ["gold-question-1"]
            ),
            predictions: [paired, duplicate, extra],
            pairs: [pair(paired, .openQuestion, "gold-question-1")],
            duplicatePredictions: [
                SemanticDuplicatePredictionDeclaration(duplicate: duplicate, canonical: paired),
            ]
        )

        let result = try account(fixture)

        XCTAssertTrue(result.ledgers.allSatisfy(\.satisfiesAccountingInvariants))
    }

    func testScorerEntryPointRequiresAuthorizedCaseAfterPayloadVerification() throws {
        let entryPoint: (AuthorizedSemanticScoringCase) -> SemanticAccountingResult =
            SemanticScoringAccountingCore.account
        let fixture = try makeFixture(outputs: outputs(), predictions: [], pairs: [])
        let recorder = AccountingRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)

        let entry = try store.authorize(fixture.request())
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path])
        let scoringCase = try store.loadScoringCase(for: entry)
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path, fixture.payloadURL.path])
        XCTAssertEqual(entryPoint(scoringCase).caseID, Self.caseID)
    }

    private func account(_ fixture: AccountingFixture) throws -> SemanticAccountingResult {
        let store = SemanticScorerInputStore(root: fixture.root)
        let entry = try store.authorize(fixture.request())
        return SemanticScoringAccountingCore.account(try store.loadScoringCase(for: entry))
    }

    private func assertAuthorizationRefused(
        _ expected: SemanticScorerRefusal,
        fixture: AccountingFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorder = AccountingRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)

        XCTAssertThrowsError(try store.authorize(fixture.request()), file: file, line: line) { error in
            XCTAssertEqual(error as? SemanticScorerRefusal, expected, file: file, line: line)
        }
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path], file: file, line: line)
        XCTAssertFalse(recorder.accessedPaths.contains(fixture.payloadURL.path), file: file, line: line)
    }

    private func assertLedger(
        _ ledger: SemanticOutputAccountingLedger,
        gold: Int,
        predictions: Int,
        tp: Int,
        fp: Int,
        fn: Int,
        duplicates: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(ledger.goldTotal, gold, file: file, line: line)
        XCTAssertEqual(ledger.predictionTotal, predictions, file: file, line: line)
        XCTAssertEqual(ledger.truePositive, tp, file: file, line: line)
        XCTAssertEqual(ledger.falsePositive, fp, file: file, line: line)
        XCTAssertEqual(ledger.falseNegative, fn, file: file, line: line)
        XCTAssertEqual(ledger.duplicatePredictionCount, duplicates, file: file, line: line)
        XCTAssertTrue(ledger.satisfiesAccountingInvariants, file: file, line: line)
    }

    private func makeFixture(
        mapSchemaVersion: String = SemanticMatchingMap.duplicateSchemaVersion,
        outputs: SemanticGoldOutputCollections,
        predictions: [SemanticPredictionReference],
        pairs: [SemanticMatchingPair],
        duplicatePredictions: [SemanticDuplicatePredictionDeclaration] = []
    ) throws -> AccountingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-SemanticAccounting-\(UUID().uuidString)", isDirectory: true)
        let payloadRoot = root.appendingPathComponent("semantic-scorer-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let input = SemanticScorerInput(
            status: .scorerReady,
            scorerReady: true,
            secondaryReviewComplete: true,
            benchmark: "meeting-execution-v0",
            caseID: Self.caseID,
            split: .development,
            predictionArtifactHash: Self.predictionHash,
            matchingPolicyVersion: SemanticMatchingMap.policyVersion,
            outputs: outputs,
            forbiddenInferences: [],
            ambiguityPolicy: SemanticAmbiguityPolicy(
                handling: .requireExplicitResolution,
                ambiguityIDs: []
            )
        )
        let payloadData = try SemanticScorerInput.encoder.encode(input)
        let goldInputHash = SemanticSHA256Digest.rawBytes(payloadData)
        let goldReferences = input.outputs.referencesByKind.map { kind, output in
            goldReference(kind, output.id.rawValue)
        }
        let matchingMap = SemanticMatchingMap(
            schemaVersion: mapSchemaVersion,
            caseID: Self.caseID,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: goldInputHash,
            pairs: pairs,
            duplicatePredictions: duplicatePredictions
        )
        let indexEntry = SemanticScorerSourceIndexEntry(
            indexSchemaVersion: SemanticScorerInputStore.indexSchemaVersion,
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            benchmark: "meeting-execution-v0",
            caseID: Self.caseID,
            split: .development,
            status: SemanticScorerInputStatus.scorerReady.rawValue,
            scorerReady: true,
            secondaryReviewComplete: true,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: goldInputHash,
            matchingPolicyVersion: SemanticMatchingMap.policyVersion,
            goldReferences: goldReferences
        )

        let indexURL = root.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName)
        let indexEncoder = JSONEncoder()
        indexEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var indexData = try indexEncoder.encode(indexEntry)
        indexData.append(0x0A)
        try indexData.write(to: indexURL)

        let payloadURL = payloadRoot.appendingPathComponent("\(Self.caseID).json")
        try payloadData.write(to: payloadURL)

        return AccountingFixture(
            root: root,
            indexURL: indexURL,
            payloadURL: payloadURL,
            predictions: predictions,
            matchingMap: matchingMap
        )
    }

    private func outputs(
        decisions: [String] = [],
        actions: [String] = [],
        questions: [String] = [],
        agenda: [String] = []
    ) -> SemanticGoldOutputCollections {
        SemanticGoldOutputCollections(
            decisions: decisions.map { output($0, kind: .decision) },
            actionItems: actions.map { output($0, kind: .actionItem) },
            openQuestions: questions.map { output($0, kind: .openQuestion) },
            nextAgenda: agenda.map { output($0, kind: .nextAgenda) }
        )
    }

    private func output(_ id: String, kind: SemanticScoringOutputKind) -> SemanticGoldOutput {
        SemanticGoldOutput(
            id: GoldOutputID(rawValue: id),
            evidenceUtteranceIDs: ["SYN.1"],
            inferenceClass: .explicit,
            targetSpeakerResponsibility: .targetSpeakerResponsible,
            assignee: kind == .actionItem
                ? SemanticAssigneeExpectation(
                    scope: .individual,
                    basis: .speakerCommitment,
                    valueReference: "speaker:B",
                    evidenceUtteranceIDs: ["SYN.1"]
                )
                : nil,
            due: kind == .actionItem
                ? SemanticDueExpectation(
                    status: .explicit,
                    value: "2026-09-30",
                    evidenceUtteranceIDs: ["SYN.1"]
                )
                : nil
        )
    }

    private func prediction(
        _ id: Int,
        kind: SemanticScoringOutputKind
    ) -> SemanticPredictionReference {
        SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: Self.caseID,
            kind: kind,
            proposalID: uuid(id)
        )
    }

    private func goldReference(
        _ kind: SemanticScoringOutputKind,
        _ id: String
    ) -> SemanticGoldReference {
        SemanticGoldReference(
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            caseID: Self.caseID,
            kind: kind,
            outputID: GoldOutputID(rawValue: id)
        )
    }

    private func pair(
        _ prediction: SemanticPredictionReference,
        _ kind: SemanticScoringOutputKind,
        _ goldID: String
    ) -> SemanticMatchingPair {
        SemanticMatchingPair(prediction: prediction, gold: goldReference(kind, goldID))
    }

    private func uuid(_ id: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
    }
}

private struct AccountingFixture {
    let root: URL
    let indexURL: URL
    let payloadURL: URL
    let predictions: [SemanticPredictionReference]
    let matchingMap: SemanticMatchingMap

    func request() -> SemanticScorerAuthorizationRequest {
        SemanticScorerAuthorizationRequest(
            runtimeAuthorization: .development(),
            requestedSplit: .development,
            benchmark: "meeting-execution-v0",
            caseID: "SYN-ACCOUNT-D01",
            predictionArtifactFingerprint: PredictionArtifactFingerprint.rawArtifactBytes(
                Data("synthetic-accounting-prediction-artifact".utf8)
            ),
            availablePredictions: predictions,
            matchingMap: matchingMap
        )
    }
}

private final class AccountingRecordingFileManager: FileManager {
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
