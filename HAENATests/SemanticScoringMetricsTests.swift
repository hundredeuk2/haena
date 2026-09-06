import Foundation
import XCTest
@testable import HAENA

final class SemanticScoringMetricsTests: XCTestCase {
    private static let caseID = "SYN-METRIC-D01"
    private static let fingerprint = PredictionArtifactFingerprint.rawArtifactBytes(
        Data("synthetic-metric-prediction-artifact".utf8)
    )
    private static var predictionHash: String { fingerprint.rawValue }

    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testOutputKindFractionsComeFromAccountingLedgersAndPreserveZeroDenominators() throws {
        let decision = prediction(1, .decision)
        let extraAction = prediction(2, .actionItem)
        let fixture = try makeFixture(
            gold: [
                gold("gold-decision", .decision),
                gold("gold-action", .actionItem),
            ],
            predictions: [extraAction, decision],
            pairs: [pair(decision, .decision, "gold-decision")]
        )

        let result = try measure(fixture)
        let decisionMetric = try XCTUnwrap(result.outputKinds.first { $0.kind == .decision })
        XCTAssertEqual(decisionMetric.classification.precision, fraction(1, 1))
        XCTAssertEqual(decisionMetric.classification.recall, fraction(1, 1))
        XCTAssertEqual(decisionMetric.classification.f1, fraction(2, 2))
        XCTAssertEqual(decisionMetric.ledger.truePositive, 1)

        let action = try XCTUnwrap(result.outputKinds.first { $0.kind == .actionItem })
        XCTAssertEqual(action.classification.precision, fraction(0, 1))
        XCTAssertEqual(action.classification.recall, fraction(0, 1))
        XCTAssertEqual(action.classification.f1, fraction(0, 2))
        XCTAssertEqual(action.ledger.falsePositive, 1)
        XCTAssertEqual(action.ledger.falseNegative, 1)

        let question = try XCTUnwrap(result.outputKinds.first { $0.kind == .openQuestion })
        XCTAssertEqual(question.classification.precision.numerator, 0)
        XCTAssertEqual(question.classification.precision.denominator, 0)
        XCTAssertEqual(question.classification.precision.availability, .noPositivePredictions)
        XCTAssertNil(question.classification.precision.value)
        XCTAssertEqual(question.classification.recall.availability, .noPositiveGold)
        XCTAssertEqual(question.classification.f1.availability, .noPositiveGoldOrPredictions)
    }

    func testEvidencePerfectPartialExtraMissingAbsentAndUnresolvedStayDistinct() throws {
        let predictions = (1...5).map { prediction($0, .decision) }
        let fixture = try makeFixture(
            gold: [
                gold("g1", .decision, evidence: ["U1", "U2"]),
                gold("g2", .decision, evidence: ["U3"]),
                gold("g3", .decision, evidence: ["U5", "U6"]),
                gold("g4", .decision, evidence: ["U7"]),
                gold("g5", .decision, evidence: ["U8"]),
            ],
            predictions: predictions,
            pairs: zip(predictions, 1...5).map { pair($0.0, .decision, "g\($0.1)") },
            observations: [
                observation(predictions[0], evidence: .init(state: .known, utteranceIDs: ["U2", "U1"])),
                observation(predictions[1], evidence: .init(state: .known, utteranceIDs: ["U3", "U4"])),
                observation(predictions[2], evidence: .init(state: .known, utteranceIDs: ["U5"])),
                observation(predictions[3], evidence: .init(state: .absent)),
                observation(predictions[4], evidence: .init(state: .unresolved, utteranceIDs: ["U8"])),
            ]
        )

        let evidence = try measure(fixture).evidence
        XCTAssertEqual(evidence.citation.truePositive, 4)
        XCTAssertEqual(evidence.citation.falsePositive, 1)
        XCTAssertEqual(evidence.citation.falseNegative, 2)
        XCTAssertEqual(evidence.citation.precision, fraction(4, 5))
        XCTAssertEqual(evidence.citation.recall, fraction(4, 6))
        XCTAssertEqual(evidence.citation.f1, fraction(8, 11))
        XCTAssertEqual(evidence.exactEvidenceSetAccuracy, fraction(1, 4))
        XCTAssertEqual(evidence.diagnostics.eligibleSampleCount, 4)
        XCTAssertEqual(evidence.diagnostics.ineligibleSampleCount, 1)
        XCTAssertEqual(evidence.diagnostics.unresolvedSampleCount, 1)
        XCTAssertEqual(
            evidence.diagnostics.ineligibleSamples,
            [.init(reason: .evidenceUnresolved, sampleCount: 1)]
        )
    }

    func testTargetSpeakerBAccountsTPFPFNAndPreservesNegativeStatesAndUnresolved() throws {
        let predictions = (1...6).map { prediction($0, .actionItem) }
        let fixture = try makeFixture(
            gold: [
                gold("g1", .actionItem, target: .targetSpeakerResponsible),
                gold("g2", .actionItem, target: .otherSpeaker),
                gold("g3", .actionItem, target: .targetSpeakerResponsible),
                gold("g4", .actionItem, target: .noResponsibilityAssigned),
                gold("g5", .actionItem, target: .targetSpeakerResponsible),
                gold("g6", .actionItem, target: .targetSpeakerResponsible),
            ],
            predictions: predictions,
            pairs: (0..<5).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(predictions[0], target: .targetSpeakerResponsible),
                observation(predictions[1], target: .targetSpeakerResponsible),
                observation(predictions[2], target: .otherSpeaker),
                observation(predictions[3], target: .noResponsibilityAssigned),
                observation(predictions[4], target: .unresolved),
                observation(predictions[5], target: .targetSpeakerResponsible),
            ]
        )

        let metric = try measure(fixture).targetSpeakerB
        XCTAssertEqual(metric.responsibility.truePositive, 1)
        XCTAssertEqual(metric.responsibility.falsePositive, 2)
        XCTAssertEqual(metric.responsibility.falseNegative, 2)
        XCTAssertEqual(metric.responsibility.precision, fraction(1, 3))
        XCTAssertEqual(metric.responsibility.recall, fraction(1, 3))
        XCTAssertEqual(metric.responsibility.f1, fraction(2, 6))
        XCTAssertEqual(metric.exactResponsibilityStateAccuracy, fraction(2, 4))
        XCTAssertEqual(metric.otherSpeakerPredictionCount, 1)
        XCTAssertEqual(metric.noResponsibilityAssignedPredictionCount, 1)
        XCTAssertEqual(metric.diagnostics.unresolvedSampleCount, 1)
    }

    func testTargetSpeakerBEmptyDenominatorsAreUnavailable() throws {
        let fixture = try makeFixture(gold: [], predictions: [], pairs: [])
        let metric = try measure(fixture).targetSpeakerB

        XCTAssertEqual(metric.responsibility.precision.availability, .noPositivePredictions)
        XCTAssertEqual(metric.responsibility.recall.availability, .noPositiveGold)
        XCTAssertEqual(metric.responsibility.f1.availability, .noPositiveGoldOrPredictions)
        XCTAssertEqual(metric.exactResponsibilityStateAccuracy.availability, .noEligibleSamples)
    }

    func testAssigneeMetricsDistinguishScopeAbsenceUnresolvedAndIncomparable() throws {
        let predictions = (1...5).map { prediction($0, .actionItem) }
        let fixture = try makeFixture(
            gold: [
                gold("g1", .actionItem, assignee: assignee(.individual, .speakerCommitment, "speaker:B")),
                gold("g2", .actionItem, assignee: assignee(.organization, .supportedByUtterance, "org:ops")),
                gold("g3", .actionItem, assignee: assignee(.unspecified, .absentMustStayEmpty, nil)),
                gold("g4", .actionItem, assignee: assignee(.individual, .speakerCommitment, "speaker:B")),
                gold("g5", .actionItem, assignee: assignee(.individual, .speakerCommitment, "speaker:B")),
            ],
            predictions: predictions,
            pairs: (0..<5).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(predictions[0]),
                observation(
                    predictions[1],
                    assignee: predictionAssignee(.known, .individual, .supportedByUtterance, "org:ops")
                ),
                observation(predictions[2], assignee: .init(state: .absent)),
                observation(predictions[3], assignee: .init(state: .unresolved)),
                observation(predictions[4], assignee: .init(state: .incomparable)),
            ]
        )

        let metric = try XCTUnwrap(
            measure(fixture).actionItemPolicyMetrics.first { $0.inferenceClass == .explicit }
        ).assignee
        XCTAssertEqual(metric.scopeAccuracy, fraction(2, 3))
        XCTAssertEqual(metric.basisAccuracy, fraction(3, 3))
        XCTAssertEqual(metric.valueReferenceAccuracy, fraction(3, 3))
        XCTAssertEqual(metric.exactAccuracy, fraction(2, 3))
        XCTAssertEqual(metric.absentMustStayEmptyCompliance, fraction(1, 1))
        XCTAssertEqual(metric.diagnostics.eligibleSampleCount, 3)
        XCTAssertEqual(metric.diagnostics.ineligibleSampleCount, 2)
        XCTAssertEqual(metric.diagnostics.unresolvedSampleCount, 1)
        XCTAssertEqual(metric.diagnostics.incomparableSampleCount, 1)
    }

    func testDueMetricsPreserveExplicitRelativeAbsentUnresolvedAndIncomparable() throws {
        let predictions = (1...6).map { prediction($0, .actionItem) }
        let fixture = try makeFixture(
            gold: [
                gold("g1", .actionItem, due: due(.explicit, "2026-09-30")),
                gold("g2", .actionItem, due: due(.explicitRelative, "P2D")),
                gold("g3", .actionItem, due: due(.absent, nil)),
                gold("g4", .actionItem, due: due(.explicit, "2026-10-01")),
                gold("g5", .actionItem, due: due(.explicit, "2026-10-02")),
                gold("g6", .actionItem, due: due(.unresolved, "opaque:pending")),
            ],
            predictions: predictions,
            pairs: (0..<6).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(predictions[0]),
                observation(predictions[1], due: predictionDue(.explicitRelative, "P2D")),
                observation(predictions[2], due: .init(status: .absent)),
                observation(predictions[3], due: .init(status: .unresolved, value: "2026-10-01")),
                observation(predictions[4], due: .init(status: .incomparable, value: "2026-10-02")),
                observation(predictions[5]),
            ]
        )

        let metric = try XCTUnwrap(
            measure(fixture).actionItemPolicyMetrics.first { $0.inferenceClass == .explicit }
        ).due
        XCTAssertEqual(metric.statusAccuracy, fraction(3, 3))
        XCTAssertEqual(metric.comparableValueAccuracy, fraction(2, 2))
        XCTAssertEqual(metric.exactAccuracy, fraction(3, 3))
        XCTAssertEqual(metric.absentCompliance, fraction(1, 1))
        XCTAssertEqual(metric.diagnostics.eligibleSampleCount, 3)
        XCTAssertEqual(metric.diagnostics.ineligibleSampleCount, 3)
        XCTAssertEqual(metric.diagnostics.unresolvedSampleCount, 2)
        XCTAssertEqual(metric.diagnostics.incomparableSampleCount, 1)
        XCTAssertEqual(Set(metric.diagnostics.ineligibleSamples.map(\.reason)), Set([
            .predictionDueUnresolved,
            .predictionDueIncomparable,
            .goldDueUnresolved,
        ]))
    }

    func testActionItemMetricsAreSeparatedByGoldInferenceClass() throws {
        let predictions = (1...3).map { prediction($0, .actionItem) }
        let fixture = try makeFixture(
            gold: [
                gold("g1", .actionItem, inference: .explicit),
                gold("g2", .actionItem, inference: .derivedProposal, due: due(.explicitRelative, "P2D")),
                gold(
                    "g3",
                    .actionItem,
                    inference: .forbiddenInference,
                    assignee: assignee(.unspecified, .absentMustStayEmpty, nil),
                    due: due(.absent, nil)
                ),
            ],
            predictions: predictions,
            pairs: (0..<3).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(predictions[0]),
                observation(predictions[1], due: predictionDue(.explicitRelative, "P3D")),
                observation(
                    predictions[2],
                    assignee: .init(state: .absent),
                    due: .init(status: .absent)
                ),
            ]
        )

        let metrics = try measure(fixture).actionItemPolicyMetrics
        XCTAssertEqual(metrics.map(\.inferenceClass), [.explicit, .derivedProposal, .forbiddenInference])
        XCTAssertEqual(metrics.map(\.matchedActionItemCount), [1, 1, 1])
        XCTAssertEqual(metrics[1].due.statusAccuracy, fraction(1, 1))
        XCTAssertEqual(metrics[1].due.comparableValueAccuracy, fraction(0, 1))
        XCTAssertEqual(metrics[2].assignee.absentMustStayEmptyCompliance, fraction(1, 1))
        XCTAssertEqual(metrics[2].due.absentCompliance, fraction(1, 1))
    }

    func testExactForbiddenDeclarationIsAnFPAndSeparateViolation() throws {
        let violation = prediction(1, .actionItem)
        let declaration = SemanticForbiddenPredictionDeclaration(
            prediction: violation,
            forbiddenInferenceID: "forbidden-1",
            outputKind: .actionItem
        )
        let fixture = try makeFixture(
            gold: [],
            forbidden: [forbidden("forbidden-1", .actionItem)],
            predictions: [violation],
            pairs: [],
            forbiddenPredictions: [declaration],
            observations: [observation(violation)]
        )

        let result = try measure(fixture)
        XCTAssertEqual(result.forbiddenInference.violationPredictionCount, 1)
        XCTAssertEqual(result.forbiddenInference.declaredViolations, [declaration])
        XCTAssertEqual(
            result.outputKinds.first { $0.kind == .actionItem }?.ledger.falsePositive,
            1
        )
    }

    func testForbiddenPreOpenDanglingCrossCaseCrossKindPairedDuplicateAndConflictRefusals() throws {
        let canonical = prediction(1, .actionItem)
        let violation = prediction(2, .actionItem)
        let dangling = prediction(99, .actionItem)
        try assertPreOpenRefusal(
            .danglingForbiddenPredictionReference,
            fixture: makeFixture(
                gold: [],
                forbidden: [forbidden("f1", .actionItem)],
                predictions: [canonical],
                pairs: [],
                forbiddenPredictions: [.init(prediction: dangling, forbiddenInferenceID: "f1", outputKind: .actionItem)]
            )
        )

        let crossCase = SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: "SYN-METRIC-D02",
            kind: .actionItem,
            proposalID: uuid(2)
        )
        try assertPreOpenRefusal(
            .crossCaseForbiddenDeclaration,
            fixture: makeFixture(
                gold: [], forbidden: [forbidden("f1", .actionItem)], predictions: [canonical], pairs: [],
                forbiddenPredictions: [.init(prediction: crossCase, forbiddenInferenceID: "f1", outputKind: .actionItem)]
            )
        )
        try assertPreOpenRefusal(
            .crossKindForbiddenDeclaration,
            fixture: makeFixture(
                gold: [], forbidden: [forbidden("f1", .decision)], predictions: [canonical], pairs: [],
                forbiddenPredictions: [.init(prediction: canonical, forbiddenInferenceID: "f1", outputKind: .decision)]
            )
        )
        try assertPreOpenRefusal(
            .forbiddenPredictionIsPaired,
            fixture: makeFixture(
                gold: [gold("g1", .actionItem)], forbidden: [forbidden("f1", .actionItem)],
                predictions: [canonical], pairs: [pair(canonical, .actionItem, "g1")],
                forbiddenPredictions: [.init(prediction: canonical, forbiddenInferenceID: "f1", outputKind: .actionItem)]
            )
        )
        try assertPreOpenRefusal(
            .forbiddenPredictionIsDuplicate,
            fixture: makeFixture(
                gold: [gold("g1", .actionItem)], forbidden: [forbidden("f1", .actionItem)],
                predictions: [canonical, violation], pairs: [pair(canonical, .actionItem, "g1")],
                duplicatePredictions: [.init(duplicate: violation, canonical: canonical)],
                forbiddenPredictions: [.init(prediction: violation, forbiddenInferenceID: "f1", outputKind: .actionItem)]
            )
        )
        try assertPreOpenRefusal(
            .forbiddenDeclarationConflict,
            fixture: makeFixture(
                gold: [], forbidden: [forbidden("f1", .actionItem), forbidden("f2", .actionItem)],
                predictions: [violation], pairs: [],
                forbiddenPredictions: [
                    .init(prediction: violation, forbiddenInferenceID: "f1", outputKind: .actionItem),
                    .init(prediction: violation, forbiddenInferenceID: "f2", outputKind: .actionItem),
                ]
            )
        )
    }

    func testForbiddenIDAndKindAreResolvedOnlyAfterAuthorizedPayloadLoad() throws {
        let violation = prediction(1, .actionItem)
        let dangling = try makeFixture(
            gold: [],
            forbidden: [forbidden("f1", .actionItem)],
            predictions: [violation],
            pairs: [],
            forbiddenPredictions: [.init(prediction: violation, forbiddenInferenceID: "missing", outputKind: .actionItem)]
        )
        try assertPostOpenRefusal(.danglingForbiddenInferenceReference, fixture: dangling)

        let wrongKind = try makeFixture(
            gold: [],
            forbidden: [forbidden("f1", .decision)],
            predictions: [violation],
            pairs: [],
            forbiddenPredictions: [.init(prediction: violation, forbiddenInferenceID: "f1", outputKind: .actionItem)]
        )
        try assertPostOpenRefusal(.forbiddenInferenceKindMismatch, fixture: wrongKind)
    }

    func testV01AndV02MatchingMapSerializationRemainUnchanged() throws {
        for version in [SemanticMatchingMap.schemaVersion, SemanticMatchingMap.duplicateSchemaVersion] {
            let map = SemanticMatchingMap(
                schemaVersion: version,
                caseID: Self.caseID,
                predictionArtifactHash: Self.predictionHash,
                goldInputHash: SemanticSHA256Digest.rawBytes(Data("gold".utf8)),
                pairs: []
            )
            let bytes = try SemanticMatchingMap.encoder.encode(map)
            let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertFalse(json.contains("forbidden_predictions"))
            XCTAssertEqual(try SemanticMatchingMap.decoder.decode(SemanticMatchingMap.self, from: bytes), map)
            if version == SemanticMatchingMap.schemaVersion {
                XCTAssertFalse(json.contains("duplicate_predictions"))
            } else {
                XCTAssertTrue(json.contains("duplicate_predictions"))
            }
        }

        let violation = prediction(1, .actionItem)
        let v02WithForbidden = try makeFixture(
            mapSchemaVersion: SemanticMatchingMap.duplicateSchemaVersion,
            gold: [],
            forbidden: [forbidden("f1", .actionItem)],
            predictions: [violation],
            pairs: [],
            forbiddenPredictions: [
                .init(prediction: violation, forbiddenInferenceID: "f1", outputKind: .actionItem),
            ]
        )
        try assertPreOpenRefusal(.forbiddenDeclarationsUnsupported, fixture: v02WithForbidden)
    }

    func testObservationInventoryRejectsUnknownMissingDuplicateAndAdditionalBeforePayloadOpen() throws {
        let first = prediction(1, .decision)
        let second = prediction(2, .decision)
        let fixture = try makeFixture(gold: [], predictions: [first, second], pairs: [])
        let observations = [observation(first), observation(second)]

        try assertPreOpenRefusal(
            .unknownPredictionObservationVersion,
            fixture: fixture,
            observations: .init(schemaVersion: "unknown", observations: observations)
        )
        try assertPreOpenRefusal(
            .missingPredictionObservation,
            fixture: fixture,
            observations: .init(observations: [observations[0]])
        )
        try assertPreOpenRefusal(
            .duplicatePredictionObservation,
            fixture: fixture,
            observations: .init(observations: [observations[0], observations[0]])
        )
        try assertPreOpenRefusal(
            .additionalPredictionObservation,
            fixture: fixture,
            observations: .init(observations: observations + [observation(prediction(3, .decision))])
        )
    }

    func testObservationShapeRefusalAndMissingRuntimeAuthorizationOpenNoPayload() throws {
        let item = prediction(1, .actionItem)
        let fixture = try makeFixture(gold: [], predictions: [item], pairs: [])
        try assertPreOpenRefusal(
            .malformedPredictionObservation,
            fixture: fixture,
            observations: .init(observations: [
                observation(item, assignee: .init(state: .absent, valueReference: "must-not-exist")),
            ])
        )

        let recorder = MetricRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)
        let request = fixture.metricRequest(runtimeAuthorization: nil)
        XCTAssertThrowsError(try store.authorizeMetrics(request)) { error in
            XCTAssertEqual(error as? SemanticScorerRefusal, .authorizationMissing)
        }
        XCTAssertEqual(recorder.accessedPaths, [])
        XCTAssertFalse(recorder.accessedPaths.contains(fixture.payloadURL.path))
    }

    func testInputOrderAndRepeatedEncodingAreDeterministic() throws {
        let first = prediction(1, .decision)
        let second = prediction(2, .actionItem)
        let goldRecords = [gold("g1", .decision), gold("g2", .actionItem)]
        let pairs = [pair(first, .decision, "g1"), pair(second, .actionItem, "g2")]
        let observations = [observation(first), observation(second)]
        let fixtureA = try makeFixture(
            gold: goldRecords,
            predictions: [second, first],
            pairs: Array(pairs.reversed()),
            observations: Array(observations.reversed())
        )
        let fixtureB = try makeFixture(
            gold: Array(goldRecords.reversed()),
            predictions: [first, second],
            pairs: pairs,
            observations: observations
        )

        let resultA = try measure(fixtureA)
        let resultB = try measure(fixtureB)
        let bytesA = try SemanticMetricResult.encoder.encode(resultA)
        XCTAssertEqual(resultA, resultB)
        XCTAssertEqual(bytesA, try SemanticMetricResult.encoder.encode(resultB))
        XCTAssertEqual(bytesA, try SemanticMetricResult.encoder.encode(resultA))
        let reversedObservationSet = SemanticPredictionMetricObservationSet(
            observations: Array(observations.reversed())
        )
        let orderedObservationSet = SemanticPredictionMetricObservationSet(
            observations: observations
        )
        let observationBytes = try SemanticPredictionMetricObservationSet.encoder.encode(
            reversedObservationSet
        )
        XCTAssertEqual(
            observationBytes,
            try SemanticPredictionMetricObservationSet.encoder.encode(orderedObservationSet)
        )
    }

    func testPriorStateBoundaryIsFiniteAndNeverRepresentedAsScoreZero() throws {
        let result = try measure(makeFixture(gold: [], predictions: [], pairs: []))
        XCTAssertEqual(
            result.scopeExclusions,
            [.init(scope: .priorStateTransition, reason: .scorerIneligiblePriorState)]
        )
        XCTAssertFalse(try String(decoding: SemanticMetricResult.encoder.encode(result), as: UTF8.self)
            .contains("prior_state_score"))
    }

    func testMetricEntryPointRequiresFullyAuthorizedMetricCapability() throws {
        let entryPoint: (AuthorizedSemanticMetricScoringCase) -> SemanticMetricResult =
            SemanticScoringMetricCore.measure
        let fixture = try makeFixture(gold: [], predictions: [], pairs: [])
        let recorder = MetricRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)

        let entry = try store.authorizeMetrics(fixture.metricRequest())
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path])
        let metricCase = try store.loadMetricScoringCase(for: entry)
        XCTAssertEqual(recorder.accessedPaths, [fixture.indexURL.path, fixture.payloadURL.path])
        XCTAssertEqual(entryPoint(metricCase).caseID, Self.caseID)
    }

    private func measure(_ fixture: MetricFixture) throws -> SemanticMetricResult {
        let store = SemanticScorerInputStore(root: fixture.root)
        let entry = try store.authorizeMetrics(fixture.metricRequest())
        return SemanticScoringMetricCore.measure(try store.loadMetricScoringCase(for: entry))
    }

    private func assertPreOpenRefusal(
        _ expected: SemanticScorerRefusal,
        fixture: MetricFixture,
        observations: SemanticPredictionMetricObservationSet? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorder = MetricRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)
        XCTAssertThrowsError(
            try store.authorizeMetrics(fixture.metricRequest(observations: observations)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? SemanticScorerRefusal, expected, file: file, line: line)
        }
        XCTAssertFalse(recorder.accessedPaths.contains(fixture.payloadURL.path), file: file, line: line)
    }

    private func assertPostOpenRefusal(
        _ expected: SemanticScorerRefusal,
        fixture: MetricFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorder = MetricRecordingFileManager()
        let store = SemanticScorerInputStore(root: fixture.root, fileManager: recorder)
        let entry = try store.authorizeMetrics(fixture.metricRequest())
        XCTAssertThrowsError(try store.loadMetricScoringCase(for: entry), file: file, line: line) { error in
            XCTAssertEqual(error as? SemanticScorerRefusal, expected, file: file, line: line)
        }
        XCTAssertEqual(recorder.accessedPaths.last, fixture.payloadURL.path, file: file, line: line)
    }

    private func makeFixture(
        mapSchemaVersion: String = SemanticMatchingMap.forbiddenInferenceSchemaVersion,
        gold: [MetricGoldRecord],
        forbidden: [SemanticForbiddenInference] = [],
        predictions: [SemanticPredictionReference],
        pairs: [SemanticMatchingPair],
        duplicatePredictions: [SemanticDuplicatePredictionDeclaration] = [],
        forbiddenPredictions: [SemanticForbiddenPredictionDeclaration] = [],
        observations: [SemanticPredictionMetricObservation]? = nil
    ) throws -> MetricFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-SemanticMetrics-\(UUID().uuidString)", isDirectory: true)
        let payloadRoot = root.appendingPathComponent("semantic-scorer-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let outputs = SemanticGoldOutputCollections(
            decisions: gold.filter { $0.kind == .decision }.map(\.output),
            actionItems: gold.filter { $0.kind == .actionItem }.map(\.output),
            openQuestions: gold.filter { $0.kind == .openQuestion }.map(\.output),
            nextAgenda: gold.filter { $0.kind == .nextAgenda }.map(\.output)
        )
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
            forbiddenInferences: forbidden,
            ambiguityPolicy: SemanticAmbiguityPolicy(
                handling: .requireExplicitResolution,
                ambiguityIDs: []
            )
        )
        let payloadData = try exactPayloadData(input)
        let payloadHash = SemanticSHA256Digest.rawBytes(payloadData)
        let map = SemanticMatchingMap(
            schemaVersion: mapSchemaVersion,
            caseID: Self.caseID,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: payloadHash,
            pairs: pairs,
            duplicatePredictions: duplicatePredictions,
            forbiddenPredictions: forbiddenPredictions
        )
        let references = input.outputs.referencesByKind.map { kind, output in
            goldReference(kind, output.id.rawValue)
        }
        let index = SemanticScorerSourceIndexEntry(
            indexSchemaVersion: SemanticScorerInputStore.indexSchemaVersion,
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            benchmark: "meeting-execution-v0",
            caseID: Self.caseID,
            split: .development,
            status: SemanticScorerInputStatus.scorerReady.rawValue,
            scorerReady: true,
            secondaryReviewComplete: true,
            predictionArtifactHash: Self.predictionHash,
            goldInputHash: payloadHash,
            matchingPolicyVersion: SemanticMatchingMap.policyVersion,
            goldReferences: references
        )
        let indexEncoder = JSONEncoder()
        indexEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var indexData = try indexEncoder.encode(index)
        indexData.append(0x0A)
        let indexURL = root.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName)
        try indexData.write(to: indexURL)
        let payloadURL = payloadRoot.appendingPathComponent("\(Self.caseID).json")
        try payloadData.write(to: payloadURL)

        let resolvedObservations = observations ?? predictions.map { observation($0) }
        return MetricFixture(
            root: root,
            indexURL: indexURL,
            payloadURL: payloadURL,
            predictions: predictions,
            matchingMap: map,
            observations: SemanticPredictionMetricObservationSet(observations: resolvedObservations)
        )
    }

    private func gold(
        _ id: String,
        _ kind: SemanticScoringOutputKind,
        evidence: [String] = ["SYN.1"],
        inference: SemanticInferenceClass = .explicit,
        target: SemanticTargetSpeakerResponsibility = .targetSpeakerResponsible,
        assignee: SemanticAssigneeExpectation? = nil,
        due: SemanticDueExpectation? = nil
    ) -> MetricGoldRecord {
        MetricGoldRecord(
            kind: kind,
            output: SemanticGoldOutput(
                id: GoldOutputID(rawValue: id),
                evidenceUtteranceIDs: evidence,
                inferenceClass: inference,
                targetSpeakerResponsibility: target,
                assignee: kind == .actionItem
                    ? assignee ?? self.assignee(.individual, .speakerCommitment, "speaker:B")
                    : nil,
                due: kind == .actionItem ? due ?? self.due(.explicit, "2026-09-30") : nil
            )
        )
    }

    /// The v0.1 exact-shape contract requires nullable value keys to be present. Swift's
    /// synthesized optional encoding omits nil, so synthetic fixtures materialize the existing
    /// wire-level null without changing the scorer-input model or schema.
    private func exactPayloadData(_ input: SemanticScorerInput) throws -> Data {
        let encoded = try SemanticScorerInput.encoder.encode(input)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var outputs = try XCTUnwrap(root["outputs"] as? [String: Any])
        var actions = try XCTUnwrap(outputs["action_items"] as? [[String: Any]])
        for index in actions.indices {
            if var assignee = actions[index]["assignee"] as? [String: Any] {
                if assignee["value_reference"] == nil {
                    assignee["value_reference"] = NSNull()
                }
                actions[index]["assignee"] = assignee
            }
            if var due = actions[index]["due"] as? [String: Any] {
                if due["value"] == nil {
                    due["value"] = NSNull()
                }
                actions[index]["due"] = due
            }
        }
        outputs["action_items"] = actions
        root["outputs"] = outputs
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func assignee(
        _ scope: SemanticAssigneeScope,
        _ basis: SemanticAssigneeBasis,
        _ value: String?
    ) -> SemanticAssigneeExpectation {
        SemanticAssigneeExpectation(
            scope: scope,
            basis: basis,
            valueReference: value,
            evidenceUtteranceIDs: basis == .absentMustStayEmpty ? [] : ["SYN.1"]
        )
    }

    private func due(_ status: SemanticDueStatus, _ value: String?) -> SemanticDueExpectation {
        SemanticDueExpectation(
            status: status,
            value: value,
            evidenceUtteranceIDs: status == .absent ? [] : ["SYN.1"]
        )
    }

    private func forbidden(
        _ id: String,
        _ kind: SemanticScoringOutputKind
    ) -> SemanticForbiddenInference {
        SemanticForbiddenInference(
            id: id,
            outputKind: kind,
            basis: .reviewMethod,
            evidenceUtteranceIDs: []
        )
    }

    private func observation(
        _ reference: SemanticPredictionReference,
        evidence: SemanticPredictionEvidenceObservation = .init(state: .known, utteranceIDs: ["SYN.1"]),
        target: SemanticPredictionTargetResponsibility? = nil,
        assignee: SemanticPredictionAssigneeObservation? = nil,
        due: SemanticPredictionDueObservation? = nil
    ) -> SemanticPredictionMetricObservation {
        let isAction = reference.kind == .actionItem
        return SemanticPredictionMetricObservation(
            predictionReference: reference,
            evidence: evidence,
            targetResponsibility: target ?? (isAction ? .targetSpeakerResponsible : .noResponsibilityAssigned),
            assignee: assignee ?? (isAction
                ? predictionAssignee(.known, .individual, .speakerCommitment, "speaker:B")
                : .init(state: .absent)),
            due: due ?? (isAction ? predictionDue(.explicit, "2026-09-30") : .init(status: .absent))
        )
    }

    private func predictionAssignee(
        _ state: SemanticPredictionAssigneeState,
        _ scope: SemanticAssigneeScope,
        _ basis: SemanticAssigneeBasis,
        _ value: String
    ) -> SemanticPredictionAssigneeObservation {
        SemanticPredictionAssigneeObservation(
            state: state,
            scope: scope,
            basis: basis,
            valueReference: value,
            evidenceUtteranceIDs: ["SYN.1"]
        )
    }

    private func predictionDue(
        _ status: SemanticPredictionDueStatus,
        _ value: String
    ) -> SemanticPredictionDueObservation {
        SemanticPredictionDueObservation(
            status: status,
            value: value,
            evidenceUtteranceIDs: ["SYN.1"]
        )
    }

    private func prediction(_ id: Int, _ kind: SemanticScoringOutputKind) -> SemanticPredictionReference {
        SemanticPredictionReference(
            artifactFingerprint: Self.predictionHash,
            caseID: Self.caseID,
            kind: kind,
            proposalID: uuid(id)
        )
    }

    private func pair(
        _ prediction: SemanticPredictionReference,
        _ kind: SemanticScoringOutputKind,
        _ goldID: String
    ) -> SemanticMatchingPair {
        SemanticMatchingPair(prediction: prediction, gold: goldReference(kind, goldID))
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

    private func fraction(
        _ numerator: Int,
        _ denominator: Int,
        _ availability: SemanticMetricAvailability = .available
    ) -> SemanticMetricFraction {
        SemanticMetricFraction.ratio(
            numerator: numerator,
            denominator: denominator,
            unavailableWhenEmpty: availability
        )
    }

    private func uuid(_ id: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!
    }
}

private struct MetricGoldRecord {
    let kind: SemanticScoringOutputKind
    let output: SemanticGoldOutput
}

private struct MetricFixture {
    let root: URL
    let indexURL: URL
    let payloadURL: URL
    let predictions: [SemanticPredictionReference]
    let matchingMap: SemanticMatchingMap
    let observations: SemanticPredictionMetricObservationSet

    func metricRequest(
        observations: SemanticPredictionMetricObservationSet? = nil,
        runtimeAuthorization: SemanticScorerRuntimeAuthorization? = .development()
    ) -> SemanticMetricAuthorizationRequest {
        SemanticMetricAuthorizationRequest(
            scorerRequest: SemanticScorerAuthorizationRequest(
                runtimeAuthorization: runtimeAuthorization,
                requestedSplit: .development,
                benchmark: "meeting-execution-v0",
                caseID: "SYN-METRIC-D01",
                predictionArtifactFingerprint: PredictionArtifactFingerprint.rawArtifactBytes(
                    Data("synthetic-metric-prediction-artifact".utf8)
                ),
                availablePredictions: predictions,
                matchingMap: matchingMap
            ),
            predictionObservations: observations ?? self.observations
        )
    }
}

private final class MetricRecordingFileManager: FileManager {
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
