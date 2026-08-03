import XCTest
@testable import HAENA

final class ProjectModelTests: XCTestCase {
    func testProjectCreationWithEmptyCollections() {
        let project = Project(
            id: TestFixtures.projectID,
            name: "HAE.NA MVP",
            summary: "Phase 0 domain model",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        XCTAssertEqual(project.id, TestFixtures.projectID)
        XCTAssertTrue(project.meetings.isEmpty)
        XCTAssertTrue(project.decisions.isEmpty)
    }

    func testProjectCodableRoundTrip() throws {
        let original = Project(
            id: TestFixtures.projectID,
            name: "HAE.NA MVP",
            summary: "Phase 0 domain model",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
