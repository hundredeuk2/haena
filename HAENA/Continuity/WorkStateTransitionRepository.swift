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

struct WorkStateTransitionTerminalReview: Equatable, Sendable {
    let proposalID: UUID
    let verdict: WorkStateTransitionTerminalVerdict
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
/// Schema 3 adds terminal ambiguity selections. Missing newer arrays decode as empty so v1/v2
/// files migrate without losing proposals, terminal review state, ambiguity groups, or refusals.
struct WorkStateTransitionStoreFile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let readableSchemaVersions: Set<Int> = [1, 2, 3]

    var schemaVersion: Int
    var proposals: [WorkStateTransitionProposal]
    var reviews: [WorkStateTransitionReviewState]
    var ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup]
    var ambiguityReviews: [WorkStateAmbiguityReviewState]
    var refusals: [WorkStateTransitionRefusalRecord]

    init(
        schemaVersion: Int = WorkStateTransitionStoreFile.currentSchemaVersion,
        proposals: [WorkStateTransitionProposal] = [],
        reviews: [WorkStateTransitionReviewState] = [],
        ambiguousMatchGroups: [WorkStateAmbiguousMatchGroup] = [],
        ambiguityReviews: [WorkStateAmbiguityReviewState] = [],
        refusals: [WorkStateTransitionRefusalRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.proposals = proposals
        self.reviews = reviews
        self.ambiguousMatchGroups = ambiguousMatchGroups
        self.ambiguityReviews = ambiguityReviews
        self.refusals = refusals
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, proposals, reviews, ambiguousMatchGroups, ambiguityReviews, refusals
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
}

private struct WorkStateTransitionStoreCache {
    var proposals: [String: WorkStateTransitionProposal] = [:]
    var reviews: [String: WorkStateTransitionReviewStatus] = [:]
    var ambiguousMatchGroups: [String: WorkStateAmbiguousMatchGroup] = [:]
    var ambiguityReviews: [UUID: WorkStateAmbiguityReviewState] = [:]
    var refusals: [String: WorkStateTransitionRefusalRecord] = [:]
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
        try persist(stored)
        cache = stored
        return .recorded
    }

    func resolveAmbiguity(
        projectID: UUID,
        groupID: UUID,
        selection: WorkStateAmbiguousMatchSelection,
        reviewedAt: Date
    ) throws -> WorkStateTransitionReviewWriteResult {
        var stored = try loadIfNeeded()
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
        try persist(stored)
        cache = stored
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
            refusals: sortedRefusals(stored)
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
