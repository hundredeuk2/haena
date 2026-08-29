import XCTest
@testable import HAENA

/// Adds a second, test-owned boundary around the production ephemeral transport. Validation runs
/// before the only forwarded request, and a second invocation is rejected even if retry settings
/// regress later.
private actor AuthorizedSingleAttemptTransport: HTTPTransport {
    private let underlying: any HTTPTransport
    private let allowedSegmentIDs: Set<String>
    private let forbiddenStrings: [String]
    private var invocationCount = 0
    private(set) var forwardedAttemptCount = 0

    init(
        underlying: any HTTPTransport,
        allowedSegmentIDs: Set<UUID>,
        forbiddenStrings: [String]
    ) {
        self.underlying = underlying
        self.allowedSegmentIDs = Set(allowedSegmentIDs.map { $0.uuidString.uppercased() })
        self.forbiddenStrings = forbiddenStrings.filter { !$0.isEmpty }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard invocationCount == 0 else {
            throw WorkStateExtractionError.invalidConfiguration
        }
        invocationCount += 1
        try validate(request)
        forwardedAttemptCount += 1
        return try await underlying.send(request)
    }

    private func validate(_ request: URLRequest) throws {
        guard request.url == OpenAIConfiguration.defaultEndpoint,
              request.httpMethod == "POST",
              let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["model"] as? String == "gpt-5.6",
              json["store"] as? Bool == false,
              let messages = json["input"] as? [[String: Any]],
              let userContent = messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String else {
            throw WorkStateExtractionError.invalidConfiguration
        }

        for forbidden in forbiddenStrings where body.range(of: Data(forbidden.utf8)) != nil {
            throw WorkStateExtractionError.invalidConfiguration
        }
        guard !userContent.contains("input_audio") else {
            throw WorkStateExtractionError.invalidConfiguration
        }

        let expression = try NSRegularExpression(
            pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        )
        let range = NSRange(userContent.startIndex..<userContent.endIndex, in: userContent)
        let transmittedUUIDs = Set(expression.matches(in: userContent, range: range).compactMap { match in
            Range(match.range, in: userContent).map { String(userContent[$0]).uppercased() }
        })
        guard transmittedUUIDs.isSubset(of: allowedSegmentIDs),
              allowedSegmentIDs.isSubset(of: transmittedUUIDs) else {
            throw WorkStateExtractionError.invalidConfiguration
        }
    }
}

/// The authorized call does not include the stored meeting title. IDs remain available to the
/// local service and mapper but are not serialized by the provider adapter.
private struct TitleRedactingWorkStateExtractor: WorkStateExtractor {
    let underlying: OpenAIWorkStateExtractor

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        try await underlying.extract(
            from: WorkStateExtractionInput(
                meetingID: input.meetingID,
                projectID: input.projectID,
                meetingTitle: "",
                occurredAt: input.occurredAt,
                excerpts: input.excerpts,
                priorWorkStates: input.priorWorkStates
            )
        )
    }
}

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
    private struct AuthorizedAttributionReport: Codable {
        let actionItemID: UUID
        let evidenceSegmentID: UUID?
        let assigneeID: UUID?
        let basis: String?
        let speakerLabel: String?
        let resolution: String?
        let status: String
    }

    private struct AuthorizedLiveReport: Codable {
        let outcome: String
        let errorCategory: String?
        let httpAttempts: Int
        let projectID: UUID
        let meetingID: UUID
        let beforeMeetingCount: Int
        let afterMeetingCount: Int
        let beforeActionItemCount: Int
        let afterActionItemCount: Int
        let newActionItemIDs: [UUID]
        let storedDecisionCount: Int
        let storedActionItemCount: Int
        let storedOpenQuestionCount: Int
        let storedAgendaItemCount: Int
        let rejectedProposalCount: Int
        let replacedProposalCount: Int
        let approvedStateUnchanged: Bool
        let relaunchPreserved: Bool
        let attributions: [AuthorizedAttributionReport]
    }

    private static let authorizedReportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("haena-pasted-speaker-linking-openai-report.json")

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
                credentialProvider: { .resolved(apiKey) }
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

    /// One explicitly authorized real-project validation. It is separately gated from the generic
    /// synthetic smoke test and accepts target identities only through the invoking process.
    /// Neither request nor response payloads are logged or written to disk.
    func testAuthorizedPastedSpeakerAttributionUsesOnePrivacyGuardedRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard OpenAILiveTestGate.isExplicitlyEnabled(environment: environment) else {
            throw XCTSkip("Authorized pasted-speaker live validation is opt-in.")
        }
        guard let projectID = environment["HAENA_AUTHORIZED_PROJECT_ID"].flatMap(UUID.init(uuidString:)),
              let meetingID = environment["HAENA_AUTHORIZED_MEETING_ID"].flatMap(UUID.init(uuidString:)),
              let expectedProjectName = environment["HAENA_AUTHORIZED_PROJECT_NAME"],
              let segmentAID = environment["HAENA_AUTHORIZED_SEGMENT_A_ID"].flatMap(UUID.init(uuidString:)),
              let segmentBID = environment["HAENA_AUTHORIZED_SEGMENT_B_ID"].flatMap(UUID.init(uuidString:)),
              let segmentCID = environment["HAENA_AUTHORIZED_SEGMENT_C_ID"].flatMap(UUID.init(uuidString:)),
              let commitmentText = environment["HAENA_AUTHORIZED_SEGMENT_B_COMMITMENT_TEXT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commitmentText.isEmpty,
              environment["HAENA_AUTHORIZED_LIVE_ACK"] == "\(projectID.uuidString)/\(meetingID.uuidString)/gpt-5.6/ONE_ATTEMPT" else {
            XCTFail("Exact authorized project, meeting, segments, model, and one-attempt acknowledgement are required.")
            return
        }
        guard let apiKey = Self.resolvedAPIKey(environment: environment) else {
            throw XCTSkip("No OpenAI credential is available after explicit opt-in.")
        }

        let repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
        let loadedBefore = try await repository.project(id: projectID)
        var before = try XCTUnwrap(loadedBefore)
        guard before.name == expectedProjectName,
              let meetingIndex = before.meetings.firstIndex(where: { $0.id == meetingID }) else {
            XCTFail("The authorized project or meeting did not match local storage.")
            return
        }

        let authorizedSegments = ["A": segmentAID, "B": segmentBID, "C": segmentCID]
        let storedIDsByLabel = Dictionary(
            uniqueKeysWithValues: before.meetings[meetingIndex].transcriptSegments.compactMap { segment in
                segment.sourceSpeakerLabel.map { ($0, segment.id) }
            }
        )
        guard storedIDsByLabel == authorizedSegments else {
            XCTFail("The stored A/B/C segment identities did not match the authorization.")
            return
        }

        // Make B a true omitted-subject speaker commitment without changing its identity or link.
        if let segmentIndex = before.meetings[meetingIndex].transcriptSegments.firstIndex(where: { $0.id == segmentBID }),
           before.meetings[meetingIndex].transcriptSegments[segmentIndex].text != commitmentText {
            before.meetings[meetingIndex].transcriptSegments[segmentIndex].text = commitmentText
            try await repository.save(before)
            let reloadedBefore = try await JSONProjectRepository(
                fileURL: JSONProjectRepository.defaultFileURL()
            ).project(id: projectID)
            before = try XCTUnwrap(reloadedBefore)
        }

        let meeting = try XCTUnwrap(before.meetings.first(where: { $0.id == meetingID }))
        let segmentsByLabel = Dictionary(
            uniqueKeysWithValues: meeting.transcriptSegments.compactMap { segment in
                segment.sourceSpeakerLabel.map { ($0, segment) }
            }
        )
        XCTAssertNotNil(segmentsByLabel["A"]?.speakerID)
        XCTAssertNotNil(segmentsByLabel["B"]?.speakerID)
        XCTAssertNil(segmentsByLabel["C"]?.speakerID)

        let beforeApproved = ApprovedWorkStateSnapshot(project: before)
        let beforeMeetingCount = before.meetings.count
        let beforeActionIDs = Set(before.actionItems.map(\.id))
        let beforeActionCount = before.actionItems.count
        XCTAssertTrue(before.actionItems.filter { $0.meetingID == meetingID }.isEmpty)

        let guardedTransport = AuthorizedSingleAttemptTransport(
            underlying: URLSessionHTTPTransport(requestTimeout: 60),
            allowedSegmentIDs: Set(authorizedSegments.values),
            forbiddenStrings: [before.name, meeting.title]
                + meeting.participants.flatMap { [$0.displayName, $0.id.uuidString] }
                + [projectID.uuidString, meetingID.uuidString]
                + before.decisions.map { $0.id.uuidString }
                + before.actionItems.map { $0.id.uuidString }
                + before.openQuestions.map { $0.id.uuidString }
                + before.nextAgenda.map { $0.id.uuidString }
        )
        let configuration = OpenAIConfiguration(
            modelID: "gpt-5.6",
            requestTimeout: 60,
            maxRetries: 0,
            retryDelay: 0
        )
        let extractor = TitleRedactingWorkStateExtractor(
            underlying: OpenAIWorkStateExtractor(
                configuration: configuration,
                credentialProvider: { .resolved(apiKey) },
                transport: guardedTransport
            )
        )
        let service = WorkStateExtractionService(repository: repository, extractor: extractor)

        let extractionReport: WorkStateExtractionReport
        do {
            extractionReport = try await service.extractAndApply(meetingID: meetingID, projectID: projectID)
        } catch {
            let attempts = await guardedTransport.forwardedAttemptCount
            let afterFailure = try? await JSONProjectRepository(
                fileURL: JSONProjectRepository.defaultFileURL()
            ).project(id: projectID)
            try writeAuthorizedReport(
                AuthorizedLiveReport(
                    outcome: "failed",
                    errorCategory: finiteErrorCategory(error),
                    httpAttempts: attempts,
                    projectID: projectID,
                    meetingID: meetingID,
                    beforeMeetingCount: beforeMeetingCount,
                    afterMeetingCount: afterFailure?.meetings.count ?? beforeMeetingCount,
                    beforeActionItemCount: beforeActionCount,
                    afterActionItemCount: afterFailure?.actionItems.count ?? beforeActionCount,
                    newActionItemIDs: [],
                    storedDecisionCount: 0,
                    storedActionItemCount: 0,
                    storedOpenQuestionCount: 0,
                    storedAgendaItemCount: 0,
                    rejectedProposalCount: 0,
                    replacedProposalCount: 0,
                    approvedStateUnchanged: afterFailure.map {
                        ApprovedWorkStateSnapshot(project: $0) == beforeApproved
                    } ?? false,
                    relaunchPreserved: false,
                    attributions: []
                )
            )
            throw error
        }

        let loadedAfter = try await JSONProjectRepository(
            fileURL: JSONProjectRepository.defaultFileURL()
        ).project(id: projectID)
        let after = try XCTUnwrap(loadedAfter)
        let newActions = after.actionItems
            .filter { !beforeActionIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let attributions = newActions.map { item in
            AuthorizedAttributionReport(
                actionItemID: item.id,
                evidenceSegmentID: item.evidence?.transcriptSegmentID,
                assigneeID: item.assigneeID,
                basis: item.proposedAssigneeAttribution?.basis.rawValue,
                speakerLabel: item.proposedAssigneeAttribution?.speakerLabel,
                resolution: item.proposedAssigneeAttribution?.resolution.rawValue,
                status: item.status.rawValue
            )
        }
        let actionsBySegment = Dictionary(grouping: newActions) { $0.evidence?.transcriptSegmentID }
        let actionA = try XCTUnwrap(actionsBySegment[segmentAID]?.only)
        let actionB = try XCTUnwrap(actionsBySegment[segmentBID]?.only)
        let actionC = try XCTUnwrap(actionsBySegment[segmentCID]?.only)

        let forwardedAttemptCount = await guardedTransport.forwardedAttemptCount
        XCTAssertEqual(forwardedAttemptCount, 1)
        XCTAssertEqual(extractionReport.replacedProposals, 0)
        XCTAssertEqual(extractionReport.storedActionItems, 3)
        XCTAssertEqual(extractionReport.storedDecisions, 0)
        XCTAssertEqual(extractionReport.storedOpenQuestions, 0)
        XCTAssertEqual(extractionReport.storedAgendaItems, 0)
        XCTAssertEqual(after.meetings.count, beforeMeetingCount)
        XCTAssertEqual(after.actionItems.count, beforeActionCount + 3)
        XCTAssertEqual(Set(newActions.map(\.id)).count, newActions.count)
        XCTAssertEqual(Set(newActions.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }).count, newActions.count)
        XCTAssertTrue(newActions.allSatisfy { $0.status == .proposed && PendingAIProposalPolicy.isPending($0) })

        XCTAssertEqual(actionA.assigneeID, segmentsByLabel["A"]?.speakerID)
        XCTAssertEqual(actionA.proposedAssigneeAttribution?.basis, .selfReference)
        XCTAssertEqual(actionA.proposedAssigneeAttribution?.speakerLabel, "A")
        XCTAssertEqual(actionA.proposedAssigneeAttribution?.resolution, .resolved)

        XCTAssertEqual(actionB.assigneeID, segmentsByLabel["B"]?.speakerID)
        XCTAssertEqual(actionB.proposedAssigneeAttribution?.basis, .speakerCommitment)
        XCTAssertEqual(actionB.proposedAssigneeAttribution?.speakerLabel, "B")
        XCTAssertEqual(actionB.proposedAssigneeAttribution?.resolution, .resolved)

        XCTAssertNil(actionC.assigneeID)
        XCTAssertNotEqual(actionC.proposedAssigneeAttribution?.resolution, .resolved)
        XCTAssertEqual(actionC.proposedAssigneeAttribution?.speakerLabel, nil)

        let approvedStateUnchanged = ApprovedWorkStateSnapshot(project: after) == beforeApproved
        XCTAssertTrue(approvedStateUnchanged)

        let loadedRelaunched = try await JSONProjectRepository(
            fileURL: JSONProjectRepository.defaultFileURL()
        ).project(id: projectID)
        let relaunched = try XCTUnwrap(loadedRelaunched)
        let relaunchedMeeting = try XCTUnwrap(relaunched.meetings.first(where: { $0.id == meetingID }))
        let relaunchPreserved = relaunchedMeeting == meeting
            && Set(relaunched.actionItems.filter { !beforeActionIDs.contains($0.id) }.map(\.id)) == Set(newActions.map(\.id))
        XCTAssertTrue(relaunchPreserved)

        try writeAuthorizedReport(
            AuthorizedLiveReport(
                outcome: "completed",
                errorCategory: nil,
                httpAttempts: forwardedAttemptCount,
                projectID: projectID,
                meetingID: meetingID,
                beforeMeetingCount: beforeMeetingCount,
                afterMeetingCount: after.meetings.count,
                beforeActionItemCount: beforeActionCount,
                afterActionItemCount: after.actionItems.count,
                newActionItemIDs: newActions.map(\.id),
                storedDecisionCount: extractionReport.storedDecisions,
                storedActionItemCount: extractionReport.storedActionItems,
                storedOpenQuestionCount: extractionReport.storedOpenQuestions,
                storedAgendaItemCount: extractionReport.storedAgendaItems,
                rejectedProposalCount: extractionReport.rejected.count,
                replacedProposalCount: extractionReport.replacedProposals,
                approvedStateUnchanged: approvedStateUnchanged,
                relaunchPreserved: relaunchPreserved,
                attributions: attributions
            )
        )
        print("[authorized-live] report=\(Self.authorizedReportURL.path)")
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

    private func writeAuthorizedReport(_ report: AuthorizedLiveReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: Self.authorizedReportURL, options: .atomic)
    }

    private func finiteErrorCategory(_ error: Error) -> String {
        switch error {
        case WorkStateExtractionError.missingCredential: "missing_credential"
        case WorkStateExtractionError.invalidConfiguration: "invalid_configuration"
        case WorkStateExtractionError.unauthorized: "unauthorized"
        case WorkStateExtractionError.rateLimited: "rate_limited"
        case WorkStateExtractionError.serverError: "server_error"
        case WorkStateExtractionError.requestRejected: "request_rejected"
        case WorkStateExtractionError.timedOut: "timed_out"
        case WorkStateExtractionError.networkUnavailable: "network_unavailable"
        case WorkStateExtractionError.refused: "refused"
        case WorkStateExtractionError.emptyResponse: "empty_response"
        case WorkStateExtractionError.malformedResponse: "malformed_response"
        case WorkStateExtractionServiceError.projectNotFound: "project_not_found"
        case WorkStateExtractionServiceError.meetingNotFound: "meeting_not_found"
        case WorkStateExtractionServiceError.repositoryFailure: "repository_failure"
        default: "unexpected_error"
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
