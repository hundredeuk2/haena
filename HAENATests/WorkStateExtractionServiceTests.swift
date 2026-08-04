import XCTest
@testable import HAENA

final class WorkStateExtractionServiceTests: XCTestCase {
    private var meeting: Meeting!
    private var repository: InMemoryProjectRepository!

    override func setUp() async throws {
        meeting = ExtractionFixtures.meeting()
        repository = InMemoryProjectRepository()
        try await repository.save(ExtractionFixtures.project(with: [meeting]))
    }

    private func makeService(
        _ outcome: StubWorkStateExtractor.Outcome,
        repository: (any ProjectRepository)? = nil
    ) -> WorkStateExtractionService {
        WorkStateExtractionService(
            repository: repository ?? self.repository,
            extractor: StubWorkStateExtractor(outcome),
            now: { TestFixtures.laterDate }
        )
    }

    private func storedProject(from repository: (any ProjectRepository)? = nil) async throws -> Project {
        let repository = repository ?? self.repository!
        let project = try await repository.project(id: TestFixtures.projectID)
        return try XCTUnwrap(project)
    }

    // MARK: - Applying results

    func testStoresAllFourKindsAgainstTheProject() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedDecisions, 1)
        XCTAssertEqual(report.storedActionItems, 1)
        XCTAssertEqual(report.storedOpenQuestions, 1)
        XCTAssertEqual(report.storedAgendaItems, 1)
        XCTAssertTrue(report.rejected.isEmpty)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
        XCTAssertEqual(project.openQuestions.count, 1)
        XCTAssertEqual(project.nextAgenda.count, 1)
        XCTAssertEqual(project.updatedAt, TestFixtures.laterDate)
    }

    func testEmptyExtractionStoresNothingAndLeavesTheMeetingIntact() async throws {
        let service = makeService(.success(ExtractionFixtures.emptyResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedCount, 0)
        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertTrue(project.nextAgenda.isEmpty)
        XCTAssertEqual(project.meetings.count, 1)
    }

    func testReportsRejectedProposalsWithoutStoringThem() async throws {
        let service = makeService(.success(
            ExtractionFixtures.fullResult(evidence: ExtractionFixtures.evidence(quote: "회의록에 없는 문장"))
        ))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.storedCount, 0)
        XCTAssertEqual(report.rejected.count, 4)
        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
    }

    func testCarriesProviderMetadataIntoTheReport() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let report = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(report.metadata.provider, .openAI)
        XCTAssertEqual(report.metadata.modelID, "test-model")
    }

    // MARK: - Failure must not damage stored data

    func testProviderFailureLeavesTheSavedMeetingAndProjectUntouched() async throws {
        let service = makeService(.failure(.rateLimited))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            XCTFail("expected the provider error to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .rateLimited)
        }

        let project = try await storedProject()
        XCTAssertEqual(project.meetings.count, 1)
        XCTAssertEqual(project.meetings[0].transcriptSegments[0].text, ExtractionFixtures.transcript)
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate, "a failed extraction must not touch the project")
    }

    func testMissingCredentialSurfacesAsAnErrorRatherThanFabricatedResults() async throws {
        let service = makeService(.failure(.missingCredential))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
            XCTFail("expected missingCredential to propagate")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionError, .missingCredential)
        }

        let project = try await storedProject()
        XCTAssertTrue(project.decisions.isEmpty)
        XCTAssertTrue(project.actionItems.isEmpty)
    }

    func testUnknownProjectAndMeetingAreRejectedBeforeExtraction() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        do {
            _ = try await service.extractAndApply(meetingID: meeting.id, projectID: UUID())
            XCTFail("expected projectNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionServiceError, .projectNotFound)
        }

        do {
            _ = try await service.extractAndApply(meetingID: UUID(), projectID: meeting.projectID)
            XCTFail("expected meetingNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateExtractionServiceError, .meetingNotFound)
        }
    }

    // MARK: - Re-extraction policy

    func testReExtractingReplacesPreviousProposalsInsteadOfAccumulating() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))

        let first = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
        let second = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        XCTAssertEqual(first.replacedProposals, 0)
        XCTAssertEqual(second.replacedProposals, 4, "the first run's four proposals are superseded")

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1)
        XCTAssertEqual(project.actionItems.count, 1)
        XCTAssertEqual(project.openQuestions.count, 1)
        XCTAssertEqual(project.nextAgenda.count, 1)
    }

    func testReExtractingKeepsItemsTheUserHasAlreadyActedOn() async throws {
        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        // Simulate the review step this slice does not yet ship: the user confirms one decision
        // and resolves the open question.
        var project = try await storedProject()
        project.decisions[0].status = .confirmed
        project.openQuestions[0].status = .resolved
        try await repository.save(project)

        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.decisions.count, 2, "the confirmed decision survives alongside the new proposal")
        XCTAssertEqual(updated.decisions.filter { $0.status == .confirmed }.count, 1)
        XCTAssertEqual(updated.openQuestions.count, 2)
        XCTAssertEqual(updated.openQuestions.filter { $0.status == .resolved }.count, 1)
    }

    func testReExtractingKeepsHandEnteredAgendaItemsThatHaveNoEvidence() async throws {
        var project = try await storedProject()
        project.nextAgenda.append(
            AgendaItem(
                id: UUID(),
                projectID: project.id,
                title: "사용자가 직접 추가한 아젠다",
                reason: "직접 입력",
                sourceMeetingID: meeting.id,
                relatedActionItemID: nil,
                relatedOpenQuestionID: nil,
                status: .pending,
                createdAt: TestFixtures.fixedDate
            )
        )
        try await repository.save(project)

        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let updated = try await storedProject()
        XCTAssertEqual(updated.nextAgenda.filter { $0.evidence == nil }.count, 1)
        XCTAssertEqual(updated.nextAgenda.filter { $0.evidence != nil }.count, 1)
    }

    func testReExtractingOneMeetingLeavesAnotherMeetingsProposalsAlone() async throws {
        let otherMeeting = ExtractionFixtures.meeting(id: UUID(), segmentID: UUID())
        var project = try await storedProject()
        project.meetings.append(otherMeeting)
        try await repository.save(project)

        let service = makeService(.success(ExtractionFixtures.fullResult()))
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        let otherService = WorkStateExtractionService(
            repository: repository,
            extractor: StubWorkStateExtractor(.success(
                ExtractionFixtures.fullResult(
                    evidence: ExtractionFixtures.evidence(segmentID: otherMeeting.transcriptSegments[0].id)
                )
            )),
            now: { TestFixtures.laterDate }
        )
        _ = try await otherService.extractAndApply(meetingID: otherMeeting.id, projectID: project.id)

        let updated = try await storedProject()
        XCTAssertEqual(updated.decisions.count, 2)
        XCTAssertEqual(updated.decisions.filter { $0.meetingID == meeting.id }.count, 1)
        XCTAssertEqual(updated.decisions.filter { $0.meetingID == otherMeeting.id }.count, 1)
    }

    // MARK: - Persistence

    func testStoredProposalsSurviveAJSONRepositoryReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Extraction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("projects.json")
        let writer = JSONProjectRepository(fileURL: fileURL)
        try await writer.save(ExtractionFixtures.project(with: [meeting]))

        let service = makeService(.success(ExtractionFixtures.fullResult()), repository: writer)
        _ = try await service.extractAndApply(meetingID: meeting.id, projectID: meeting.projectID)

        // A second instance pointed at the same file is the closest equivalent to relaunching.
        let reader = JSONProjectRepository(fileURL: fileURL)
        let reloadedProject = try await reader.project(id: TestFixtures.projectID)
        let reloaded = try XCTUnwrap(reloadedProject)

        XCTAssertEqual(reloaded.decisions.count, 1)
        XCTAssertEqual(reloaded.actionItems.count, 1)
        XCTAssertEqual(reloaded.openQuestions.count, 1)
        XCTAssertEqual(reloaded.nextAgenda.count, 1)

        XCTAssertEqual(reloaded.decisions[0].status, .proposed)
        XCTAssertEqual(reloaded.decisions[0].evidence?.quote, "2월 출시로 가기로 했습니다")
        XCTAssertEqual(reloaded.decisions[0].confidence, Confidence(0.8))
        XCTAssertEqual(reloaded.nextAgenda[0].confidence, Confidence(0.8))
        XCTAssertEqual(reloaded.nextAgenda[0].evidence?.transcriptSegmentID, TestFixtures.segmentID)
    }
}
