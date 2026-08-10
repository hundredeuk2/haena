import Foundation

/// Creates the smallest complete local dataset needed to exercise the reminder Agent Flow.
///
/// This is an explicit Private-beta validation aid, never an automatic seed. Existing projects
/// and profile choices are preserved; only the stable sample project is created or reset so the
/// button is safe to press again after completing the sample task.
struct ActionItemReminderSampleService: Sendable {
    struct Result: Equatable, Sendable {
        let projectID: UUID
        let meetingID: UUID
        let actionItemID: UUID
    }

    static let projectID = UUID(uuidString: "A6000000-0000-4000-8000-000000000001")!
    static let meetingID = UUID(uuidString: "A6000000-0000-4000-8000-000000000002")!
    static let participantID = UUID(uuidString: "A6000000-0000-4000-8000-000000000003")!
    static let segmentID = UUID(uuidString: "A6000000-0000-4000-8000-000000000004")!
    static let actionItemID = UUID(uuidString: "A6000000-0000-4000-8000-000000000005")!

    let projectRepository: any ProjectRepository
    let profileRepository: any LocalUserProfileRepository
    let calendar: Calendar
    let now: @Sendable () -> Date

    init(
        projectRepository: any ProjectRepository,
        profileRepository: any LocalUserProfileRepository,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projectRepository = projectRepository
        self.profileRepository = profileRepository
        self.calendar = calendar
        self.now = now
    }

    func createOrReset() async throws -> Result {
        let timestamp = now()
        let dueDate = sampleDueDate(after: timestamp)
        let participant = Participant(
            id: Self.participantID,
            displayName: "나 (알림 검증)",
            linkedUserID: nil,
            speakerLabel: "Speaker 1"
        )
        let segment = TranscriptSegment(
            id: Self.segmentID,
            meetingID: Self.meetingID,
            speakerID: Self.participantID,
            text: "확정된 내 업무의 로컬 알림 흐름을 검증하고 결과를 기록합니다.",
            startTime: nil,
            endTime: nil
        )
        let meeting = Meeting(
            id: Self.meetingID,
            projectID: Self.projectID,
            title: "Agent Flow 알림 검증 회의",
            occurredAt: timestamp.addingTimeInterval(-3_600),
            sourceType: .pastedText,
            participants: [participant],
            transcriptSegments: [segment],
            createdAt: timestamp
        )
        let evidence = EvidenceReference(
            meetingID: Self.meetingID,
            transcriptSegmentID: Self.segmentID,
            quote: segment.text
        )
        let actionItem = ActionItem(
            id: Self.actionItemID,
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            title: "Private 0.2.0 로컬 알림 수신 확인",
            details: "알림을 2분 뒤로 예약하고, 재실행 유지와 완료 시 자동 취소를 확인합니다.",
            assigneeID: Self.participantID,
            dueDate: dueDate,
            status: .confirmed,
            evidence: evidence,
            confidence: .maximum,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        var project = try await projectRepository.project(id: Self.projectID) ?? Project(
            id: Self.projectID,
            name: "HAE.NA Agent Flow 검증 샘플",
            summary: "Private 0.2.0의 로컬 알림 예약·유지·자동 취소를 검증하는 샘플입니다.",
            createdAt: timestamp,
            updatedAt: timestamp,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        replaceOrAppend(meeting, in: &project.meetings)
        replaceOrAppend(actionItem, in: &project.actionItems)
        project.updatedAt = timestamp

        var profile = try await profileRepository.profile() ?? LocalUserProfile(
            displayName: "나",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        profile.link([Self.participantID], at: timestamp)

        // Save the identity link first. If the project write then fails, no invented task appears;
        // the extra linked sample participant is harmless and the next press can finish the seed.
        try await profileRepository.save(profile)
        try await projectRepository.save(project)

        return Result(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            actionItemID: Self.actionItemID
        )
    }

    private func sampleDueDate(after reference: Date) -> Date {
        let start = calendar.startOfDay(for: reference)
        let day = calendar.date(byAdding: .day, value: 2, to: start)
            ?? reference.addingTimeInterval(2 * 86_400)
        return calendar.date(byAdding: .hour, value: 18, to: day)
            ?? reference.addingTimeInterval(2 * 86_400)
    }

    private func replaceOrAppend<Value: Identifiable>(_ value: Value, in values: inout [Value])
    where Value.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }
}
