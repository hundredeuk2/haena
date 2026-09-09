import Foundation
import XCTest
@testable import HAENA

final class SemanticRegressionReportTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    func testEmptyReportPreservesUnavailableDenominators() throws {
        let report = try SemanticRegressionReportBuilder.build(from: [])

        XCTAssertEqual(report.schemaVersion, "haena-semantic-regression-report-v0.1")
        XCTAssertEqual(report.caseReports, [])
        XCTAssertEqual(report.aggregate.caseCount, 0)
        XCTAssertEqual(report.aggregate.outputKinds.count, 4)
        XCTAssertTrue(report.aggregate.outputKinds.allSatisfy {
            $0.ledger.goldTotal == 0 && $0.ledger.predictionTotal == 0
        })
        XCTAssertEqual(
            report.aggregate.forbiddenInference.violationRate.availability,
            .noPositivePredictions
        )
        XCTAssertNil(report.aggregate.forbiddenInference.violationRate.value)
    }

    func testPerfectSingleCaseRetainsExactPairsAndNoDiscrepancies() throws {
        let caseID = "SYN-REPORT-001"
        let predictions = [
            prediction(caseID, 1, .decision),
            prediction(caseID, 2, .actionItem),
            prediction(caseID, 3, .openQuestion),
            prediction(caseID, 4, .nextAgenda),
        ]
        let goldRecords = [
            gold("g1", .decision),
            gold("g2", .actionItem),
            gold("g3", .openQuestion),
            gold("g4", .nextAgenda),
        ]
        let pairs = zip(predictions, goldRecords).map {
            pair($0.0, $0.1.kind, $0.1.output.id.rawValue)
        }
        let report = try buildReport(
            try makeCase(caseID: caseID, gold: goldRecords, predictions: predictions, pairs: pairs)
        )
        let item = try XCTUnwrap(report.caseReports.first)

        XCTAssertEqual(item.matchedPairs, pairs.sorted())
        XCTAssertEqual(item.missedGold, [])
        XCTAssertEqual(item.extraPredictions, [])
        XCTAssertEqual(item.duplicatePredictions, [])
        XCTAssertEqual(item.evidenceDiscrepancies, [])
        XCTAssertEqual(item.targetSpeakerBDiscrepancies, [])
        XCTAssertEqual(item.assigneeDiscrepancies, [])
        XCTAssertEqual(item.dueDiscrepancies, [])
        XCTAssertTrue(item.metrics.outputKinds.allSatisfy {
            $0.ledger.truePositive == 1 && $0.ledger.falsePositive == 0
                && $0.ledger.falseNegative == 0
        })
    }

    func testMissedGoldAndExtraPredictionRemainTyped() throws {
        let caseID = "SYN-REPORT-002"
        let matched = prediction(caseID, 1, .decision)
        let extra = prediction(caseID, 2, .actionItem)
        let fixture = try makeCase(
            caseID: caseID,
            gold: [gold("g1", .decision), gold("g2", .openQuestion)],
            predictions: [extra, matched],
            pairs: [pair(matched, .decision, "g1")]
        )
        let item = try XCTUnwrap(buildReport(fixture).caseReports.first)

        XCTAssertEqual(item.extraPredictions, [extra])
        XCTAssertEqual(item.missedGold, [goldReference(caseID, .openQuestion, "g2")])
        XCTAssertEqual(
            item.metrics.outputKinds.first { $0.kind == .actionItem }?.ledger.falsePositive,
            1
        )
        XCTAssertEqual(
            item.metrics.outputKinds.first { $0.kind == .openQuestion }?.ledger.falseNegative,
            1
        )
    }

    func testDuplicateAndForbiddenAreFPsAndUseCompletePredictionDenominator() throws {
        let caseID = "SYN-REPORT-003"
        let canonical = prediction(caseID, 1, .actionItem)
        let duplicate = prediction(caseID, 2, .actionItem)
        let violation = prediction(caseID, 3, .actionItem)
        let forbiddenDeclaration = SemanticForbiddenPredictionDeclaration(
            prediction: violation,
            forbiddenInferenceID: "forbidden-1",
            outputKind: .actionItem
        )
        let fixture = try makeCase(
            caseID: caseID,
            gold: [gold("g1", .actionItem)],
            forbidden: [forbidden("forbidden-1", .actionItem)],
            predictions: [duplicate, violation, canonical],
            pairs: [pair(canonical, .actionItem, "g1")],
            duplicatePredictions: [.init(duplicate: duplicate, canonical: canonical)],
            forbiddenPredictions: [forbiddenDeclaration]
        )
        let report = try buildReport(fixture)
        let item = try XCTUnwrap(report.caseReports.first)
        let ledger = try XCTUnwrap(item.metrics.outputKinds.first { $0.kind == .actionItem }?.ledger)

        XCTAssertEqual(ledger.falsePositive, 2)
        XCTAssertEqual(ledger.duplicatePredictionCount, 1)
        XCTAssertEqual(item.forbiddenDeclarations, [forbiddenDeclaration])
        XCTAssertEqual(item.metrics.forbiddenInference.violationRate, fraction(1, 3))
        XCTAssertEqual(report.aggregate.forbiddenInference.violationRate, fraction(1, 3))
    }

    func testForbiddenZeroOverNIsAvailableAndZeroOverZeroIsUnavailable() throws {
        let populatedID = "SYN-REPORT-004"
        let populated = try buildReport(
            try makeCase(
                caseID: populatedID,
                gold: [],
                predictions: [prediction(populatedID, 1, .decision)],
                pairs: []
            )
        )
        let empty = try buildReport(
            try makeCase(caseID: "SYN-REPORT-005", gold: [], predictions: [], pairs: [])
        )

        XCTAssertEqual(populated.aggregate.forbiddenInference.violationRate, fraction(0, 1))
        XCTAssertEqual(empty.aggregate.forbiddenInference.violationRate.numerator, 0)
        XCTAssertEqual(empty.aggregate.forbiddenInference.violationRate.denominator, 0)
        XCTAssertEqual(
            empty.aggregate.forbiddenInference.violationRate.availability,
            .noPositivePredictions
        )
    }

    func testPartialEvidenceProducesExactTypedDiscrepancy() throws {
        let caseID = "SYN-REPORT-006"
        let prediction = prediction(caseID, 1, .decision)
        let fixture = try makeCase(
            caseID: caseID,
            gold: [gold("g1", .decision, evidence: ["U1", "U2"])],
            predictions: [prediction],
            pairs: [pair(prediction, .decision, "g1")],
            observations: [
                observation(
                    prediction,
                    evidence: .init(state: .known, utteranceIDs: ["U2", "U3"])
                ),
            ]
        )
        let discrepancy = try XCTUnwrap(
            buildReport(fixture).caseReports.first?.evidenceDiscrepancies.first
        )

        XCTAssertEqual(discrepancy.missingUtteranceIDs, ["U1"])
        XCTAssertEqual(discrepancy.extraUtteranceIDs, ["U3"])
        XCTAssertNil(discrepancy.ineligibilityReason)
    }

    func testResponsibilityMismatchAndUnresolvedRemainDistinct() throws {
        let caseID = "SYN-REPORT-007"
        let mismatch = prediction(caseID, 1, .actionItem)
        let unresolved = prediction(caseID, 2, .actionItem)
        let fixture = try makeCase(
            caseID: caseID,
            gold: [
                gold("g1", .actionItem, target: .targetSpeakerResponsible),
                gold("g2", .actionItem, target: .targetSpeakerResponsible),
            ],
            predictions: [mismatch, unresolved],
            pairs: [pair(mismatch, .actionItem, "g1"), pair(unresolved, .actionItem, "g2")],
            observations: [
                observation(mismatch, target: .otherSpeaker),
                observation(unresolved, target: .unresolved),
            ]
        )
        let item = try XCTUnwrap(buildReport(fixture).caseReports.first)

        XCTAssertEqual(item.targetSpeakerBDiscrepancies.count, 2)
        XCTAssertEqual(
            item.targetSpeakerBDiscrepancies.compactMap(\.ineligibilityReason),
            [.targetResponsibilityUnresolved]
        )
        XCTAssertTrue(item.ineligibleRecords.contains {
            $0.reason == .targetResponsibilityUnresolved
                && $0.predictionReference == unresolved
        })
    }

    func testAssigneeDiscrepanciesPreserveOrganizationIndividualAndUnspecified() throws {
        let caseID = "SYN-REPORT-008"
        let predictions = (1...3).map { prediction(caseID, $0, .actionItem) }
        let fixture = try makeCase(
            caseID: caseID,
            gold: [
                gold("g1", .actionItem, assignee: assignee(.individual, .speakerCommitment, "person:B")),
                gold("g2", .actionItem, assignee: assignee(.organization, .supportedByUtterance, "org:ops")),
                gold("g3", .actionItem, assignee: assignee(.unspecified, .absentMustStayEmpty, nil)),
            ],
            predictions: predictions,
            pairs: (0..<3).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(
                    predictions[0],
                    assignee: predictionAssignee(.known, .organization, .speakerCommitment, "person:B")
                ),
                observation(
                    predictions[1],
                    assignee: predictionAssignee(.known, .individual, .supportedByUtterance, "org:ops")
                ),
                observation(predictions[2], assignee: .init(state: .absent)),
            ]
        )
        let discrepancies = try XCTUnwrap(buildReport(fixture).caseReports.first).assigneeDiscrepancies

        XCTAssertEqual(discrepancies.count, 2)
        XCTAssertTrue(discrepancies.allSatisfy { $0.dimensions == [.scope] })
        XCTAssertEqual(Set(discrepancies.map(\.gold.scope)), [.individual, .organization])
    }

    func testDueDiscrepanciesPreserveAbsentRelativeAndUnresolved() throws {
        let caseID = "SYN-REPORT-009"
        let predictions = (1...3).map { prediction(caseID, $0, .actionItem) }
        let fixture = try makeCase(
            caseID: caseID,
            gold: [
                gold("g1", .actionItem, due: due(.absent, nil)),
                gold("g2", .actionItem, due: due(.explicitRelative, "P2D")),
                gold("g3", .actionItem, due: due(.explicit, "2026-10-01")),
            ],
            predictions: predictions,
            pairs: (0..<3).map { pair(predictions[$0], .actionItem, "g\($0 + 1)") },
            observations: [
                observation(predictions[0], due: .init(status: .absent)),
                observation(predictions[1], due: predictionDue(.explicitRelative, "P3D")),
                observation(predictions[2], due: .init(status: .unresolved)),
            ]
        )
        let item = try XCTUnwrap(buildReport(fixture).caseReports.first)

        XCTAssertEqual(item.dueDiscrepancies.count, 2)
        XCTAssertEqual(item.dueDiscrepancies[0].dimensions, [.value])
        XCTAssertEqual(item.dueDiscrepancies[0].gold.status, .explicitRelative)
        XCTAssertEqual(item.dueDiscrepancies[1].ineligibilityReason, .predictionDueUnresolved)
        XCTAssertTrue(item.ineligibleRecords.contains {
            $0.reason == .predictionDueUnresolved
        })
    }

    func testAmbiguityAndPriorStateIneligibilityArePreserved() throws {
        let caseID = "SYN-REPORT-010"
        let fixture = try makeCase(
            caseID: caseID,
            gold: [],
            predictions: [],
            pairs: [],
            ambiguityPolicy: .init(
                handling: .excludeFromMetrics,
                ambiguityIDs: ["ambiguity-2", "ambiguity-1"]
            )
        )
        let report = try buildReport(fixture)
        let item = try XCTUnwrap(report.caseReports.first)

        XCTAssertEqual(item.ambiguityPolicy.ambiguityIDs, ["ambiguity-1", "ambiguity-2"])
        XCTAssertEqual(
            item.ineligibleRecords,
            [.init(
                area: .priorStateTransition,
                predictionReference: nil,
                goldReference: nil,
                reason: .scorerIneligiblePriorState
            )]
        )
        XCTAssertEqual(report.aggregate.ambiguity.first?.ambiguityRecordCount, 2)
        XCTAssertEqual(
            report.aggregate.ineligibilityReasonCounts,
            [.init(reason: .scorerIneligiblePriorState, sampleCount: 1)]
        )
    }

    func testTwoCaseAggregateUsesMicroAggregationAndAvailableEligibleDenominator() throws {
        let firstID = "SYN-REPORT-011"
        let firstPrediction = prediction(firstID, 1, .decision)
        let first = try makeCase(
            caseID: firstID,
            gold: [gold("g1", .decision)],
            predictions: [firstPrediction],
            pairs: [pair(firstPrediction, .decision, "g1")]
        )
        let secondID = "SYN-REPORT-012"
        let matched = prediction(secondID, 1, .decision)
        let extra = prediction(secondID, 2, .decision)
        let second = try makeCase(
            caseID: secondID,
            gold: [gold("g1", .decision), gold("g2", .decision)],
            predictions: [extra, matched],
            pairs: [pair(matched, .decision, "g1")]
        )

        let report = try SemanticRegressionReportBuilder.build(from: [second, first])
        let metric = try XCTUnwrap(report.aggregate.outputKinds.first { $0.kind == .decision })
        XCTAssertEqual(metric.ledger.truePositive, 2)
        XCTAssertEqual(metric.ledger.falsePositive, 1)
        XCTAssertEqual(metric.ledger.falseNegative, 1)
        XCTAssertEqual(metric.classification.precision, fraction(2, 3))
        XCTAssertEqual(metric.classification.recall, fraction(2, 3))
        XCTAssertEqual(metric.classification.f1, fraction(4, 6))
        XCTAssertEqual(report.aggregate.evidence.exactEvidenceSetAccuracy, fraction(2, 2))
    }

    func testInputOrderAndRepeatedEncodingAreByteIdentical() throws {
        let firstID = "SYN-REPORT-013"
        let secondID = "SYN-REPORT-014"
        let firstPrediction = prediction(firstID, 1, .decision)
        let secondPrediction = prediction(secondID, 1, .actionItem)
        let first = try makeCase(
            caseID: firstID,
            gold: [gold("g1", .decision)],
            predictions: [firstPrediction],
            pairs: [pair(firstPrediction, .decision, "g1")]
        )
        let second = try makeCase(
            caseID: secondID,
            gold: [gold("g1", .actionItem)],
            predictions: [secondPrediction],
            pairs: [pair(secondPrediction, .actionItem, "g1")]
        )

        let a = try SemanticRegressionReportBuilder.build(from: [second, first])
        let b = try SemanticRegressionReportBuilder.build(from: [first, second])
        let bytes = try SemanticRegressionReport.encoder.encode(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(bytes, try SemanticRegressionReport.encoder.encode(b))
        XCTAssertEqual(bytes, try SemanticRegressionReport.encoder.encode(a))
        XCTAssertEqual(a.caseReports.map(\.caseID), [firstID, secondID])
    }

    func testDuplicateCaseIDFailsClosed() throws {
        let caseID = "SYN-REPORT-015"
        let item = try makeCase(caseID: caseID, gold: [], predictions: [], pairs: [])
        XCTAssertThrowsError(try SemanticRegressionReportBuilder.build(from: [item, item])) {
            XCTAssertEqual($0 as? SemanticRegressionReportError, .duplicateCaseID)
        }
    }

    func testCaseSchemaAndFingerprintMismatchFailClosedOnDecode() throws {
        let caseID = "SYN-REPORT-016"
        let fixture = try makeCase(caseID: caseID, gold: [], predictions: [], pairs: [])
        let bytes = try SemanticRegressionReport.encoder.encode(buildReport(fixture))

        try assertTamperedReportFails(bytes) { root in
            root["schema_version"] = "unknown"
        }
        try assertTamperedReportFails(bytes) { root in
            var cases = root["case_reports"] as! [[String: Any]]
            cases[0]["case_id"] = "SYN-REPORT-WRONG"
            root["case_reports"] = cases
        }
        try assertTamperedReportFails(bytes) { root in
            var provenance = root["provenance"] as! [String: Any]
            var fingerprints = provenance["case_fingerprints"] as! [[String: Any]]
            fingerprints[0]["gold_input_hash"] = Self.otherHash
            provenance["case_fingerprints"] = fingerprints
            root["provenance"] = provenance
        }
    }

    func testAggregateAndPerCaseLedgerMismatchFailClosedOnDecode() throws {
        let caseID = "SYN-REPORT-017"
        let prediction = prediction(caseID, 1, .decision)
        let fixture = try makeCase(
            caseID: caseID,
            gold: [gold("g1", .decision)],
            predictions: [prediction],
            pairs: [pair(prediction, .decision, "g1")]
        )
        let bytes = try SemanticRegressionReport.encoder.encode(buildReport(fixture))

        try assertTamperedReportFails(bytes, expected: .aggregateReconciliationMismatch) { root in
            var aggregate = root["aggregate"] as! [String: Any]
            var kinds = aggregate["output_kinds"] as! [[String: Any]]
            var ledger = kinds[0]["ledger"] as! [String: Any]
            ledger["true_positive"] = 0
            kinds[0]["ledger"] = ledger
            aggregate["output_kinds"] = kinds
            root["aggregate"] = aggregate
        }
        try assertTamperedReportFails(bytes, expected: .caseLedgerInvariantViolation) { root in
            var cases = root["case_reports"] as! [[String: Any]]
            var metrics = cases[0]["metrics"] as! [String: Any]
            var kinds = metrics["output_kinds"] as! [[String: Any]]
            var ledger = kinds[0]["ledger"] as! [String: Any]
            ledger["true_positive"] = 0
            kinds[0]["ledger"] = ledger
            metrics["output_kinds"] = kinds
            cases[0]["metrics"] = metrics
            root["case_reports"] = cases
        }
    }

    func testReportContainsNoPrivacyTripwireTextOrLocalPath() throws {
        let caseID = "SYN-REPORT-018"
        let report = try buildReport(
            try makeCase(caseID: caseID, gold: [], predictions: [], pairs: [])
        )
        let json = String(decoding: try SemanticRegressionReport.encoder.encode(report), as: UTF8.self)
        let tripwires = [
            "PRIVATE TRANSCRIPT SENTENCE",
            "Reviewer secret note",
            "Person Display Name",
            "/Users/example/Library/Application Support",
            "OPENAI_API_KEY",
            "sk-synthetic-secret",
        ]

        XCTAssertTrue(tripwires.allSatisfy { !json.contains($0) })
        XCTAssertFalse(json.contains("generated_at"))
    }

    func testEmptyGoldenJSONFixtureMatchesExactBytes() throws {
        let report = try SemanticRegressionReportBuilder.build(from: [])
        var actual = try SemanticRegressionReport.encoder.encode(report)
        actual.append(0x0A) // Repository JSON fixtures are newline-terminated files.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/semantic-regression-report-empty-v0.1.json")
        XCTAssertEqual(actual, try Data(contentsOf: fixtureURL))
    }

    private static let otherHash = SemanticSHA256Digest.rawBytes(Data("other".utf8))

    private func buildReport(
        _ metricCase: AuthorizedSemanticMetricScoringCase
    ) throws -> SemanticRegressionReport {
        try SemanticRegressionReportBuilder.build(from: [metricCase])
    }

    private func assertTamperedReportFails(
        _ data: Data,
        expected: SemanticRegressionReportError? = nil,
        mutation: (inout [String: Any]) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&root)
        let tampered = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        XCTAssertThrowsError(try SemanticRegressionReport.decoder.decode(
            SemanticRegressionReport.self,
            from: tampered
        ), file: file, line: line) { error in
            guard let expected else {
                XCTAssertNotNil(error as? SemanticRegressionReportError, file: file, line: line)
                return
            }
            XCTAssertEqual(error as? SemanticRegressionReportError, expected, file: file, line: line)
        }
    }

    private func makeCase(
        caseID: String,
        gold: [ReportGoldRecord],
        forbidden: [SemanticForbiddenInference] = [],
        predictions: [SemanticPredictionReference],
        pairs: [SemanticMatchingPair],
        duplicatePredictions: [SemanticDuplicatePredictionDeclaration] = [],
        forbiddenPredictions: [SemanticForbiddenPredictionDeclaration] = [],
        observations: [SemanticPredictionMetricObservation]? = nil,
        ambiguityPolicy: SemanticAmbiguityPolicy = .init(
            handling: .requireExplicitResolution,
            ambiguityIDs: []
        )
    ) throws -> AuthorizedSemanticMetricScoringCase {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENA-SemanticReport-\(UUID().uuidString)", isDirectory: true)
        let payloadRoot = root.appendingPathComponent("semantic-scorer-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
        temporaryRoots.append(root)

        let fingerprint = predictionFingerprint(caseID)
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
            caseID: caseID,
            split: .development,
            predictionArtifactHash: fingerprint.rawValue,
            matchingPolicyVersion: SemanticMatchingMap.policyVersion,
            outputs: outputs,
            forbiddenInferences: forbidden,
            ambiguityPolicy: ambiguityPolicy
        )
        let payload = try exactPayloadData(input)
        let goldHash = SemanticSHA256Digest.rawBytes(payload)
        let map = SemanticMatchingMap(
            schemaVersion: SemanticMatchingMap.forbiddenInferenceSchemaVersion,
            caseID: caseID,
            predictionArtifactHash: fingerprint.rawValue,
            goldInputHash: goldHash,
            pairs: pairs,
            duplicatePredictions: duplicatePredictions,
            forbiddenPredictions: forbiddenPredictions
        )
        let references = input.outputs.referencesByKind.map { kind, output in
            goldReference(caseID, kind, output.id.rawValue)
        }
        let index = SemanticScorerSourceIndexEntry(
            indexSchemaVersion: SemanticScorerInputStore.indexSchemaVersion,
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            benchmark: input.benchmark,
            caseID: caseID,
            split: .development,
            status: SemanticScorerInputStatus.scorerReady.rawValue,
            scorerReady: true,
            secondaryReviewComplete: true,
            predictionArtifactHash: fingerprint.rawValue,
            goldInputHash: goldHash,
            matchingPolicyVersion: SemanticMatchingMap.policyVersion,
            goldReferences: references
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var indexData = try encoder.encode(index)
        indexData.append(0x0A)
        try indexData.write(to: root.appendingPathComponent(SemanticScorerInputStore.sourceIndexFileName))
        try payload.write(to: payloadRoot.appendingPathComponent("\(caseID).json"))

        let store = SemanticScorerInputStore(root: root)
        let observationSet = SemanticPredictionMetricObservationSet(
            observations: observations ?? predictions.map { observation($0) }
        )
        let request = SemanticMetricAuthorizationRequest(
            scorerRequest: SemanticScorerAuthorizationRequest(
                runtimeAuthorization: .development(),
                requestedSplit: .development,
                benchmark: input.benchmark,
                caseID: caseID,
                predictionArtifactFingerprint: fingerprint,
                availablePredictions: predictions,
                matchingMap: map
            ),
            predictionObservations: observationSet
        )
        return try store.loadMetricScoringCase(for: store.authorizeMetrics(request))
    }

    private func exactPayloadData(_ input: SemanticScorerInput) throws -> Data {
        let encoded = try SemanticScorerInput.encoder.encode(input)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var outputs = try XCTUnwrap(root["outputs"] as? [String: Any])
        var actions = try XCTUnwrap(outputs["action_items"] as? [[String: Any]])
        for index in actions.indices {
            if var assignee = actions[index]["assignee"] as? [String: Any] {
                if assignee["value_reference"] == nil { assignee["value_reference"] = NSNull() }
                actions[index]["assignee"] = assignee
            }
            if var due = actions[index]["due"] as? [String: Any] {
                if due["value"] == nil { due["value"] = NSNull() }
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

    private func gold(
        _ id: String,
        _ kind: SemanticScoringOutputKind,
        evidence: [String] = ["SYN.1"],
        inference: SemanticInferenceClass = .explicit,
        target: SemanticTargetSpeakerResponsibility = .targetSpeakerResponsible,
        assignee: SemanticAssigneeExpectation? = nil,
        due: SemanticDueExpectation? = nil
    ) -> ReportGoldRecord {
        ReportGoldRecord(
            kind: kind,
            output: SemanticGoldOutput(
                id: GoldOutputID(rawValue: id),
                evidenceUtteranceIDs: evidence,
                inferenceClass: inference,
                targetSpeakerResponsibility: target,
                assignee: kind == .actionItem
                    ? assignee ?? self.assignee(.individual, .speakerCommitment, "person:B")
                    : nil,
                due: kind == .actionItem ? due ?? self.due(.explicit, "2026-09-30") : nil
            )
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

    private func observation(
        _ reference: SemanticPredictionReference,
        evidence: SemanticPredictionEvidenceObservation = .init(
            state: .known,
            utteranceIDs: ["SYN.1"]
        ),
        target: SemanticPredictionTargetResponsibility? = nil,
        assignee: SemanticPredictionAssigneeObservation? = nil,
        due: SemanticPredictionDueObservation? = nil
    ) -> SemanticPredictionMetricObservation {
        let action = reference.kind == .actionItem
        return SemanticPredictionMetricObservation(
            predictionReference: reference,
            evidence: evidence,
            targetResponsibility: target ?? (action
                ? .targetSpeakerResponsible : .noResponsibilityAssigned),
            assignee: assignee ?? (action
                ? predictionAssignee(.known, .individual, .speakerCommitment, "person:B")
                : .init(state: .absent)),
            due: due ?? (action
                ? predictionDue(.explicit, "2026-09-30") : .init(status: .absent))
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

    private func prediction(
        _ caseID: String,
        _ id: Int,
        _ kind: SemanticScoringOutputKind
    ) -> SemanticPredictionReference {
        SemanticPredictionReference(
            artifactFingerprint: predictionFingerprint(caseID).rawValue,
            caseID: caseID,
            kind: kind,
            proposalID: UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012d",
                id
            ))!
        )
    }

    private func predictionFingerprint(_ caseID: String) -> PredictionArtifactFingerprint {
        PredictionArtifactFingerprint.rawArtifactBytes(Data("artifact-\(caseID)".utf8))
    }

    private func pair(
        _ prediction: SemanticPredictionReference,
        _ kind: SemanticScoringOutputKind,
        _ goldID: String
    ) -> SemanticMatchingPair {
        SemanticMatchingPair(
            prediction: prediction,
            gold: goldReference(prediction.caseID, kind, goldID)
        )
    }

    private func goldReference(
        _ caseID: String,
        _ kind: SemanticScoringOutputKind,
        _ id: String
    ) -> SemanticGoldReference {
        SemanticGoldReference(
            inputSchemaVersion: SemanticScorerInput.schemaVersion,
            caseID: caseID,
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
}

private struct ReportGoldRecord {
    let kind: SemanticScoringOutputKind
    let output: SemanticGoldOutput
}
