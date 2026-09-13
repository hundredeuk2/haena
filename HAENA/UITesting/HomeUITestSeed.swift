#if DEBUG
import Foundation

/// Fixed scenario selection in the existing in-memory UI assembly. No payload/path from env.
struct HomeUITestSeed {
    enum Scenario: String, CaseIterable {
        case empty, pendingReview, assignedWork, noProfile, loadFailure, resume
    }
    let scenario: Scenario
    let projects: [Project]
    let profile: LocalUserProfile?

    static func select(environment: [String: String]) -> Self? {
        guard environment["HAENA_UI_TESTING"] == "1",
              let raw = environment["HAENA_UI_TEST_HOME"],
              let scenario = Scenario(rawValue: raw) else { return nil }
        return make(scenario)
    }

    static func make(_ scenario: Scenario) -> Self {
        let date = Date(timeIntervalSince1970: 1_786_358_400)
        func id(_ suffix: Int) -> UUID {
            UUID(uuidString: String(format: "CA000000-0000-4000-8000-%012d", suffix))!
        }
        let participant = Participant(id: id(3), displayName: "Synthetic Participant",
                                      linkedUserID: nil, speakerLabel: "A")
        let segment = TranscriptSegment(id: id(4), meetingID: id(2), speakerID: participant.id,
                                        sourceSpeakerLabel: "A", text: "Synthetic follow-up evidence.",
                                        startTime: nil, endTime: nil)
        let meeting = Meeting(id: id(2), projectID: id(1), title: "Synthetic Resume Meeting",
                              occurredAt: date, sourceType: .pastedText, participants: [participant],
                              transcriptSegments: [segment], createdAt: date)
        let pending = scenario == .pendingReview || scenario == .resume
        let action = ActionItem(id: id(5), projectID: id(1), meetingID: meeting.id,
                                title: "Synthetic assigned follow-up", assigneeID: participant.id,
                                dueDate: nil, status: pending ? .proposed : .confirmed,
                                evidence: EvidenceReference(meetingID: meeting.id,
                                                            transcriptSegmentID: segment.id, quote: segment.text),
                                confidence: .maximum, createdAt: date, updatedAt: date)
        let project = Project(id: id(1), name: "Synthetic Home Project", summary: "",
                              createdAt: date, updatedAt: date, meetings: [meeting], decisions: [],
                              actionItems: [action], openQuestions: [], nextAgenda: [])
        let profile = LocalUserProfile(id: id(6), displayName: participant.displayName,
                                       linkedParticipantIDs: [participant.id], createdAt: date, updatedAt: date)
        return Self(scenario: scenario, projects: scenario == .empty ? [] : [project],
                    profile: scenario == .noProfile || scenario == .empty ? nil : profile)
    }
}

/// Deliberately failing repository, selected only by the fixed Debug UI scenario above.
/// An honest read failure reaches Home's existing error/retry path, never a fake loaded screen.
actor HomeLoadFailureUITestRepository: WorkStateTransitionProjectRepository {
    enum Failure: Error { case syntheticReadFailure }
    func allProjects() throws -> [Project] { throw Failure.syntheticReadFailure }
    func project(id: UUID) throws -> Project? { throw Failure.syntheticReadFailure }
    func save(_ project: Project) throws { throw Failure.syntheticReadFailure }
    func delete(id: UUID) throws { throw Failure.syntheticReadFailure }
    func save(_ project: Project, recording marker: WorkStateTransitionApplyMarker) throws {
        throw Failure.syntheticReadFailure
    }
    func transitionApplyMarker(projectID: UUID, operationID: UUID,
                               operationKind: WorkStateTransitionApplyOperationKind) -> WorkStateTransitionApplyMarker? { nil }
}
#endif
