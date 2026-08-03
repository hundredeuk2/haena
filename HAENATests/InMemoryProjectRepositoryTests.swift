import XCTest
@testable import HAENA

final class InMemoryProjectRepositoryTests: XCTestCase {
    private static func makeProject(id: UUID = UUID(), name: String = "Project") -> Project {
        Project(
            id: id,
            name: name,
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    func testSaveThenFetchByID() async throws {
        let repository = InMemoryProjectRepository()
        let project = Self.makeProject(id: TestFixtures.projectID)

        try await repository.save(project)
        let fetched = try await repository.project(id: TestFixtures.projectID)

        XCTAssertEqual(fetched, project)
    }

    func testFetchingUnknownIDReturnsNil() async throws {
        let repository = InMemoryProjectRepository()

        let fetched = try await repository.project(id: UUID())

        XCTAssertNil(fetched)
    }

    func testAllProjectsListsEveryStoredProject() async throws {
        let repository = InMemoryProjectRepository()
        let first = Self.makeProject(name: "First")
        let second = Self.makeProject(name: "Second")

        try await repository.save(first)
        try await repository.save(second)
        let all = try await repository.allProjects()

        XCTAssertEqual(Set(all.map(\.id)), Set([first.id, second.id]))
    }

    func testSavingSameIDUpdatesExistingProject() async throws {
        let repository = InMemoryProjectRepository()
        var project = Self.makeProject(id: TestFixtures.projectID, name: "Original")

        try await repository.save(project)
        project.name = "Renamed"
        try await repository.save(project)

        let all = try await repository.allProjects()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Renamed")
    }

    func testDeleteRemovesProject() async throws {
        let repository = InMemoryProjectRepository()
        let project = Self.makeProject(id: TestFixtures.projectID)

        try await repository.save(project)
        try await repository.delete(id: TestFixtures.projectID)
        let fetched = try await repository.project(id: TestFixtures.projectID)

        XCTAssertNil(fetched)
    }

    func testConcurrentSavesDoNotCorruptState() async throws {
        let repository = InMemoryProjectRepository()
        let projectIDs = (0..<50).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for id in projectIDs {
                group.addTask {
                    try? await repository.save(Self.makeProject(id: id))
                }
            }
        }

        let all = try await repository.allProjects()
        XCTAssertEqual(Set(all.map(\.id)), Set(projectIDs))
    }
}
