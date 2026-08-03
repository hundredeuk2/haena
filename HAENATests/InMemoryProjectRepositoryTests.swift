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

    func testSaveThenFetchByID() async {
        let repository = InMemoryProjectRepository()
        let project = Self.makeProject(id: TestFixtures.projectID)

        await repository.save(project)
        let fetched = await repository.project(id: TestFixtures.projectID)

        XCTAssertEqual(fetched, project)
    }

    func testFetchingUnknownIDReturnsNil() async {
        let repository = InMemoryProjectRepository()

        let fetched = await repository.project(id: UUID())

        XCTAssertNil(fetched)
    }

    func testAllProjectsListsEveryStoredProject() async {
        let repository = InMemoryProjectRepository()
        let first = Self.makeProject(name: "First")
        let second = Self.makeProject(name: "Second")

        await repository.save(first)
        await repository.save(second)
        let all = await repository.allProjects()

        XCTAssertEqual(Set(all.map(\.id)), Set([first.id, second.id]))
    }

    func testSavingSameIDUpdatesExistingProject() async {
        let repository = InMemoryProjectRepository()
        var project = Self.makeProject(id: TestFixtures.projectID, name: "Original")

        await repository.save(project)
        project.name = "Renamed"
        await repository.save(project)

        let all = await repository.allProjects()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Renamed")
    }

    func testDeleteRemovesProject() async {
        let repository = InMemoryProjectRepository()
        let project = Self.makeProject(id: TestFixtures.projectID)

        await repository.save(project)
        await repository.delete(id: TestFixtures.projectID)
        let fetched = await repository.project(id: TestFixtures.projectID)

        XCTAssertNil(fetched)
    }

    func testConcurrentSavesDoNotCorruptState() async {
        let repository = InMemoryProjectRepository()
        let projectIDs = (0..<50).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for id in projectIDs {
                group.addTask {
                    await repository.save(Self.makeProject(id: id))
                }
            }
        }

        let all = await repository.allProjects()
        XCTAssertEqual(Set(all.map(\.id)), Set(projectIDs))
    }
}
