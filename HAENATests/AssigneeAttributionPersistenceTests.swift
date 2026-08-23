import XCTest
@testable import HAENA

final class AssigneeAttributionPersistenceTests: XCTestCase {
    private var testDirectory: URL!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HAENATests-AssigneeAttributionPersistence-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    func testBasisAndResolutionRawValuesAreFrozen() {
        XCTAssertEqual(
            AssigneeAttributionBasis.allCases.map(\.rawValue),
            [
                "explicit_name",
                "self_reference",
                "speaker_commitment",
                "team_or_role",
                "unspecified",
            ]
        )
        XCTAssertEqual(
            AssigneeAttributionResolution.allCases.map(\.rawValue),
            [
                "resolved",
                "no_participant_match",
                "ambiguous_participant_match",
                "missing_evidence_speaker",
                "evidence_speaker_not_participant",
                "speaker_label_mismatch",
                "non_individual",
                "unspecified",
                "invalid_attribution",
            ]
        )
    }

    func testLegacyActionItemJSONWithoutAttributionStillDecodes() throws {
        let legacy = LegacyActionItem(
            id: Self.actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "기존 저장 업무",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .confirmed,
            evidence: nil,
            confidence: Confidence(0.8),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )

        let decoded = try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.title, legacy.title)
        XCTAssertNil(decoded.proposedAssigneeAttribution)
    }

    func testLegacyActionItemPreservesExistingAssigneeID() throws {
        let legacy = LegacyActionItem(
            id: Self.actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "기존 담당 업무",
            details: "기존 저장 형식",
            assigneeID: TestFixtures.participantID,
            dueDate: TestFixtures.laterDate,
            status: .inProgress,
            evidence: makeEvidence(),
            confidence: Confidence(0.7),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.laterDate
        )

        let decoded = try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.assigneeID, TestFixtures.participantID)
        XCTAssertEqual(decoded.evidence, legacy.evidence)
        XCTAssertNil(decoded.proposedAssigneeAttribution)
    }

    func testNewAttributionJSONRoundTripsEveryStoredField() throws {
        let attribution = makeAttribution()
        let item = makeActionItem(attribution: attribution)

        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(object["proposedAssigneeAttribution"] as? [String: Any])
        XCTAssertEqual(stored["basis"] as? String, "self_reference")
        XCTAssertEqual(stored["reference"] as? String, "제가")
        XCTAssertEqual(stored["speakerLabel"] as? String, "B")
        XCTAssertEqual(stored["resolution"] as? String, "resolved")

        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.proposedAssigneeAttribution, attribution)
    }

    func testHandEnteredActionItemDefaultsAttributionToNil() throws {
        let item = ActionItem(
            id: Self.actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "직접 입력한 업무",
            details: nil,
            assigneeID: TestFixtures.participantID,
            dueDate: nil,
            status: .confirmed,
            evidence: nil,
            confidence: .maximum,
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )

        XCTAssertNil(item.proposedAssigneeAttribution)
        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["proposedAssigneeAttribution"])
        XCTAssertNil(try JSONDecoder().decode(ActionItem.self, from: data).proposedAssigneeAttribution)
    }

    func testAttributionRequiresFiniteResolutionButAllowsMissingReferenceAndSpeaker() throws {
        let minimal = Data(
            #"{"basis":"unspecified","resolution":"unspecified"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(AssigneeAttribution.self, from: minimal)
        XCTAssertEqual(decoded.basis, .unspecified)
        XCTAssertNil(decoded.reference)
        XCTAssertNil(decoded.speakerLabel)
        XCTAssertEqual(decoded.resolution, .unspecified)

        let missingResolution = Data(#"{"basis":"unspecified"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(AssigneeAttribution.self, from: missingResolution)
        )
        let unknownResolution = Data(
            #"{"basis":"unspecified","resolution":"future_value"}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(AssigneeAttribution.self, from: unknownResolution)
        )
    }

    func testRepositoryReloadPreservesAttribution() async throws {
        let url = testDirectory.appendingPathComponent("projects.json")
        let item = makeActionItem(attribution: makeAttribution())
        let original = makeProject(actionItem: item)

        try await JSONProjectRepository(fileURL: url).save(original)
        let reloaded = try await JSONProjectRepository(fileURL: url).project(id: original.id)

        XCTAssertEqual(reloaded, original)
        XCTAssertEqual(reloaded?.actionItems.first?.proposedAssigneeAttribution, makeAttribution())
    }

    func testEditingAssigneeIDPreservesOriginalProvenanceAcrossReload() async throws {
        let url = testDirectory.appendingPathComponent("projects.json")
        let attribution = makeAttribution()
        var project = makeProject(actionItem: makeActionItem(attribution: attribution))
        let originalAssigneeID = try XCTUnwrap(project.actionItems.first?.assigneeID)
        let correctedAssigneeID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        XCTAssertNotEqual(originalAssigneeID, correctedAssigneeID)
        project.actionItems[0].assigneeID = correctedAssigneeID
        project.actionItems[0].updatedAt = TestFixtures.laterDate
        try await JSONProjectRepository(fileURL: url).save(project)

        let storedProject = try await JSONProjectRepository(fileURL: url).project(id: project.id)
        let reloaded = try XCTUnwrap(storedProject)
        let reloadedItem = try XCTUnwrap(reloaded.actionItems.first)
        XCTAssertEqual(reloadedItem.assigneeID, correctedAssigneeID)
        XCTAssertEqual(reloadedItem.proposedAssigneeAttribution, attribution)
    }

    // MARK: Fixtures

    private static let actionItemID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000010"
    )!

    private func makeAttribution() -> AssigneeAttribution {
        AssigneeAttribution(
            basis: .selfReference,
            reference: "제가",
            speakerLabel: "B",
            resolution: .resolved
        )
    }

    private func makeEvidence() -> EvidenceReference {
        EvidenceReference(
            meetingID: TestFixtures.meetingID,
            transcriptSegmentID: TestFixtures.segmentID,
            quote: "제가 맡겠습니다."
        )
    }

    private func makeActionItem(attribution: AssigneeAttribution?) -> ActionItem {
        ActionItem(
            id: Self.actionItemID,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "지표 정의",
            details: nil,
            assigneeID: TestFixtures.participantID,
            dueDate: TestFixtures.laterDate,
            status: .proposed,
            evidence: makeEvidence(),
            confidence: Confidence(0.9),
            proposedAssigneeAttribution: attribution,
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    private func makeProject(actionItem: ActionItem) -> Project {
        Project(
            id: TestFixtures.projectID,
            name: "Attribution persistence",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [actionItem],
            openQuestions: [],
            nextAgenda: []
        )
    }

    /// Exact pre-attribution ActionItem shape used to prove additive decoding compatibility.
    private struct LegacyActionItem: Encodable {
        let id: UUID
        let projectID: UUID
        let meetingID: UUID
        let title: String
        let details: String?
        let assigneeID: UUID?
        let dueDate: Date?
        let status: ActionItemStatus
        let evidence: EvidenceReference?
        let confidence: Confidence
        let createdAt: Date
        let updatedAt: Date
    }
}
