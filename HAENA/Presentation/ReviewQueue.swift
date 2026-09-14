import Foundation

enum ReviewQueueFilter: String, CaseIterable, Identifiable {
    case all, decisions, actions, questions, agenda
    var id: String { rawValue }
    var kind: WorkStateProposal.Kind? {
        switch self {
        case .all: nil
        case .decisions: .decision
        case .actions: .actionItem
        case .questions: .openQuestion
        case .agenda: .agendaItem
        }
    }
    var localizationKey: String {
        switch self {
        case .all: "review.filter.all"
        case .decisions: "review.filter.decisions"
        case .actions: "review.filter.actions"
        case .questions: "review.filter.questions"
        case .agenda: "review.filter.agenda"
        }
    }
}

/// Exact typed IDs keep different kinds distinct even if a legacy UUID is reused across kinds.
struct ReviewProposalIdentity: Hashable {
    let kind: WorkStateProposal.Kind
    let id: UUID
    init(_ proposal: WorkStateProposal) { kind = proposal.kind; id = proposal.id }
}

enum ReviewSourceIssue: String, Equatable {
    case noEvidence, noOwningMeeting, missingMeeting, differentMeeting, missingSegment
    var localizationKey: String {
        switch self {
        case .noEvidence: "저장된 원문 근거가 없습니다."
        case .noOwningMeeting: "소유 회의가 지정되지 않았습니다."
        case .missingMeeting: "소유 회의를 찾을 수 없습니다."
        case .differentMeeting: "근거와 소유 회의가 일치하지 않습니다."
        case .missingSegment: "인용문은 보존되어 있지만 원문 발화를 찾을 수 없습니다."
        }
    }
}

struct ReviewQueue: Equatable {
    struct Entry: Identifiable, Equatable {
        let proposal: WorkStateProposal
        let timestamp: String?
        let sourceIssue: ReviewSourceIssue?
        /// Set only when the owning meeting really stores the referenced segment. Built from the
        /// stored IDs alone; a missing, dangling or cross-meeting reference gets nil, never a
        /// nearest match. Independent of `timestamp`: a pasted transcript has no timing but its
        /// segment is still exactly addressable.
        let transcriptSelection: TranscriptEvidenceSelection?
        var id: ReviewProposalIdentity { ReviewProposalIdentity(proposal) }
        var canEdit: Bool { proposal.kind == .actionItem }
    }
    struct Group: Identifiable, Equatable {
        // nil is its own unassigned group; never retarget to the evidence's meeting.
        let id: UUID?
        let meeting: Meeting?
        let entries: [Entry]
        var pendingCount: Int { entries.count }
        func visible(_ filter: ReviewQueueFilter) -> [Entry] {
            entries.filter { filter.kind == nil || $0.proposal.kind == filter.kind }
        }
    }
    let groups: [Group]
    var pendingCount: Int { groups.reduce(0) { $0 + $1.pendingCount } }
    func count(_ filter: ReviewQueueFilter) -> Int { groups.reduce(0) { $0 + $1.visible(filter).count } }

    init(project: Project) {
        let proposals = WorkStateInbox.pendingProposals(in: project)
        let grouped = Dictionary(grouping: proposals, by: \.meetingID)
        groups = grouped.map { meetingID, proposals in
            let meeting = project.meetings.first { $0.id == meetingID }
            let entries = proposals.sorted(by: WorkStateInbox.isOrderedBefore).map { proposal in
                let issue: ReviewSourceIssue?
                if proposal.meetingID == nil { issue = .noOwningMeeting }
                else if meeting == nil { issue = .missingMeeting }
                else if proposal.evidence == nil { issue = .noEvidence }
                else if proposal.evidence?.meetingID != meetingID { issue = .differentMeeting }
                else if !meeting!.transcriptSegments.contains(where: { $0.id == proposal.evidence?.transcriptSegmentID }) {
                    issue = .missingSegment
                } else { issue = nil }
                let selection = issue == nil ? proposal.evidence.map {
                    TranscriptEvidenceSelection(meetingID: $0.meetingID, segmentID: $0.transcriptSegmentID)
                } : nil
                return Entry(proposal: proposal,
                    timestamp: issue == nil ? meeting.flatMap { MeetingWorkStateSummary.evidenceTimestamp(proposal.evidence, in: $0) } : nil,
                    sourceIssue: issue, transcriptSelection: selection)
            }
            return Group(id: meetingID, meeting: meeting, entries: entries)
        }.sorted {
            // Known meetings newest first; dangling and unassigned groups remain visible last.
            let left = $0.meeting?.occurredAt ?? .distantPast
            let right = $1.meeting?.occurredAt ?? .distantPast
            if left != right { return left > right }
            return ($0.id?.uuidString ?? "~") < ($1.id?.uuidString ?? "~")
        }
    }
}
