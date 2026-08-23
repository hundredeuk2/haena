import Foundation
import XCTest
@testable import HAENA

/// Provider-boundary tests only. They encode/decode local JSON values and never construct a live
/// transport, credential resolver, or request to an external API.
final class StructuredAssigneeProviderContractTests: XCTestCase {
    func testActionItemSchemaRequiresOnlyTheThreeStrictAttributionFields() throws {
        let item = try actionItemSchema()

        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            Set(try XCTUnwrap(item["required"] as? [String])),
            [
                "provider_key", "title", "details", "assignee_basis", "assignee_reference",
                "assignee_speaker", "due_date", "confidence", "evidence",
            ]
        )
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            [
                "provider_key", "title", "details", "assignee_basis", "assignee_reference",
                "assignee_speaker", "due_date", "confidence", "evidence",
            ]
        )
        XCTAssertNil(properties["assignee_name"])
        XCTAssertNil(properties["participant_id"], "a provider must never return an app UUID")
    }

    func testSchemaBasisEnumIsExactAndReferenceAndSpeakerAreRequiredNullableKeys() throws {
        let properties = try XCTUnwrap(try actionItemSchema()["properties"] as? [String: Any])
        let basis = try XCTUnwrap(properties["assignee_basis"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap(basis["enum"] as? [String])),
            [
                "explicit_name", "self_reference", "speaker_commitment",
                "team_or_role", "unspecified",
            ]
        )

        for key in ["assignee_reference", "assignee_speaker"] {
            let field = try XCTUnwrap(properties[key] as? [String: Any])
            XCTAssertEqual(Set(try XCTUnwrap(field["type"] as? [String])), ["string", "null"])
        }
    }

    func testDTOAcceptsEveryValidBasisAndNullableCombination() throws {
        let fixtures: [(
            AssigneeAttributionBasis,
            Any,
            Any,
            String?,
            String?
        )] = [
            (.explicitName, "민수님", NSNull(), "민수님", nil),
            (.selfReference, "제가", "B", "제가", "B"),
            (.speakerCommitment, NSNull(), "B", nil, "B"),
            (.teamOrRole, "우리 팀", NSNull(), "우리 팀", nil),
            (.unspecified, NSNull(), NSNull(), nil, nil),
        ]

        for (basis, referenceJSON, speakerJSON, expectedReference, expectedSpeaker) in fixtures {
            let item = try decodeActionItem(
                basis: basis.rawValue,
                reference: referenceJSON,
                speaker: speakerJSON
            )
            XCTAssertEqual(item.assigneeBasis, basis)
            XCTAssertEqual(item.assigneeReference, expectedReference)
            XCTAssertEqual(item.assigneeSpeaker, expectedSpeaker)
        }
    }

    func testDTORejectsUnknownBasis() throws {
        XCTAssertThrowsError(
            try decodeActionItem(
                basis: "future_guessed_owner",
                reference: NSNull(),
                speaker: NSNull()
            )
        )
    }

    func testDTORejectsAdditionalActionItemKeyIncludingParticipantUUID() throws {
        XCTAssertThrowsError(
            try decodeActionItem(
                basis: "unspecified",
                reference: NSNull(),
                speaker: NSNull(),
                additional: ["participant_id": UUID().uuidString]
            )
        )
    }

    func testDTORejectsMissingRequiredNullableField() throws {
        var item = validActionItem(
            basis: "unspecified",
            reference: NSNull(),
            speaker: NSNull()
        )
        item.removeValue(forKey: "assignee_reference")
        XCTAssertThrowsError(try decodeActionItem(item))
    }

    func testDTORejectsEveryInvalidBasisFieldCombination() throws {
        let invalid: [(String, Any, Any)] = [
            ("explicit_name", NSNull(), NSNull()),
            ("explicit_name", "민수님", "B"),
            ("self_reference", "제가", NSNull()),
            ("self_reference", NSNull(), "B"),
            ("speaker_commitment", NSNull(), NSNull()),
            ("speaker_commitment", "   ", "B"),
            ("team_or_role", NSNull(), NSNull()),
            ("team_or_role", "우리 팀", "A"),
            ("unspecified", "민수님", NSNull()),
            ("unspecified", NSNull(), "B"),
        ]

        for (basis, reference, speaker) in invalid {
            XCTAssertThrowsError(
                try decodeActionItem(basis: basis, reference: reference, speaker: speaker),
                "accepted invalid combination for \(basis)"
            )
        }
    }

    func testPromptFixesNamedRequestSelfReferenceAndOmittedSubjectPromiseExamples() {
        let prompt = OpenAIExtractionSchema.instructions

        XCTAssertTrue(prompt.contains("민수님, 보고서 작성해 주세요."))
        XCTAssertTrue(prompt.contains("explicit_name"))
        XCTAssertTrue(prompt.contains("제가 보고서를 작성하겠습니다."))
        XCTAssertTrue(prompt.contains("self_reference"))
        XCTAssertTrue(prompt.contains("보고서를 작성하겠습니다."))
        XCTAssertTrue(prompt.contains("speaker_commitment"))
        XCTAssertTrue(prompt.contains("검토해 주세요."))
        XCTAssertTrue(prompt.contains("unspecified"))
        XCTAssertTrue(prompt.contains("Never return a participant UUID"))
    }

    func testProviderNeutralAttributionCarriesOpaqueSpeakerLabelNotUUID() {
        let attribution = ProposedAssigneeAttribution(
            basis: .selfReference,
            reference: "제가",
            speakerLabel: "B"
        )

        XCTAssertEqual(attribution.basis, .selfReference)
        XCTAssertEqual(attribution.reference, "제가")
        XCTAssertEqual(attribution.speakerLabel, "B")
        XCTAssertNil(UUID(uuidString: attribution.speakerLabel ?? ""))
    }

    func testContinuitySchemaHasExactlySevenRequiredRootArrays() throws {
        let root = try schemaRoot()
        let expected: Set<String> = [
            "decisions", "action_items", "open_questions", "next_agenda_items",
            "progress_signals", "open_question_resolution_links",
            "decision_derived_action_item_links",
        ]

        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(root["required"] as? [String])), expected)
        XCTAssertEqual(Set(try XCTUnwrap(root["properties"] as? [String: Any]).keys), expected)
    }

    func testEveryBaseObjectRequiresProviderKeyWithBoundedOpaquePattern() throws {
        let properties = try XCTUnwrap(try schemaRoot()["properties"] as? [String: Any])
        let expectedPatterns = [
            "decisions": "^decision_[1-9][0-9]{0,5}$",
            "action_items": "^action_[1-9][0-9]{0,5}$",
            "open_questions": "^question_[1-9][0-9]{0,5}$",
            "next_agenda_items": "^agenda_[1-9][0-9]{0,5}$",
        ]
        for (collection, expectedPattern) in expectedPatterns {
            let array = try XCTUnwrap(properties[collection] as? [String: Any])
            let item = try XCTUnwrap(array["items"] as? [String: Any])
            let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
            let key = try XCTUnwrap(itemProperties["provider_key"] as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(item["required"] as? [String]).contains("provider_key"), collection)
            XCTAssertEqual(key["pattern"] as? String, expectedPattern, collection)
            XCTAssertEqual((key["maxLength"] as? NSNumber)?.intValue, 32, collection)
        }
    }

    func testContinuitySignalSchemaUsesExactKeysAndEnumAllowLists() throws {
        let properties = try XCTUnwrap(try schemaRoot()["properties"] as? [String: Any])

        let progress = try arrayItem("progress_signals", in: properties)
        XCTAssertEqual(Set(try XCTUnwrap(progress["required"] as? [String])), ["kind", "action_item_key", "evidence"])
        let progressProperties = try XCTUnwrap(progress["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap((progressProperties["kind"] as? [String: Any])?["enum"] as? [String])),
            ["completed", "deferred", "blocked"]
        )

        let resolution = try arrayItem("open_question_resolution_links", in: properties)
        let resolutionProperties = try XCTUnwrap(resolution["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(try XCTUnwrap((resolutionProperties["target_kind"] as? [String: Any])?["enum"] as? [String])),
            ["decision", "action_item", "agenda_item"]
        )
        XCTAssertEqual(
            (resolutionProperties["prior_open_question_ref"] as? [String: Any])?["pattern"] as? String,
            "^prior_question_[1-9][0-9]{0,5}$"
        )

        let derived = try arrayItem("decision_derived_action_item_links", in: properties)
        XCTAssertEqual(
            Set(try XCTUnwrap(derived["required"] as? [String])),
            ["incoming_decision_key", "prior_decision_ref", "action_item_key", "evidence"]
        )
        let derivedProperties = try XCTUnwrap(derived["properties"] as? [String: Any])
        XCTAssertEqual(
            (derivedProperties["prior_decision_ref"] as? [String: Any])?["pattern"] as? String,
            "^prior_decision_[1-9][0-9]{0,5}$"
        )
        for item in [progress, resolution, derived] {
            XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        }
    }

    func testDTORejectsExtraRootAndBaseKeysButRoundTripsAllSignals() throws {
        let valid = validPayloadObject()
        let decoded = try decodePayload(valid)
        XCTAssertEqual(decoded.decisions[0].providerKey, "decision_1")
        XCTAssertEqual(decoded.actionItems[0].providerKey, "action_1")
        XCTAssertEqual(decoded.progressSignals[0].kind, .completed)
        XCTAssertEqual(decoded.openQuestionResolutionLinks[0].targetKind, .agendaItem)
        XCTAssertEqual(decoded.decisionDerivedActionItemLinks[0].incomingDecisionKey, "decision_1")
        XCTAssertNil(decoded.decisionDerivedActionItemLinks[0].priorDecisionReference)

        var extraRoot = valid
        extraRoot["project_id"] = UUID().uuidString
        XCTAssertThrowsError(try decodePayload(extraRoot))

        var extraBase = valid
        var decisions = try XCTUnwrap(extraBase["decisions"] as? [[String: Any]])
        decisions[0]["id"] = UUID().uuidString
        extraBase["decisions"] = decisions
        XCTAssertThrowsError(try decodePayload(extraBase))
    }

    func testMalformedSignalEnumSurvivesAsRawSidecarWithoutDestroyingBaseDTO() throws {
        var payload = validPayloadObject()
        var progress = try XCTUnwrap(payload["progress_signals"] as? [[String: Any]])
        progress[0]["kind"] = "probably_done"
        payload["progress_signals"] = progress

        let decoded = try decodePayload(payload)

        XCTAssertEqual(decoded.decisions.count, 1)
        XCTAssertNil(decoded.progressSignals[0].kind)
    }

    func testPromptRequiresGroundedSignalsNoInferenceNoFabricationAndEmptyArrays() {
        let prompt = OpenAIExtractionSchema.instructions

        XCTAssertTrue(prompt.contains("explicitly provides its evidence"))
        XCTAssertTrue(prompt.contains("emotion, tone"))
        XCTAssertTrue(prompt.contains("keyword matching"))
        XCTAssertTrue(prompt.contains("carried forward, not resolved"))
        XCTAssertTrue(prompt.contains("Never manipulate or fabricate a base proposal"))
        XCTAssertTrue(prompt.contains("all three signal arrays as empty arrays"))
        XCTAssertTrue(prompt.contains("Never put transcript text, a person's name, or a UUID in a key"))
    }

    // MARK: Helpers

    private func schemaRoot() throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(OpenAIExtractionSchema.schema())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    }

    private func arrayItem(
        _ key: String,
        in properties: [String: Any]
    ) throws -> [String: Any] {
        let array = try XCTUnwrap(properties[key] as? [String: Any])
        return try XCTUnwrap(array["items"] as? [String: Any])
    }

    private func decodePayload(_ object: [String: Any]) throws -> OpenAIExtractionPayload {
        try JSONDecoder().decode(
            OpenAIExtractionPayload.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func validPayloadObject() -> [String: Any] {
        let evidence: [String: Any] = ["segment_id": "segment_1", "quote": "완료했습니다"]
        return [
            "decisions": [[
                "provider_key": "decision_1", "statement": "출시한다", "rationale": NSNull(),
                "confidence": 0.9, "evidence": evidence,
            ]],
            "action_items": [[
                "provider_key": "action_1", "title": "보고서 작성", "details": NSNull(),
                "assignee_basis": "unspecified", "assignee_reference": NSNull(),
                "assignee_speaker": NSNull(), "due_date": NSNull(), "confidence": 0.9,
                "evidence": evidence,
            ]],
            "open_questions": [[
                "provider_key": "question_1", "question": "언제 출시하는가?",
                "confidence": 0.8, "evidence": evidence,
            ]],
            "next_agenda_items": [[
                "provider_key": "agenda_1", "title": "출시 점검", "reason": "다음 회의에서 점검",
                "confidence": 0.7, "evidence": evidence,
            ]],
            "progress_signals": [[
                "kind": "completed", "action_item_key": "action_1", "evidence": evidence,
            ]],
            "open_question_resolution_links": [[
                "prior_open_question_ref": "prior_question_1", "target_kind": "agenda_item",
                "target_key": "agenda_1", "evidence": evidence,
            ]],
            "decision_derived_action_item_links": [[
                "incoming_decision_key": "decision_1", "prior_decision_ref": NSNull(),
                "action_item_key": "action_1", "evidence": evidence,
            ]],
        ]
    }

    private func actionItemSchema() throws -> [String: Any] {
        let encoded = try JSONEncoder().encode(OpenAIExtractionSchema.schema())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rootProperties = try XCTUnwrap(root["properties"] as? [String: Any])
        let actionItems = try XCTUnwrap(rootProperties["action_items"] as? [String: Any])
        return try XCTUnwrap(actionItems["items"] as? [String: Any])
    }

    private func decodeActionItem(
        basis: String,
        reference: Any,
        speaker: Any,
        additional: [String: Any] = [:]
    ) throws -> OpenAIExtractionPayload.ActionItemDTO {
        var item = validActionItem(basis: basis, reference: reference, speaker: speaker)
        item.merge(additional) { _, replacement in replacement }
        return try decodeActionItem(item)
    }

    private func decodeActionItem(
        _ item: [String: Any]
    ) throws -> OpenAIExtractionPayload.ActionItemDTO {
        let data = try JSONSerialization.data(withJSONObject: [
            "decisions": [],
            "action_items": [item],
            "open_questions": [],
            "next_agenda_items": [],
            "progress_signals": [],
            "open_question_resolution_links": [],
            "decision_derived_action_item_links": [],
        ])
        return try JSONDecoder().decode(OpenAIExtractionPayload.self, from: data).actionItems[0]
    }

    private func validActionItem(
        basis: String,
        reference: Any,
        speaker: Any
    ) -> [String: Any] {
        [
            "provider_key": "action_1",
            "title": "보고서 작성",
            "details": NSNull(),
            "assignee_basis": basis,
            "assignee_reference": reference,
            "assignee_speaker": speaker,
            "due_date": NSNull(),
            "confidence": 0.9,
            "evidence": [
                "segment_id": "00000000-0000-0000-0000-000000000001",
                "quote": "보고서를 작성하겠습니다.",
            ],
        ]
    }
}
