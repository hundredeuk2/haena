import Foundation
@testable import HAENA

/// Returns a canned result (or throws a canned error) without touching a network, so service-level
/// tests can exercise every branch of the extraction flow deterministically.
struct StubWorkStateExtractor: WorkStateExtractor {
    enum Outcome: Sendable {
        case success(WorkStateExtractionResult)
        case failure(WorkStateExtractionError)
    }

    let outcome: Outcome

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

/// A `StubWorkStateExtractor` that counts its calls and keeps what it was handed.
///
/// An `actor` because re-analysis tests deliberately overlap two runs, and "how many times did the
/// provider get called" is the whole assertion. `delay` holds a run open long enough for a second
/// one to arrive while the first is still in flight — the only way to test a mutual exclusion is
/// to actually contend for it.
actor CountingWorkStateExtractor: WorkStateExtractor {
    private let outcome: StubWorkStateExtractor.Outcome
    private let delay: Duration
    private(set) var callCount = 0
    private(set) var receivedInputs: [WorkStateExtractionInput] = []

    init(_ outcome: StubWorkStateExtractor.Outcome, delay: Duration = .zero) {
        self.outcome = outcome
        self.delay = delay
    }

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        callCount += 1
        receivedInputs.append(input)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

/// Feeds pre-baked HTTP outcomes to the OpenAI adapter and records what it sent, so retry counts
/// and request construction can be asserted without a real request ever leaving the machine.
///
/// An `actor` because the adapter may call it several times across suspension points, and the
/// tests read the recorded requests afterwards.
actor RecordingHTTPTransport: HTTPTransport {
    enum Outcome: Sendable {
        case status(Int, body: Data)
        case failure(URLError)
    }

    private var remaining: [Outcome]
    private let endlessRepeat: Bool
    private(set) var sentRequests: [URLRequest] = []

    /// - Parameter repeatLast: when true the final outcome is reused for any further attempts,
    ///   which is what a persistently failing endpoint looks like.
    init(_ outcomes: [Outcome], repeatLast: Bool = true) {
        remaining = outcomes
        endlessRepeat = repeatLast
    }

    var attemptCount: Int {
        sentRequests.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sentRequests.append(request)

        let outcome: Outcome
        if remaining.count > 1 || !endlessRepeat {
            outcome = remaining.isEmpty ? .status(500, body: Data()) : remaining.removeFirst()
        } else {
            outcome = remaining.first ?? .status(500, body: Data())
        }

        switch outcome {
        case .failure(let error):
            throw error
        case .status(let code, let body):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
    }
}

/// Shared builders for extraction tests.
enum ExtractionFixtures {
    static let transcript = "우리는 2월 출시로 가기로 했습니다. 지표 정의는 아직 정하지 못했습니다."

    static func meeting(
        id: UUID = TestFixtures.meetingID,
        projectID: UUID = TestFixtures.projectID,
        segmentID: UUID = TestFixtures.segmentID,
        text: String = ExtractionFixtures.transcript,
        participants: [Participant] = []
    ) -> Meeting {
        Meeting(
            id: id,
            projectID: projectID,
            title: "Kickoff",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: participants,
            transcriptSegments: [
                TranscriptSegment(
                    id: segmentID,
                    meetingID: id,
                    speakerID: participants.first?.id,
                    sourceSpeakerLabel: participants.first?.speakerLabel,
                    text: text,
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )
    }

    static func project(with meetings: [Meeting], id: UUID = TestFixtures.projectID) -> Project {
        Project(
            id: id,
            name: "HAE.NA",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: meetings,
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
    }

    static let metadata = ModelRunMetadata(
        provider: .openAI,
        modelID: "test-model",
        completedAt: TestFixtures.fixedDate
    )

    static func evidence(
        segmentID: UUID = TestFixtures.segmentID,
        quote: String = "2월 출시로 가기로 했습니다"
    ) -> ProposedEvidence {
        ProposedEvidence(segmentID: segmentID.uuidString, quote: quote)
    }

    /// One verifiable proposal of each of the four kinds.
    static func fullResult(
        confidence: Double = 0.8,
        evidence: ProposedEvidence = ExtractionFixtures.evidence(),
        assigneeAttribution: ProposedAssigneeAttribution = ProposedAssigneeAttribution(
            basis: .unspecified,
            reference: nil,
            speakerLabel: nil
        ),
        dueDate: Date? = nil
    ) -> WorkStateExtractionResult {
        WorkStateExtractionResult(
            decisions: [
                ProposedDecision(
                    providerLocalKey: "decision_1",
                    statement: "2월 출시로 진행한다",
                    rationale: nil,
                    confidence: confidence,
                    evidence: evidence
                )
            ],
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "지표 정의 초안 작성",
                    details: nil,
                    assigneeAttribution: assigneeAttribution,
                    dueDate: dueDate,
                    confidence: confidence,
                    evidence: evidence
                )
            ],
            openQuestions: [
                ProposedOpenQuestion(
                    providerLocalKey: "question_1",
                    question: "지표 정의는 누가 확정하는가?",
                    confidence: confidence,
                    evidence: evidence
                )
            ],
            nextAgendaItems: [
                ProposedAgendaItem(
                    providerLocalKey: "agenda_1",
                    title: "지표 정의 확정",
                    reason: "이번 회의에서 결론이 나지 않음",
                    confidence: confidence,
                    evidence: evidence
                )
            ],
            metadata: metadata
        )
    }

    static func emptyResult() -> WorkStateExtractionResult {
        WorkStateExtractionResult(metadata: metadata)
    }
}
