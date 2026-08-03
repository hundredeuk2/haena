import XCTest
@testable import HAENA

final class ProjectBrowserQueryServiceTests: XCTestCase {
    private func makeProject(
        id: UUID = UUID(),
        name: String = "Project",
        createdAt: Date,
        updatedAt: Date
    ) -> Project {
        Project(
            id: id,
            name: name,
            summary: "",
            createdAt: createdAt,
            updatedAt: updatedAt,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    private func makeMeeting(
        id: UUID = UUID(),
        occurredAt: Date,
        createdAt: Date
    ) -> Meeting {
        Meeting(
            id: id,
            projectID: TestFixtures.projectID,
            title: "Meeting",
            occurredAt: occurredAt,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [],
            createdAt: createdAt
        )
    }

    // MARK: - Project ordering

    func testProjectsSortedByUpdatedAtDescending() async throws {
        let repository = InMemoryProjectRepository()
        let older = makeProject(name: "Older", createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate)
        let newer = makeProject(name: "Newer", createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.laterDate)
        try await repository.save(older)
        try await repository.save(newer)

        let service = ProjectBrowserQueryService(repository: repository)
        let projects = try await service.loadProjects()

        XCTAssertEqual(projects.map(\.name), ["Newer", "Older"])
    }

    func testProjectsSortedDeterministicallyWhenUpdatedAtEqual() async throws {
        let repository = InMemoryProjectRepository()
        let older = makeProject(name: "OlderCreated", createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: TestFixtures.fixedDate)
        let newer = makeProject(name: "NewerCreated", createdAt: Date(timeIntervalSince1970: 2_000), updatedAt: TestFixtures.fixedDate)
        try await repository.save(older)
        try await repository.save(newer)

        let service = ProjectBrowserQueryService(repository: repository)
        let projects = try await service.loadProjects()

        XCTAssertEqual(projects.map(\.name), ["NewerCreated", "OlderCreated"])
    }

    func testProjectsSortedByUUIDStringWhenUpdatedAtAndCreatedAtEqual() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let projectA = makeProject(id: idA, name: "A", createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate)
        let projectB = makeProject(id: idB, name: "B", createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate)

        let sorted = [projectB, projectA].sorted(by: ProjectBrowserQueryService.isOrderedBefore)

        XCTAssertEqual(sorted.map(\.name), ["A", "B"])
    }

    func testLoadProjectsReturnsEmptyArrayWhenNoneStored() async throws {
        let service = ProjectBrowserQueryService(repository: InMemoryProjectRepository())

        let projects = try await service.loadProjects()

        XCTAssertEqual(projects, [])
    }

    func testLoadProjectsReflectsFreshRepositoryDataOnEachCall() async throws {
        let repository = InMemoryProjectRepository()
        let service = ProjectBrowserQueryService(repository: repository)

        let first = try await service.loadProjects()
        XCTAssertEqual(first, [])

        try await repository.save(makeProject(name: "New", createdAt: TestFixtures.fixedDate, updatedAt: TestFixtures.fixedDate))
        let second = try await service.loadProjects()

        XCTAssertEqual(second.map(\.name), ["New"])
    }

    // MARK: - Meeting ordering

    func testMeetingsSortedByOccurredAtDescending() {
        let older = makeMeeting(occurredAt: TestFixtures.fixedDate, createdAt: TestFixtures.fixedDate)
        let newer = makeMeeting(occurredAt: TestFixtures.laterDate, createdAt: TestFixtures.fixedDate)

        let sorted = ProjectBrowserQueryService.sortedMeetings([older, newer])

        XCTAssertEqual(sorted.map(\.id), [newer.id, older.id])
    }

    func testMeetingsSortedDeterministicallyWhenOccurredAtEqual() {
        let earlierCreated = makeMeeting(occurredAt: TestFixtures.fixedDate, createdAt: Date(timeIntervalSince1970: 1_000))
        let laterCreated = makeMeeting(occurredAt: TestFixtures.fixedDate, createdAt: Date(timeIntervalSince1970: 2_000))

        let sorted = ProjectBrowserQueryService.sortedMeetings([earlierCreated, laterCreated])

        XCTAssertEqual(sorted.map(\.id), [laterCreated.id, earlierCreated.id])
    }

    func testMeetingsSortedByUUIDStringWhenOccurredAtAndCreatedAtEqual() {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let meetingA = makeMeeting(id: idA, occurredAt: TestFixtures.fixedDate, createdAt: TestFixtures.fixedDate)
        let meetingB = makeMeeting(id: idB, occurredAt: TestFixtures.fixedDate, createdAt: TestFixtures.fixedDate)

        let sorted = ProjectBrowserQueryService.sortedMeetings([meetingB, meetingA])

        XCTAssertEqual(sorted.map(\.id), [idA, idB])
    }

    func testSortingEmptyMeetingsListReturnsEmpty() {
        XCTAssertEqual(ProjectBrowserQueryService.sortedMeetings([]), [])
    }
}
