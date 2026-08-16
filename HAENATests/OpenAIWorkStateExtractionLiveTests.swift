import XCTest
@testable import HAENA

/// The one test in this project that really calls OpenAI.
///
/// It is opt-in and skips by default, so a normal `xcodebuild test` run — and any CI — costs
/// nothing and touches no network. Every other extraction test drives a stub transport.
///
/// What it proves that mocks cannot: that the request this app actually builds is accepted by the
/// live Responses API, that a real model's Structured Output decodes into our DTOs, and that its
/// quotes survive evidence validation against the stored transcript.
///
/// ## Opting in
///
/// `HAENA_RUN_LIVE_OPENAI_TESTS=1` in the test process is the only opt-in signal. A credential may
/// then come from `OPENAI_API_KEY` or `~/.haena-openai-live-key`. The key file is never inspected
/// until the explicit flag has been accepted, and its existence alone never enables a live run.
///
/// Normal full test runs therefore skip even when a developer has left the local key file in place.
///
/// The transcript below is synthetic and deliberately unremarkable — no real meeting data may be
/// sent to a provider from a test.
final class OpenAIWorkStateExtractionLiveTests: XCTestCase {
    /// Deliberately outside the repository, so a credential can never be committed.
    private static let localKeyFileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".haena-openai-live-key")

    /// Environment first, then the local file. Returns nil — never a partial or placeholder value —
    /// when neither source holds a usable key.
    private static func resolvedAPIKey(environment: [String: String]) -> String? {
        if let key = OpenAIConfiguration.apiKey(from: environment) {
            return key
        }
        guard let contents = try? String(contentsOf: localKeyFileURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    // MARK: - Synthetic input

    /// Korean-first with one English line, and one unambiguous instance of each of the four kinds:
    /// a settled decision, a task with a named owner and a stated date, a question left open, and
    /// a topic explicitly pushed to the next meeting.
    private static let syntheticTranscript = """
    민준: 오늘은 결제 모듈 v2 출시 일정부터 정리하겠습니다.
    서연: 지난주 논의대로 3월 14일 출시가 가능합니다.
    민준: 그러면 결제 모듈 v2는 2026년 3월 14일에 출시하는 것으로 확정합니다.
    서연: API 문서 초안은 제가 2026년 3월 2일까지 작성해서 공유하겠습니다.
    지훈: 결제 실패 시 재시도를 몇 회까지 할지는 아직 정하지 못했습니다. 이 부분은 답을 찾지 못했습니다.
    민준: Let's revisit the retry policy next week.
    지훈: 그러면 재시도 정책 확정을 다음 회의 안건으로 올리겠습니다.
    민준: 좋습니다. 다음 회의 안건은 재시도 정책 확정으로 하겠습니다.
    """

    /// The only two dates stated anywhere in the transcript. A due date outside this set would mean
    /// the model invented one.
    private static let statedDates: Set<Date> = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return Set([
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 2)),
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 14))
        ].compactMap { $0 })
    }()

    private let projectID = UUID()
    private let meetingID = UUID()
    private let segmentID = UUID()

    private func syntheticMeeting() -> Meeting {
        let participants = [
            Participant(id: UUID(), displayName: "민준", linkedUserID: nil, speakerLabel: nil),
            Participant(id: UUID(), displayName: "서연", linkedUserID: nil, speakerLabel: nil),
            Participant(id: UUID(), displayName: "지훈", linkedUserID: nil, speakerLabel: nil)
        ]
        return Meeting(
            id: meetingID,
            projectID: projectID,
            title: "결제 모듈 v2 킥오프 (synthetic)",
            occurredAt: Date(timeIntervalSince1970: 1_770_000_000),
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: [
                TranscriptSegment(
                    id: segmentID,
                    meetingID: meetingID,
                    speakerID: nil,
                    text: Self.syntheticTranscript,
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    // MARK: - Live end-to-end check

    func testLiveExtractionProducesGroundedProposalsThatSurviveAReload() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard OpenAILiveTestGate.isExplicitlyEnabled(environment: environment) else {
            throw XCTSkip("""
            Live OpenAI check is opt-in (it makes a real, billed API call). Enable it with \
            HAENA_RUN_LIVE_OPENAI_TESTS=1 in the test process's environment.
            """)
        }
        // Credential lookup is intentionally below the explicit opt-in guard.
        guard let apiKey = Self.resolvedAPIKey(environment: environment) else {
            throw XCTSkip("No OpenAI credential found in the environment or ~/.haena-openai-live-key; skipping.")
        }
        guard OpenAILiveTestGate.evaluate(
            environment: environment,
            kind: .workStateExtraction,
            hasCredential: true
        ) == .allowed else {
            throw XCTSkip("Live OpenAI prerequisites are incomplete; skipping.")
        }

        let configuration = OpenAIConfiguration.fromEnvironment(environment)
        print("[live] provider=openai model=\(configuration.modelID)")

        // A throwaway store, so the live run cannot read or write the real Application Support data.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENALiveTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("projects.json")

        let meeting = syntheticMeeting()
        let repository = JSONProjectRepository(fileURL: fileURL)
        try await repository.save(
            Project(
                id: projectID,
                name: "Live Smoke Test (synthetic)",
                summary: "",
                createdAt: meeting.createdAt,
                updatedAt: meeting.createdAt,
                meetings: [meeting],
                decisions: [],
                actionItems: [],
                openQuestions: [],
                nextAgenda: []
            )
        )

        // The real adapter and the real service — the same types the app assembles in production.
        // Only the credential is injected, because the test may have resolved it from the local
        // key file; everything else (endpoint, schema, transport, mapping) is the production path.
        let service = WorkStateExtractionService(
            repository: repository,
            extractor: OpenAIWorkStateExtractor(
                configuration: configuration,
                apiKeyProvider: { apiKey }
            )
        )

        let report = try await service.extractAndApply(meetingID: meetingID, projectID: projectID)

        print("[live] stored decisions=\(report.storedDecisions) actionItems=\(report.storedActionItems) " +
              "openQuestions=\(report.storedOpenQuestions) agendaItems=\(report.storedAgendaItems) " +
              "rejected=\(report.rejected.count)")
        for rejection in report.rejected {
            print("[live] rejected: \(rejection.kind.rawValue) — \(rejection.reason.rawValue)")
        }

        XCTAssertEqual(report.metadata.provider, .openAI)
        XCTAssertEqual(report.metadata.modelID, configuration.modelID)

        // The transcript states one of each explicitly, so anything less is a real failure of the
        // prompt, the schema, or the model — not noise to be tolerated.
        XCTAssertGreaterThanOrEqual(report.storedDecisions, 1, "no grounded Decision was extracted")
        XCTAssertGreaterThanOrEqual(report.storedActionItems, 1, "no grounded ActionItem was extracted")
        XCTAssertGreaterThanOrEqual(report.storedOpenQuestions, 1, "no grounded OpenQuestion was extracted")
        XCTAssertGreaterThanOrEqual(report.storedAgendaItems, 1, "no grounded AgendaItem was extracted")

        // Reload through a second repository instance — the app-relaunch equivalent.
        let reloadedProject = try await JSONProjectRepository(fileURL: fileURL).project(id: projectID)
        let project = try XCTUnwrap(reloadedProject, "the project vanished from disk")

        XCTAssertEqual(project.decisions.count, report.storedDecisions)
        XCTAssertEqual(project.actionItems.count, report.storedActionItems)
        XCTAssertEqual(project.openQuestions.count, report.storedOpenQuestions)
        XCTAssertEqual(project.nextAgenda.count, report.storedAgendaItems)

        let transcriptText = try XCTUnwrap(project.meetings.first?.transcriptSegments.first?.text)
        XCTAssertEqual(transcriptText, Self.syntheticTranscript, "the stored transcript must be untouched")

        let participantIDs = Set(meeting.participants.map(\.id))

        for decision in project.decisions {
            XCTAssertEqual(decision.status, .proposed, "AI results must never be stored as confirmed")
            assertGrounded(decision.evidence, confidence: decision.confidence, in: transcriptText, label: "decision")
            print("[live] decision: \(summary(decision.statement)) (confidence \(decision.confidence.value))")
        }

        for item in project.actionItems {
            XCTAssertEqual(item.status, .proposed)
            assertGrounded(item.evidence, confidence: item.confidence, in: transcriptText, label: "actionItem")
            if let assigneeID = item.assigneeID {
                XCTAssertTrue(participantIDs.contains(assigneeID), "an assignee must be a participant of this meeting")
            }
            if let dueDate = item.dueDate {
                XCTAssertTrue(
                    Self.statedDates.contains(dueDate),
                    "a due date must be one the transcript actually states, not an inferred one"
                )
            }
            print("[live] actionItem: \(summary(item.title)) assignee=\(item.assigneeID == nil ? "nil" : "matched") " +
                  "due=\(item.dueDate == nil ? "nil" : "stated") (confidence \(item.confidence.value))")
        }

        for question in project.openQuestions {
            XCTAssertEqual(question.status, .open)
            assertGrounded(question.evidence, confidence: question.confidence, in: transcriptText, label: "openQuestion")
            print("[live] openQuestion: \(summary(question.question)) (confidence \(question.confidence.value))")
        }

        for item in project.nextAgenda {
            XCTAssertEqual(item.status, .pending)
            let confidence = try XCTUnwrap(item.confidence, "an extracted agenda item must carry a confidence")
            assertGrounded(item.evidence, confidence: confidence, in: transcriptText, label: "agendaItem")
            XCTAssertEqual(item.sourceMeetingID, meetingID)
            print("[live] agendaItem: \(summary(item.title)) (confidence \(confidence.value))")
        }
    }

    // MARK: - Helpers

    private func assertGrounded(
        _ evidence: EvidenceReference?,
        confidence: Confidence,
        in transcript: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let evidence else {
            XCTFail("\(label) was stored without evidence", file: file, line: line)
            return
        }
        XCTAssertEqual(evidence.meetingID, meetingID, file: file, line: line)
        XCTAssertEqual(evidence.transcriptSegmentID, segmentID, file: file, line: line)
        XCTAssertTrue(
            transcript.contains(evidence.quote),
            "\(label) evidence quote is not a verbatim substring of the stored transcript",
            file: file,
            line: line
        )
        XCTAssertTrue((0...1).contains(confidence.value), file: file, line: line)
    }

    /// Truncated so the log stays a summary. The content is synthetic, but a test log is still the
    /// wrong place to reproduce a whole transcript or response.
    private func summary(_ text: String) -> String {
        text.count <= 50 ? text : String(text.prefix(50)) + "…"
    }
}
