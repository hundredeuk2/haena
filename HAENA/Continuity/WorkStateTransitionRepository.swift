import CryptoKit
import Foundation

/// User-owned review state is stored separately from the engine-owned proposal payload.
struct WorkStateTransitionReviewState: Codable, Equatable, Sendable {
    let dedupKey: String
    let status: WorkStateTransitionReviewStatus
}

enum WorkStateTransitionTerminalVerdict: String, Codable, Equatable, Sendable, CaseIterable {
    case approved
    case rejected

    var reviewStatus: WorkStateTransitionReviewStatus {
        switch self {
        case .approved: return .approved
        case .rejected: return .rejected
        }
    }
}

enum WorkStateTransitionReviewWriteRefusalReason: String, Codable, Equatable, Sendable {
    case unknownProposal = "unknown_proposal"
    case unknownAmbiguityGroup = "unknown_ambiguity_group"
    case projectMismatch = "project_mismatch"
    case terminalVerdictConflict = "terminal_verdict_conflict"
    case invalidAmbiguitySelection = "invalid_ambiguity_selection"
    case incompleteAmbiguityGroup = "incomplete_ambiguity_group"
}

enum WorkStateTransitionReviewWriteResult: Equatable, Sendable {
    case recorded
    case alreadyRecorded
    case refused(WorkStateTransitionReviewWriteRefusalReason)
}

struct WorkStateTransitionTerminalReview: Codable, Equatable, Sendable {
    let proposalID: UUID
    let verdict: WorkStateTransitionTerminalVerdict
}

enum WorkStateTransitionApplyIntentWriteRefusalReason: String, Codable, Equatable, Sendable {
    case payloadConflict = "payload_conflict"
    case invalidPayloadHash = "invalid_payload_hash"
}

enum WorkStateTransitionApplyIntentWriteResult: Equatable, Sendable {
    case recorded
    case alreadyRecorded
    case refused(WorkStateTransitionApplyIntentWriteRefusalReason)
}

/// Durable record that a meeting deletion was authorized and has not finished yet.
///
/// Deleting a meeting now touches two stores, so there is a window where the Project no longer has
/// the meeting but the transition sidecar still describes it. This is what closes that window: it
/// is written before either store changes and removed after both have, so a relaunch can tell the
/// difference between "finished" and "stopped halfway" without guessing.
///
/// `removedWorkStateIDs` is captured *before* the Project step, because after it the Project can no
/// longer answer which objects belonged to the meeting — and recovery still has to finish the
/// sidecar closure that hangs off exactly those ids.
///
/// Identifiers and a timestamp only, matching `WorkStateTransitionApplyIntent`. No title, no quote,
/// no participant: a deletion receipt must not become the last place a deleted meeting's content
/// survives.
struct MeetingDeletionIntent: Codable, Equatable, Sendable {
    let projectID: UUID
    let meetingID: UUID
    /// Sorted, so the same deletion produces the same record twice rather than two rows that only
    /// differ in order.
    let removedWorkStateIDs: [UUID]
    let requestedAt: Date

    init(projectID: UUID, meetingID: UUID, removedWorkStateIDs: [UUID], requestedAt: Date) {
        self.projectID = projectID
        self.meetingID = meetingID
        self.removedWorkStateIDs = removedWorkStateIDs
            .map { $0.uuidString.lowercased() }
            .sorted()
            .compactMap(UUID.init(uuidString:))
        self.requestedAt = requestedAt
    }

    var storageKey: String {
        "\(projectID.uuidString.lowercased())|\(meetingID.uuidString.lowercased())"
    }
}

/// Durable record that a project deletion was authorized and has not finished yet.
///
/// The same two-store window `MeetingDeletionIntent` closes, one scope up. It carries two fields
/// and can carry no more: a project deletion receipt has no meeting to name, and the project's
/// title, its meetings and its Work State are exactly what the deletion is removing — a receipt
/// must not become the last place any of it survives.
///
/// Unlike the meeting intent there is no list of removed object ids, because none is needed: the
/// sidecar rows are found by their own `projectID`, which is still on every one of them after the
/// aggregate is gone.
struct ProjectDeletionIntent: Codable, Equatable, Sendable {
    let projectID: UUID
    let requestedAt: Date

    var storageKey: String { projectID.uuidString.lowercased() }
}

/// Durable, privacy-safe description of one user-approved apply operation.
///
/// It deliberately contains identifiers, finite enums, a timestamp and a hash only. Project
/// content, evidence quotes, names and provider payloads remain in their existing authorities.
struct WorkStateTransitionApplyIntent: Codable, Equatable, Sendable {
    let projectID: UUID
    let operationID: UUID
    let operationKind: WorkStateTransitionApplyOperationKind
    let terminalReviews: [WorkStateTransitionTerminalReview]
    let ambiguitySelectionKind: WorkStateAmbiguitySelectionKind?
    let selectedPriorStateID: UUID?
    let reviewedAt: Date
    let payloadHash: String

    var storageKey: String {
        "\(projectID.uuidString.lowercased())|\(operationKind.rawValue)|\(operationID.uuidString.lowercased())"
    }

    var hasValidPayloadHash: Bool { payloadHash == Self.payloadHash(
        projectID: projectID,
        operationID: operationID,
        operationKind: operationKind,
        terminalReviews: terminalReviews,
        ambiguitySelectionKind: ambiguitySelectionKind,
        selectedPriorStateID: selectedPriorStateID,
        reviewedAt: reviewedAt
    ) }

    static func proposal(
        projectID: UUID,
        proposalID: UUID,
        terminalReviews: [WorkStateTransitionTerminalReview],
        reviewedAt: Date
    ) -> Self {
        make(
            projectID: projectID,
            operationID: proposalID,
            operationKind: .proposal,
            terminalReviews: terminalReviews,
            ambiguitySelectionKind: nil,
            selectedPriorStateID: nil,
            reviewedAt: reviewedAt
        )
    }

    static func ambiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) -> Self {
        let kind: WorkStateAmbiguitySelectionKind
        let selectedPriorStateID: UUID?
        switch selection {
        case .priorCandidate(let id):
            kind = .priorCandidate
            selectedPriorStateID = id
        case .new:
            kind = .new
            selectedPriorStateID = nil
        }
        return make(
            projectID: projectID,
            operationID: groupID,
            operationKind: .ambiguity,
            terminalReviews: [],
            ambiguitySelectionKind: kind,
            selectedPriorStateID: selectedPriorStateID,
            reviewedAt: reviewedAt
        )
    }

    var ambiguitySelection: WorkStateAmbiguousMatchSelection? {
        switch ambiguitySelectionKind {
        case .priorCandidate:
            selectedPriorStateID.map(WorkStateAmbiguousMatchSelection.priorCandidate)
        case .new:
            .new
        case nil:
            nil
        }
    }

    private static func make(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind,
        terminalReviews: [WorkStateTransitionTerminalReview],
        ambiguitySelectionKind: WorkStateAmbiguitySelectionKind?,
        selectedPriorStateID: UUID?,
        reviewedAt: Date
    ) -> Self {
        let sortedReviews = terminalReviews.sorted {
            let left = $0.proposalID.uuidString.lowercased()
            let right = $1.proposalID.uuidString.lowercased()
            return left == right ? $0.verdict.rawValue < $1.verdict.rawValue : left < right
        }
        return Self(
            projectID: projectID,
            operationID: operationID,
            operationKind: operationKind,
            terminalReviews: sortedReviews,
            ambiguitySelectionKind: ambiguitySelectionKind,
            selectedPriorStateID: selectedPriorStateID,
            reviewedAt: reviewedAt,
            payloadHash: payloadHash(
                projectID: projectID,
                operationID: operationID,
                operationKind: operationKind,
                terminalReviews: sortedReviews,
                ambiguitySelectionKind: ambiguitySelectionKind,
                selectedPriorStateID: selectedPriorStateID,
                reviewedAt: reviewedAt
            )
        )
    }

    private static func payloadHash(
        projectID: UUID,
        operationID: UUID,
        operationKind: WorkStateTransitionApplyOperationKind,
        terminalReviews: [WorkStateTransitionTerminalReview],
        ambiguitySelectionKind: WorkStateAmbiguitySelectionKind?,
        selectedPriorStateID: UUID?,
        reviewedAt: Date
    ) -> String {
        let reviews = terminalReviews.map {
            "\($0.proposalID.uuidString.lowercased()):\($0.verdict.rawValue)"
        }.joined(separator: ",")
        let canonical = [
            projectID.uuidString.lowercased(),
            operationKind.rawValue,
            operationID.uuidString.lowercased(),
            reviews,
            ambiguitySelectionKind?.rawValue ?? "none",
            selectedPriorStateID?.uuidString.lowercased() ?? "none",
            String(reviewedAt.timeIntervalSince1970.bitPattern)
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum WorkStateAmbiguitySelectionKind: String, Codable, Equatable, Sendable {
    case priorCandidate = "prior_candidate"
    case new
}

/// Persisted ambiguity review contains identifiers, finite enums and a timestamp only.
struct WorkStateAmbiguityReviewState: Codable, Equatable, Sendable {
    let groupID: UUID
    let projectID: UUID
    let selectionKind: WorkStateAmbiguitySelectionKind
    let selectedPriorStateID: UUID?
    let reviewedAt: Date

    func matches(_ selection: WorkStateAmbiguousMatchSelection) -> Bool {
        switch selection {
        case .priorCandidate(let id):
            return selectionKind == .priorCandidate && selectedPriorStateID == id
        case .new:
            return selectionKind == .new && selectedPriorStateID == nil
        }
    }
}

/// The on-disk shape of `continuity-transitions.json`.
///
/// Schema 3 adds terminal ambiguity selections. Schema 4 adds durable apply intents. Missing newer
/// arrays decode as empty so v1/v2/v3 files migrate without losing existing state.
struct WorkStateTransitionStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 4
    static let readableSchemaVersions: Set<Int> = [1, 2, 3, 4]

    var schemaVersion: Int
    var proposals: [WorkStateTransitionProposal]
    var reviews: [WorkStateTransitionReviewState]
    var ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup]
    var ambiguityReviews: [WorkStateAmbiguityReviewState]
    var refusals: [WorkStateTransitionRefusalRecord]
    var applyIntents: [WorkStateTransitionApplyIntent]
    var meetingDeletionIntents: [MeetingDeletionIntent]
    var projectDeletionIntents: [ProjectDeletionIntent]

    init(
        schemaVersion: Int = WorkStateTransitionStoreFile.currentSchemaVersion,
        proposals: [WorkStateTransitionProposal] = [],
        reviews: [WorkStateTransitionReviewState] = [],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup] = [],
        ambiguityReviews: [WorkStateAmbiguityReviewState] = [],
        refusals: [WorkStateTransitionRefusalRecord] = [],
        applyIntents: [WorkStateTransitionApplyIntent] = [],
        meetingDeletionIntents: [MeetingDeletionIntent] = [],
        projectDeletionIntents: [ProjectDeletionIntent] = []
    ) {
        self.schemaVersion = schemaVersion
        self.proposals = proposals
        self.reviews = reviews
        self.ambiguousMatchGroups = ambiguousMatchGroups
        self.ambiguityReviews = ambiguityReviews
        self.refusals = refusals
        self.applyIntents = applyIntents
        self.meetingDeletionIntents = meetingDeletionIntents
        self.projectDeletionIntents = projectDeletionIntents
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, proposals, reviews, ambiguousMatchGroups, ambiguityReviews, refusals
        case applyIntents, meetingDeletionIntents, projectDeletionIntents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        proposals = try container.decode([WorkStateTransitionProposal].self, forKey: .proposals)
        reviews = try container.decodeIfPresent(
            [WorkStateTransitionReviewState].self, forKey: .reviews
        ) ?? []
        ambiguousMatchGroups = try container.decodeIfPresent(
            [WorkStateAmbiguousMatchGroup].self, forKey: .ambiguousMatchGroups
        ) ?? []
        ambiguityReviews = try container.decodeIfPresent(
            [WorkStateAmbiguityReviewState].self, forKey: .ambiguityReviews
        ) ?? []
        refusals = try container.decodeIfPresent(
            [WorkStateTransitionRefusalRecord].self, forKey: .refusals
        ) ?? []
        applyIntents = try container.decodeIfPresent(
            [WorkStateTransitionApplyIntent].self, forKey: .applyIntents
        ) ?? []
        // Additive and optional: a sidecar written before meeting deletion became a two-store
        // operation decodes with no pending deletions, which is exactly true of it.
        meetingDeletionIntents = try container.decodeIfPresent(
            [MeetingDeletionIntent].self, forKey: .meetingDeletionIntents
        ) ?? []
        // Additive and optional for the same reason, one scope up: a sidecar written before project
        // deletion became a two-store operation decodes with no pending project deletions, which is
        // exactly true of it. No schema bump — nothing existing is read differently.
        projectDeletionIntents = try container.decodeIfPresent(
            [ProjectDeletionIntent].self, forKey: .projectDeletionIntents
        ) ?? []
    }
}

protocol WorkStateTransitionRepository: Sendable {
    func proposals(forProject projectID: UUID) async throws -> [WorkStateTransitionProposal]
    func allProposals() async throws -> [WorkStateTransitionProposal]
    func ambiguousMatchGroups(forProject projectID: UUID) async throws -> [WorkStateAmbiguousMatchGroup]
    func allAmbiguousMatchGroups() async throws -> [WorkStateAmbiguousMatchGroup]
    func ambiguityReview(groupID: UUID) async throws -> WorkStateAmbiguityReviewState?
    func refusals(forProject projectID: UUID) async throws -> [WorkStateTransitionRefusalRecord]
    func allRefusals() async throws -> [WorkStateTransitionRefusalRecord]
    func upsert(_ proposals: [WorkStateTransitionProposal]) async throws
    func upsert(
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        refusals: [WorkStateTransitionRefusalRecord]
    ) async throws
    func recordTerminalReview(
        projectID: UUID,
        proposalID: UUID,
        verdict: WorkStateTransitionTerminalVerdict
    ) async throws -> WorkStateTransitionReviewWriteResult
    func recordTerminalReviews(
        projectID: UUID,
        reviews: [WorkStateTransitionTerminalReview]
    ) async throws -> WorkStateTransitionReviewWriteResult
    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) async throws -> WorkStateTransitionReviewWriteResult
    func pendingApplyIntents() async throws -> [WorkStateTransitionApplyIntent]
    func prepareApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionApplyIntentWriteResult
    func finalizeApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) async throws -> WorkStateTransitionReviewWriteResult
    /// Records that a meeting deletion was authorized, before either store changes.
    /// Re-recording the same intent is a no-op, so a retried deletion does not create a second one.
    func recordMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws
    /// Deletions that were authorized but never confirmed finished — the relaunch work list.
    func pendingMeetingDeletionIntents() async throws -> [MeetingDeletionIntent]
    /// Removes everything the closure covers in **one** write, so the sidecar is never observed
    /// half-cleaned. Safe to run again: the second run finds nothing to remove and writes nothing.
    func applyMeetingDeletion(_ intent: MeetingDeletionIntent) async throws
    /// Marks the deletion finished. Idempotent.
    func clearMeetingDeletionIntent(_ intent: MeetingDeletionIntent) async throws
    /// Records that a project deletion was authorized, before either store changes.
    /// Re-recording the same intent is a no-op.
    func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) async throws
    /// Project deletions authorized but never confirmed finished — the relaunch work list.
    func pendingProjectDeletionIntents() async throws -> [ProjectDeletionIntent]
    /// Removes every row belonging to the project **and the intent itself** in one write, so the
    /// sweep and its receipt cannot come apart. Safe to run again: the second run finds neither and
    /// writes nothing.
    func applyProjectDeletion(_ intent: ProjectDeletionIntent) async throws
}

private struct WorkStateTransitionStoreCache {
    var proposals: [String: WorkStateTransitionProposal] = [:]
    var reviews: [String: WorkStateTransitionReviewStatus] = [:]
    var ambiguousMatchGroups: [String: WorkStateAmbiguousMatchGroup] = [:]
    var ambiguityReviews: [UUID: WorkStateAmbiguityReviewState] = [:]
    var refusals: [String: WorkStateTransitionRefusalRecord] = [:]
    var applyIntents: [String: WorkStateTransitionApplyIntent] = [:]
    var meetingDeletionIntents: [String: MeetingDeletionIntent] = [:]
    var projectDeletionIntents: [String: ProjectDeletionIntent] = [:]
}

actor JSONWorkStateTransitionRepository: WorkStateTransitionRepository {
    private let fileURL: URL
    private let fileManager: FileManager
    private var cache: WorkStateTransitionStoreCache?

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        JSONProjectRepository.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("continuity-transitions.json")
    }

    func proposals(forProject projectID: UUID) throws -> [WorkStateTransitionProposal] {
        try sortedProposals(loadIfNeeded()).filter { $0.projectID == projectID }
    }

    func allProposals() throws -> [WorkStateTransitionProposal] {
        try sortedProposals(loadIfNeeded())
    }

    func ambiguousMatchGroups(forProject projectID: UUID) throws -> [WorkStateAmbiguousMatchGroup] {
        try sortedAmbiguousMatchGroups(loadIfNeeded()).filter { $0.projectID == projectID }
    }

    func allAmbiguousMatchGroups() throws -> [WorkStateAmbiguousMatchGroup] {
        try sortedAmbiguousMatchGroups(loadIfNeeded())
    }

    func ambiguityReview(groupID: UUID) throws -> WorkStateAmbiguityReviewState? {
        try loadIfNeeded().ambiguityReviews[groupID]
    }

    func refusals(forProject projectID: UUID) throws -> [WorkStateTransitionRefusalRecord] {
        try sortedRefusals(loadIfNeeded()).filter { $0.projectID == projectID }
    }

    func allRefusals() throws -> [WorkStateTransitionRefusalRecord] {
        try sortedRefusals(loadIfNeeded())
    }

    func pendingApplyIntents() throws -> [WorkStateTransitionApplyIntent] {
        try loadIfNeeded().applyIntents.values.sorted { $0.storageKey < $1.storageKey }
    }

    func prepareApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) throws -> WorkStateTransitionApplyIntentWriteResult {
        guard intent.hasValidPayloadHash else { return .refused(.invalidPayloadHash) }
        var stored = try loadIfNeeded()
        if let existing = stored.applyIntents[intent.storageKey] {
            return existing == intent ? .alreadyRecorded : .refused(.payloadConflict)
        }
        stored.applyIntents[intent.storageKey] = intent
        try persist(stored)
        cache = stored
        return .recorded
    }

    func finalizeApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) throws -> WorkStateTransitionReviewWriteResult {
        guard intent.hasValidPayloadHash else {
            return .refused(.terminalVerdictConflict)
        }
        var stored = try loadIfNeeded()
        guard stored.applyIntents[intent.storageKey] == intent else {
            return .refused(.terminalVerdictConflict)
        }

        let result: WorkStateTransitionReviewWriteResult
        switch intent.operationKind {
        case .proposal:
            guard intent.ambiguitySelectionKind == nil,
                  intent.selectedPriorStateID == nil,
                  !intent.terminalReviews.isEmpty
            else { return .refused(.terminalVerdictConflict) }
            result = applyTerminalReviews(
                projectID: intent.projectID,
                reviews: intent.terminalReviews,
                to: &stored
            )
        case .ambiguity:
            guard intent.terminalReviews.isEmpty,
                  let selection = intent.ambiguitySelection
            else { return .refused(.terminalVerdictConflict) }
            result = applyAmbiguityResolution(
                projectID: intent.projectID,
                groupID: intent.operationID,
                selection: selection,
                reviewedAt: intent.reviewedAt,
                to: &stored
            )
        }

        switch result {
        case .recorded, .alreadyRecorded:
            stored.applyIntents.removeValue(forKey: intent.storageKey)
            try persist(stored)
            cache = stored
        case .refused:
            break
        }
        return result
    }

    func upsert(_ proposals: [WorkStateTransitionProposal]) throws {
        try upsert(proposals: proposals, ambiguousMatchGroups: [], refusals: [])
    }

    func upsert(
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        refusals: [WorkStateTransitionRefusalRecord]
    ) throws {
        guard !proposals.isEmpty || !ambiguousMatchGroups.isEmpty || !refusals.isEmpty else { return }

        var stored = try loadIfNeeded()
        mergeProposals(proposals, into: &stored)
        for group in ambiguousMatchGroups {
            stored.ambiguousMatchGroups[group.dedupKey] = group
        }
        for refusal in refusals {
            if let existing = stored.refusals[refusal.dedupKey] {
                stored.refusals[refusal.dedupKey] = copy(refusal, createdAt: existing.createdAt)
            } else {
                stored.refusals[refusal.dedupKey] = refusal
            }
        }
        try persist(stored)
        cache = stored
    }

    func recordTerminalReview(
        projectID: UUID,
        proposalID: UUID,
        verdict: WorkStateTransitionTerminalVerdict
    ) throws -> WorkStateTransitionReviewWriteResult {
        try recordTerminalReviews(
            projectID: projectID,
            reviews: [.init(proposalID: proposalID, verdict: verdict)]
        )
    }

    func recordTerminalReviews(
        projectID: UUID,
        reviews: [WorkStateTransitionTerminalReview]
    ) throws -> WorkStateTransitionReviewWriteResult {
        var stored = try loadIfNeeded()
        let result = applyTerminalReviews(projectID: projectID, reviews: reviews, to: &stored)
        guard result == .recorded else { return result }
        try persist(stored)
        cache = stored
        return .recorded
    }

    private func applyTerminalReviews(
        projectID: UUID,
        reviews: [WorkStateTransitionTerminalReview],
        to stored: inout WorkStateTransitionStoreCache
    ) -> WorkStateTransitionReviewWriteResult {
        var requestedByDedup: [String: WorkStateTransitionReviewStatus] = [:]
        for review in reviews {
            guard let proposal = stored.proposals.values.first(where: { $0.id == review.proposalID }) else {
                return .refused(.unknownProposal)
            }
            guard proposal.projectID == projectID else { return .refused(.projectMismatch) }
            let requested = review.verdict.reviewStatus
            if let duplicate = requestedByDedup[proposal.dedupKey], duplicate != requested {
                return .refused(.terminalVerdictConflict)
            }
            requestedByDedup[proposal.dedupKey] = requested
        }
        for (dedupKey, requested) in requestedByDedup {
            if let existing = stored.reviews[dedupKey], existing != requested {
                return .refused(.terminalVerdictConflict)
            }
        }
        let hasNewReview = requestedByDedup.contains { stored.reviews[$0.key] == nil }
        guard hasNewReview else { return .alreadyRecorded }
        for (dedupKey, requested) in requestedByDedup {
            stored.reviews[dedupKey] = requested
        }
        return .recorded
    }

    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) throws -> WorkStateTransitionReviewWriteResult {
        var stored = try loadIfNeeded()
        let result = applyAmbiguityResolution(
            projectID: projectID,
            groupID: groupID,
            selection: selection,
            reviewedAt: reviewedAt,
            to: &stored
        )
        guard result == .recorded else { return result }
        try persist(stored)
        cache = stored
        return .recorded
    }

    private func applyAmbiguityResolution(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date,
        to stored: inout WorkStateTransitionStoreCache
    ) -> WorkStateTransitionReviewWriteResult {
        guard let group = stored.ambiguousMatchGroups.values.first(where: { $0.id == groupID }) else {
            return .refused(.unknownAmbiguityGroup)
        }
        guard group.projectID == projectID else { return .refused(.projectMismatch) }
        guard group.accepts(selection) else { return .refused(.invalidAmbiguitySelection) }
        if let existing = stored.ambiguityReviews[groupID] {
            return existing.matches(selection)
                ? .alreadyRecorded
                : .refused(.terminalVerdictConflict)
        }

        let siblings = ambiguitySiblings(group: group, stored: stored)
        guard siblings.count == group.priorCandidateIDs.count else {
            return .refused(.incompleteAmbiguityGroup)
        }

        let selectedPriorID: UUID?
        switch selection {
        case .priorCandidate(let id): selectedPriorID = id
        case .new: selectedPriorID = nil
        }
        for sibling in siblings {
            let status: WorkStateTransitionReviewStatus =
                sibling.previousStateID == selectedPriorID && selectedPriorID != nil
                ? .approved : .rejected
            if let existing = stored.reviews[sibling.dedupKey], existing != status {
                return .refused(.terminalVerdictConflict)
            }
        }
        for sibling in siblings {
            stored.reviews[sibling.dedupKey] =
                sibling.previousStateID == selectedPriorID && selectedPriorID != nil
                ? .approved : .rejected
        }
        stored.ambiguityReviews[groupID] = WorkStateAmbiguityReviewState(
            groupID: groupID,
            projectID: projectID,
            selectionKind: selectedPriorID == nil ? .new : .priorCandidate,
            selectedPriorStateID: selectedPriorID,
            reviewedAt: reviewedAt
        )
        return .recorded
    }

    private func loadIfNeeded() throws -> WorkStateTransitionStoreCache {
        if let cache { return cache }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let empty = WorkStateTransitionStoreCache()
            cache = empty
            return empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw JSONRepositoryError.readFailed(underlying: String(describing: error))
        }

        let store: WorkStateTransitionStoreFile
        do {
            store = try JSONDecoder().decode(WorkStateTransitionStoreFile.self, from: data)
        } catch {
            throw JSONRepositoryError.decodingFailed(underlying: String(describing: error))
        }
        guard WorkStateTransitionStoreFile.readableSchemaVersions.contains(store.schemaVersion) else {
            throw JSONRepositoryError.unsupportedSchemaVersion(
                found: store.schemaVersion,
                supported: WorkStateTransitionStoreFile.currentSchemaVersion
            )
        }
        guard store.proposals.allSatisfy(\.hasValidProgressDispositionContract) else {
            throw JSONRepositoryError.decodingFailed(
                underlying: "invalid progress-disposition contract"
            )
        }

        var loaded = WorkStateTransitionStoreCache()
        for review in store.reviews where review.status != .pendingReview {
            loaded.reviews[review.dedupKey] = review.status
        }
        // Schema 1 carried user review state inside the proposal. Lift it into the separated map.
        for proposal in store.proposals {
            if proposal.reviewStatus != .pendingReview {
                loaded.reviews[proposal.dedupKey] = proposal.reviewStatus
            }
            loaded.proposals[proposal.dedupKey] = copy(
                proposal, reviewStatus: .pendingReview, createdAt: proposal.createdAt
            )
        }
        for group in store.ambiguousMatchGroups {
            loaded.ambiguousMatchGroups[group.dedupKey] = group
        }
        for review in store.ambiguityReviews {
            loaded.ambiguityReviews[review.groupID] = review
        }
        for refusal in store.refusals {
            loaded.refusals[refusal.dedupKey] = refusal
        }
        for intent in store.applyIntents {
            // Keep a malformed durable record observable so launch recovery can return a finite
            // refusal for that operation. It must never become a silent empty recovery result.
            loaded.applyIntents[intent.storageKey] = intent
        }
        cache = loaded
        return loaded
    }

    private func mergeProposals(
        _ incoming: [WorkStateTransitionProposal],
        into stored: inout WorkStateTransitionStoreCache
    ) {
        for proposal in incoming {
            let originalCreatedAt = stored.proposals[proposal.dedupKey]?.createdAt ?? proposal.createdAt
            // A terminal verdict owns the exact payload the person reviewed. Deferred and blocked
            // intentionally share the historical dedup key, so replacing a reviewed row here
            // would silently move that verdict to a different claim on rerun.
            if stored.reviews[proposal.dedupKey] != nil,
               stored.proposals[proposal.dedupKey] != nil {
                continue
            }
            if proposal.reviewStatus != .pendingReview,
               stored.reviews[proposal.dedupKey] == nil {
                stored.reviews[proposal.dedupKey] = proposal.reviewStatus
            }
            // The latest engine explanation may replace basis/reasons/relations, but user-owned
            // review state and the first insertion timestamp live outside that replacement.
            stored.proposals[proposal.dedupKey] = copy(
                proposal, reviewStatus: .pendingReview, createdAt: originalCreatedAt
            )
        }
    }

    private func sortedProposals(
        _ stored: WorkStateTransitionStoreCache
    ) -> [WorkStateTransitionProposal] {
        stored.proposals.values.map { proposal in
            copy(
                proposal,
                reviewStatus: stored.reviews[proposal.dedupKey] ?? .pendingReview,
                createdAt: proposal.createdAt
            )
        }.sorted { $0.dedupKey < $1.dedupKey }
    }

    private func sortedAmbiguousMatchGroups(
        _ stored: WorkStateTransitionStoreCache
    ) -> [WorkStateAmbiguousMatchGroup] {
        stored.ambiguousMatchGroups.values.sorted { $0.dedupKey < $1.dedupKey }
    }

    // MARK: - Meeting deletion

    func recordMeetingDeletionIntent(_ intent: MeetingDeletionIntent) throws {
        var stored = try loadIfNeeded()
        guard stored.meetingDeletionIntents[intent.storageKey] != intent else { return }
        stored.meetingDeletionIntents[intent.storageKey] = intent
        try persist(stored)
        cache = stored
    }

    func pendingMeetingDeletionIntents() throws -> [MeetingDeletionIntent] {
        try loadIfNeeded().meetingDeletionIntents.values
            .sorted { $0.storageKey < $1.storageKey }
    }

    func applyMeetingDeletion(_ intent: MeetingDeletionIntent) throws {
        var stored = try loadIfNeeded()
        let closure = MeetingDeletionClosure.resolve(
            meetingID: intent.meetingID,
            projectID: intent.projectID,
            removedWorkStateIDs: Set(intent.removedWorkStateIDs),
            proposals: Array(stored.proposals.values),
            ambiguousMatchGroups: Array(stored.ambiguousMatchGroups.values),
            refusals: Array(stored.refusals.values),
            applyIntents: Array(stored.applyIntents.values)
        )
        // Nothing to do is a real outcome, not a failure: it is what a second recovery pass sees.
        // Returning without writing is what makes repeated recovery leave the file byte-identical.
        guard !closure.isEmpty else { return }

        for key in closure.proposalKeys {
            stored.proposals.removeValue(forKey: key)
            // The verdict is keyed by the same dedupKey as the proposal it judged, so it leaves with
            // it. A verdict kept past its subject is unreachable, not preserved.
            stored.reviews.removeValue(forKey: key)
        }
        for key in closure.ambiguousMatchGroupKeys {
            stored.ambiguousMatchGroups.removeValue(forKey: key)
        }
        for key in closure.refusalKeys {
            stored.refusals.removeValue(forKey: key)
        }
        for groupID in closure.ambiguityGroupIDs {
            stored.ambiguityReviews.removeValue(forKey: groupID)
        }
        for key in closure.applyIntentKeys {
            stored.applyIntents.removeValue(forKey: key)
        }

        try persist(stored)
        cache = stored
    }

    func clearMeetingDeletionIntent(_ intent: MeetingDeletionIntent) throws {
        var stored = try loadIfNeeded()
        guard stored.meetingDeletionIntents.removeValue(forKey: intent.storageKey) != nil else {
            return
        }
        try persist(stored)
        cache = stored
    }

    // MARK: - Project deletion

    func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) throws {
        var stored = try loadIfNeeded()
        guard stored.projectDeletionIntents[intent.storageKey] != intent else { return }
        stored.projectDeletionIntents[intent.storageKey] = intent
        try persist(stored)
        cache = stored
    }

    func pendingProjectDeletionIntents() throws -> [ProjectDeletionIntent] {
        try loadIfNeeded().projectDeletionIntents.values
            .sorted { $0.storageKey < $1.storageKey }
    }

    func applyProjectDeletion(_ intent: ProjectDeletionIntent) throws {
        var stored = try loadIfNeeded()
        let closure = ProjectDeletionClosure.resolve(
            projectID: intent.projectID,
            proposals: Array(stored.proposals.values),
            ambiguousMatchGroups: Array(stored.ambiguousMatchGroups.values),
            ambiguityReviews: Array(stored.ambiguityReviews.values),
            refusals: Array(stored.refusals.values),
            applyIntents: Array(stored.applyIntents.values),
            meetingDeletionIntents: Array(stored.meetingDeletionIntents.values)
        )
        let hasIntent = stored.projectDeletionIntents[intent.storageKey] != nil
        // Nothing left and no receipt to retire is what the second pass sees. Returning without
        // writing is what makes repeated recovery leave the file byte-identical.
        guard !closure.isEmpty || hasIntent else { return }

        removeProjectScopedRows(closure, from: &stored)
        // Retired in the same write as the rows it authorized. Split across two writes there would
        // be a moment where the work is done and the receipt says it is not, and recovery would
        // redo a sweep that has already happened.
        stored.projectDeletionIntents.removeValue(forKey: intent.storageKey)

        try persist(stored)
        cache = stored
    }

    /// The removal loop, shared by the live path and recovery so they cannot drift apart. A
    /// proposal's review leaves with it under the same `dedupKey`, exactly as in the meeting path.
    private func removeProjectScopedRows(
        _ closure: ProjectDeletionClosure,
        from stored: inout WorkStateTransitionStoreCache
    ) {
        for key in closure.proposalKeys {
            stored.proposals.removeValue(forKey: key)
            stored.reviews.removeValue(forKey: key)
        }
        for key in closure.ambiguousMatchGroupKeys {
            stored.ambiguousMatchGroups.removeValue(forKey: key)
        }
        for key in closure.refusalKeys {
            stored.refusals.removeValue(forKey: key)
        }
        for groupID in closure.ambiguityGroupIDs {
            stored.ambiguityReviews.removeValue(forKey: groupID)
        }
        for key in closure.applyIntentKeys {
            stored.applyIntents.removeValue(forKey: key)
        }
        for key in closure.meetingDeletionIntentKeys {
            stored.meetingDeletionIntents.removeValue(forKey: key)
        }
    }

    private func sortedRefusals(
        _ stored: WorkStateTransitionStoreCache
    ) -> [WorkStateTransitionRefusalRecord] {
        stored.refusals.values.sorted { $0.dedupKey < $1.dedupKey }
    }

    private func persist(_ stored: WorkStateTransitionStoreCache) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JSONRepositoryError.directoryCreationFailed(underlying: String(describing: error))
        }

        let reviews = stored.reviews.map {
            WorkStateTransitionReviewState(dedupKey: $0.key, status: $0.value)
        }.sorted { $0.dedupKey < $1.dedupKey }
        let store = WorkStateTransitionStoreFile(
            proposals: stored.proposals.values.sorted { $0.dedupKey < $1.dedupKey },
            reviews: reviews,
            ambiguousMatchGroups: sortedAmbiguousMatchGroups(stored),
            ambiguityReviews: stored.ambiguityReviews.values.sorted {
                $0.groupID.uuidString.lowercased() < $1.groupID.uuidString.lowercased()
            },
            refusals: sortedRefusals(stored),
            applyIntents: stored.applyIntents.values.sorted { $0.storageKey < $1.storageKey },
            meetingDeletionIntents: stored.meetingDeletionIntents.values
                .sorted { $0.storageKey < $1.storageKey },
            projectDeletionIntents: stored.projectDeletionIntents.values
                .sorted { $0.storageKey < $1.storageKey }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(store)
        } catch {
            throw JSONRepositoryError.encodingFailed(underlying: String(describing: error))
        }

        let temporaryURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
        } catch {
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }
        _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw JSONRepositoryError.writeFailed(underlying: String(describing: error))
        }
    }

    private func ambiguitySiblings(
        group: WorkStateAmbiguousMatchGroup,
        stored: WorkStateTransitionStoreCache
    ) -> [WorkStateTransitionProposal] {
        stored.proposals.values.filter {
            $0.projectID == group.projectID
                && $0.workStateKind == group.workStateKind
                && $0.currentObjectID == group.incomingObjectID
                && $0.previousStateID.map(group.priorCandidateIDs.contains) == true
        }
    }
}

actor InMemoryWorkStateTransitionRepository: WorkStateTransitionRepository {
    private var cache = WorkStateTransitionStoreCache()
    private let saveError: Error?

    init(
        proposals: [WorkStateTransitionProposal] = [],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup] = [],
        ambiguityReviews: [WorkStateAmbiguityReviewState] = [],
        refusals: [WorkStateTransitionRefusalRecord] = [],
        saveError: Error? = nil
    ) {
        self.saveError = saveError
        for proposal in proposals {
            if proposal.reviewStatus != .pendingReview {
                cache.reviews[proposal.dedupKey] = proposal.reviewStatus
            }
            cache.proposals[proposal.dedupKey] = copy(
                proposal, reviewStatus: .pendingReview, createdAt: proposal.createdAt
            )
        }
        for group in ambiguousMatchGroups { cache.ambiguousMatchGroups[group.dedupKey] = group }
        for review in ambiguityReviews { cache.ambiguityReviews[review.groupID] = review }
        for refusal in refusals { cache.refusals[refusal.dedupKey] = refusal }
    }

    func proposals(forProject projectID: UUID) -> [WorkStateTransitionProposal] {
        sortedProposals().filter { $0.projectID == projectID }
    }

    func allProposals() -> [WorkStateTransitionProposal] { sortedProposals() }

    func ambiguousMatchGroups(forProject projectID: UUID) -> [WorkStateAmbiguousMatchGroup] {
        allAmbiguousMatchGroups().filter { $0.projectID == projectID }
    }

    func allAmbiguousMatchGroups() -> [WorkStateAmbiguousMatchGroup] {
        cache.ambiguousMatchGroups.values.sorted { $0.dedupKey < $1.dedupKey }
    }

    func ambiguityReview(groupID: UUID) -> WorkStateAmbiguityReviewState? {
        cache.ambiguityReviews[groupID]
    }

    func refusals(forProject projectID: UUID) -> [WorkStateTransitionRefusalRecord] {
        allRefusals().filter { $0.projectID == projectID }
    }

    func allRefusals() -> [WorkStateTransitionRefusalRecord] {
        cache.refusals.values.sorted { $0.dedupKey < $1.dedupKey }
    }

    func pendingApplyIntents() -> [WorkStateTransitionApplyIntent] {
        cache.applyIntents.values.sorted { $0.storageKey < $1.storageKey }
    }

    func prepareApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) throws -> WorkStateTransitionApplyIntentWriteResult {
        guard intent.hasValidPayloadHash else { return .refused(.invalidPayloadHash) }
        if let existing = cache.applyIntents[intent.storageKey] {
            return existing == intent ? .alreadyRecorded : .refused(.payloadConflict)
        }
        if let saveError { throw saveError }
        cache.applyIntents[intent.storageKey] = intent
        return .recorded
    }

    func finalizeApplyIntent(
        _ intent: WorkStateTransitionApplyIntent
    ) throws -> WorkStateTransitionReviewWriteResult {
        guard intent.hasValidPayloadHash,
              cache.applyIntents[intent.storageKey] == intent
        else { return .refused(.terminalVerdictConflict) }

        let result: WorkStateTransitionReviewWriteResult
        switch intent.operationKind {
        case .proposal:
            guard intent.ambiguitySelectionKind == nil,
                  intent.selectedPriorStateID == nil,
                  !intent.terminalReviews.isEmpty
            else { return .refused(.terminalVerdictConflict) }
            result = try recordTerminalReviews(
                projectID: intent.projectID,
                reviews: intent.terminalReviews
            )
        case .ambiguity:
            guard intent.terminalReviews.isEmpty,
                  let selection = intent.ambiguitySelection
            else { return .refused(.terminalVerdictConflict) }
            result = try resolveAmbiguity(
                projectID: intent.projectID,
                groupID: intent.operationID,
                selection: selection,
                reviewedAt: intent.reviewedAt
            )
        }
        switch result {
        case .recorded, .alreadyRecorded:
            cache.applyIntents.removeValue(forKey: intent.storageKey)
        case .refused:
            break
        }
        return result
    }

    func upsert(_ proposals: [WorkStateTransitionProposal]) throws {
        try upsert(proposals: proposals, ambiguousMatchGroups: [], refusals: [])
    }

    func upsert(
        proposals: [WorkStateTransitionProposal],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup],
        refusals: [WorkStateTransitionRefusalRecord]
    ) throws {
        if let saveError { throw saveError }
        for proposal in proposals {
            let originalCreatedAt = cache.proposals[proposal.dedupKey]?.createdAt ?? proposal.createdAt
            if cache.reviews[proposal.dedupKey] != nil,
               cache.proposals[proposal.dedupKey] != nil {
                continue
            }
            if proposal.reviewStatus != .pendingReview,
               cache.reviews[proposal.dedupKey] == nil {
                cache.reviews[proposal.dedupKey] = proposal.reviewStatus
            }
            cache.proposals[proposal.dedupKey] = copy(
                proposal, reviewStatus: .pendingReview, createdAt: originalCreatedAt
            )
        }
        for group in ambiguousMatchGroups { cache.ambiguousMatchGroups[group.dedupKey] = group }
        for refusal in refusals {
            let createdAt = cache.refusals[refusal.dedupKey]?.createdAt ?? refusal.createdAt
            cache.refusals[refusal.dedupKey] = copy(refusal, createdAt: createdAt)
        }
    }

    func recordTerminalReview(
        projectID: UUID,
        proposalID: UUID,
        verdict: WorkStateTransitionTerminalVerdict
    ) throws -> WorkStateTransitionReviewWriteResult {
        try recordTerminalReviews(
            projectID: projectID,
            reviews: [.init(proposalID: proposalID, verdict: verdict)]
        )
    }

    func recordTerminalReviews(
        projectID: UUID,
        reviews: [WorkStateTransitionTerminalReview]
    ) throws -> WorkStateTransitionReviewWriteResult {
        var requestedByDedup: [String: WorkStateTransitionReviewStatus] = [:]
        for review in reviews {
            guard let proposal = cache.proposals.values.first(where: { $0.id == review.proposalID }) else {
                return .refused(.unknownProposal)
            }
            guard proposal.projectID == projectID else { return .refused(.projectMismatch) }
            let requested = review.verdict.reviewStatus
            if let duplicate = requestedByDedup[proposal.dedupKey], duplicate != requested {
                return .refused(.terminalVerdictConflict)
            }
            requestedByDedup[proposal.dedupKey] = requested
        }
        for (dedupKey, requested) in requestedByDedup {
            if let existing = cache.reviews[dedupKey], existing != requested {
                return .refused(.terminalVerdictConflict)
            }
        }
        let hasNewReview = requestedByDedup.contains { cache.reviews[$0.key] == nil }
        guard hasNewReview else { return .alreadyRecorded }
        if let saveError { throw saveError }
        for (dedupKey, requested) in requestedByDedup {
            cache.reviews[dedupKey] = requested
        }
        return .recorded
    }

    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) throws -> WorkStateTransitionReviewWriteResult {
        guard let group = cache.ambiguousMatchGroups.values.first(where: { $0.id == groupID }) else {
            return .refused(.unknownAmbiguityGroup)
        }
        guard group.projectID == projectID else { return .refused(.projectMismatch) }
        guard group.accepts(selection) else { return .refused(.invalidAmbiguitySelection) }
        if let existing = cache.ambiguityReviews[groupID] {
            return existing.matches(selection)
                ? .alreadyRecorded
                : .refused(.terminalVerdictConflict)
        }
        let siblings = cache.proposals.values.filter {
            $0.projectID == group.projectID
                && $0.workStateKind == group.workStateKind
                && $0.currentObjectID == group.incomingObjectID
                && $0.previousStateID.map(group.priorCandidateIDs.contains) == true
        }
        guard siblings.count == group.priorCandidateIDs.count else {
            return .refused(.incompleteAmbiguityGroup)
        }
        let selectedPriorID: UUID?
        switch selection {
        case .priorCandidate(let id): selectedPriorID = id
        case .new: selectedPriorID = nil
        }
        for sibling in siblings {
            let status: WorkStateTransitionReviewStatus =
                sibling.previousStateID == selectedPriorID && selectedPriorID != nil
                ? .approved : .rejected
            if let existing = cache.reviews[sibling.dedupKey], existing != status {
                return .refused(.terminalVerdictConflict)
            }
        }
        if let saveError { throw saveError }
        for sibling in siblings {
            cache.reviews[sibling.dedupKey] =
                sibling.previousStateID == selectedPriorID && selectedPriorID != nil
                ? .approved : .rejected
        }
        cache.ambiguityReviews[groupID] = WorkStateAmbiguityReviewState(
            groupID: groupID,
            projectID: projectID,
            selectionKind: selectedPriorID == nil ? .new : .priorCandidate,
            selectedPriorStateID: selectedPriorID,
            reviewedAt: reviewedAt
        )
        return .recorded
    }

    private func sortedProposals() -> [WorkStateTransitionProposal] {
        cache.proposals.values.map { proposal in
            copy(
                proposal,
                reviewStatus: cache.reviews[proposal.dedupKey] ?? .pendingReview,
                createdAt: proposal.createdAt
            )
        }.sorted { $0.dedupKey < $1.dedupKey }
    }

    // MARK: - Meeting deletion

    func recordMeetingDeletionIntent(_ intent: MeetingDeletionIntent) {
        cache.meetingDeletionIntents[intent.storageKey] = intent
    }

    func pendingMeetingDeletionIntents() -> [MeetingDeletionIntent] {
        cache.meetingDeletionIntents.values.sorted { $0.storageKey < $1.storageKey }
    }

    func applyMeetingDeletion(_ intent: MeetingDeletionIntent) {
        let closure = MeetingDeletionClosure.resolve(
            meetingID: intent.meetingID,
            projectID: intent.projectID,
            removedWorkStateIDs: Set(intent.removedWorkStateIDs),
            proposals: Array(cache.proposals.values),
            ambiguousMatchGroups: Array(cache.ambiguousMatchGroups.values),
            refusals: Array(cache.refusals.values),
            applyIntents: Array(cache.applyIntents.values)
        )
        for key in closure.proposalKeys {
            cache.proposals.removeValue(forKey: key)
            cache.reviews.removeValue(forKey: key)
        }
        for key in closure.ambiguousMatchGroupKeys {
            cache.ambiguousMatchGroups.removeValue(forKey: key)
        }
        for key in closure.refusalKeys { cache.refusals.removeValue(forKey: key) }
        for groupID in closure.ambiguityGroupIDs {
            cache.ambiguityReviews.removeValue(forKey: groupID)
        }
        for key in closure.applyIntentKeys { cache.applyIntents.removeValue(forKey: key) }
    }

    func clearMeetingDeletionIntent(_ intent: MeetingDeletionIntent) {
        cache.meetingDeletionIntents.removeValue(forKey: intent.storageKey)
    }

    // MARK: - Project deletion

    func recordProjectDeletionIntent(_ intent: ProjectDeletionIntent) {
        cache.projectDeletionIntents[intent.storageKey] = intent
    }

    func pendingProjectDeletionIntents() -> [ProjectDeletionIntent] {
        cache.projectDeletionIntents.values.sorted { $0.storageKey < $1.storageKey }
    }

    func applyProjectDeletion(_ intent: ProjectDeletionIntent) {
        let closure = ProjectDeletionClosure.resolve(
            projectID: intent.projectID,
            proposals: Array(cache.proposals.values),
            ambiguousMatchGroups: Array(cache.ambiguousMatchGroups.values),
            ambiguityReviews: Array(cache.ambiguityReviews.values),
            refusals: Array(cache.refusals.values),
            applyIntents: Array(cache.applyIntents.values),
            meetingDeletionIntents: Array(cache.meetingDeletionIntents.values)
        )
        for key in closure.proposalKeys {
            cache.proposals.removeValue(forKey: key)
            cache.reviews.removeValue(forKey: key)
        }
        for key in closure.ambiguousMatchGroupKeys {
            cache.ambiguousMatchGroups.removeValue(forKey: key)
        }
        for key in closure.refusalKeys { cache.refusals.removeValue(forKey: key) }
        for groupID in closure.ambiguityGroupIDs {
            cache.ambiguityReviews.removeValue(forKey: groupID)
        }
        for key in closure.applyIntentKeys { cache.applyIntents.removeValue(forKey: key) }
        for key in closure.meetingDeletionIntentKeys {
            cache.meetingDeletionIntents.removeValue(forKey: key)
        }
        cache.projectDeletionIntents.removeValue(forKey: intent.storageKey)
    }
}

private func copy(
    _ proposal: WorkStateTransitionProposal,
    reviewStatus: WorkStateTransitionReviewStatus,
    createdAt: Date
) -> WorkStateTransitionProposal {
    WorkStateTransitionProposal(
        id: proposal.id,
        projectID: proposal.projectID,
        workStateKind: proposal.workStateKind,
        transitionKind: proposal.transitionKind,
        previousStateID: proposal.previousStateID,
        currentObjectID: proposal.currentObjectID,
        sourceMeetingID: proposal.sourceMeetingID,
        evidence: proposal.evidence,
        basis: proposal.basis,
        progressDisposition: proposal.progressDisposition,
        reasons: proposal.reasons,
        requiresConfirmation: proposal.requiresConfirmation,
        reviewStatus: reviewStatus,
        relations: proposal.relations,
        dedupKey: proposal.dedupKey,
        createdAt: createdAt
    )
}

private func copy(
    _ refusal: WorkStateTransitionRefusalRecord,
    createdAt: Date
) -> WorkStateTransitionRefusalRecord {
    WorkStateTransitionRefusalRecord(copying: refusal, createdAt: createdAt)
}
