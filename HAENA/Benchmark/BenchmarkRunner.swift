import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Run options

/// What a run records about *itself* rather than about a case: which benchmark, which model, which
/// prompt, which commit.
///
/// Separate from `BenchmarkPreparedCase` because these values are identical for every case in a run
/// and must appear identically in every artifact it writes — an artifact whose provenance differed
/// case by case could not be compared with another run at all.
struct BenchmarkRunOptions: Equatable, Sendable {
    let benchmark: String
    let provider: BenchmarkProviderSelection
    let modelID: String
    let promptRevision: String
    let extractionSchemaVersion: String
    let gitRevision: String
}

// MARK: - Outcomes

/// One case's outcome: an artifact, or the reason the case could not be run at all.
///
/// A failure is a value rather than a thrown error because one unreadable case must not abort a
/// 16-case run — the other fifteen artifacts are still worth having, and the failure still has to
/// appear in the report rather than in a log nobody reads.
enum BenchmarkCaseOutcome: Sendable {
    case produced(PredictionArtifact)
    case failed(caseID: String, error: BenchmarkRunFailure)
}

enum BenchmarkRunFailure: String, Equatable, Sendable {
    /// `WorkStateExtractor.extract` threw. The underlying `WorkStateExtractionError` is deliberately
    /// dropped: it is provider-shaped detail, and the harness's job is to report that this case has
    /// no prediction, not to describe someone's HTTP status code in a benchmark artifact.
    case extractorFailed
    /// The case file could not be turned into extractor input (bad schema version, empty or
    /// duplicated transcript). Raised by the caller that prepares cases, not by the runner, which
    /// only ever sees cases that were prepared successfully.
    case adapterFailed
}

/// Counts only. This type must never gain a precision, recall, accuracy, or score field: the gold
/// it would be measured against does not exist yet, and a zero would read as a real result.
struct BenchmarkRunReport: Equatable, Sendable {
    let benchmark: String
    let runMode: String
    let caseCount: Int
    let producedCount: Int
    let failedCount: Int
    let rawProposalCount: Int
    let mappedProposalCount: Int
    let rejectedProposalCount: Int
    let unscoredCount: Int
    let caseIDs: [String]
}

extension BenchmarkRunReport {
    /// Folds in cases that never reached the extractor, so the written report accounts for every
    /// case that was *requested* rather than quietly shrinking to the ones that happened to load.
    func including(failedCaseIDs: [String]) -> BenchmarkRunReport {
        guard !failedCaseIDs.isEmpty else {
            return self
        }
        return BenchmarkRunReport(
            benchmark: benchmark,
            runMode: runMode,
            caseCount: caseCount + failedCaseIDs.count,
            producedCount: producedCount,
            failedCount: failedCount + failedCaseIDs.count,
            rawProposalCount: rawProposalCount,
            mappedProposalCount: mappedProposalCount,
            rejectedProposalCount: rejectedProposalCount,
            unscoredCount: unscoredCount,
            caseIDs: caseIDs + failedCaseIDs
        )
    }
}

/// `Encodable` in a same-file extension rather than on the declaration, so the type itself stays
/// exactly the counts-only value described above and the serialisation stays an implementation
/// detail of writing `run-report.json`.
extension BenchmarkRunReport: Encodable {
    enum CodingKeys: String, CodingKey {
        case benchmark
        case runMode = "run_mode"
        case caseCount = "case_count"
        case producedCount = "produced_count"
        case failedCount = "failed_count"
        case rawProposalCount = "raw_proposal_count"
        case mappedProposalCount = "mapped_proposal_count"
        case rejectedProposalCount = "rejected_proposal_count"
        case unscoredCount = "unscored_count"
        case caseIDs = "case_ids"
    }
}

// MARK: - Runner

/// Runs the app's real extraction seam over prepared benchmark cases.
///
/// It holds no `ProjectRepository` and constructs none: a benchmark run must not be able to write
/// into a user's projects even by accident, and the absence of the dependency is the proof. That is
/// also why `WorkStateExtractionService` — the app's own orchestrator — is not reused here despite
/// doing the same two steps: it saves what it maps.
struct BenchmarkRunner: Sendable {
    let extractor: any WorkStateExtractor
    /// Supplies `executedAt`, the one field of an artifact that is *meant* to move between runs.
    let now: @Sendable () -> Date

    init(extractor: any WorkStateExtractor, now: @escaping @Sendable () -> Date = Date.init) {
        self.extractor = extractor
        self.now = now
    }

    /// Every timestamp the mapper stamps onto a domain object.
    ///
    /// Fixed to the adapter's synthetic meeting date rather than to `now()`: `createdAt`/`updatedAt`
    /// on a benchmark proposal describe nothing real, and letting them move would make two runs of
    /// the same input differ in fields that carry no information.
    static let mappingDate = BenchmarkExtractionInputAdapter.syntheticMeetingDate

    // MARK: Running

    /// Cases are run one after another, not concurrently: the artifact order must be the case
    /// order for a diff between two runs to be readable, and a provider-backed run must not fan out
    /// into parallel requests nobody asked for.
    func run(
        _ preparedCases: [BenchmarkPreparedCase],
        options: BenchmarkRunOptions
    ) async -> (report: BenchmarkRunReport, outcomes: [BenchmarkCaseOutcome]) {
        var outcomes: [BenchmarkCaseOutcome] = []
        outcomes.reserveCapacity(preparedCases.count)
        for preparedCase in preparedCases {
            outcomes.append(await run(preparedCase, options: options))
        }
        return (Self.report(for: outcomes, options: options), outcomes)
    }

    func run(_ preparedCase: BenchmarkPreparedCase, options: BenchmarkRunOptions) async -> BenchmarkCaseOutcome {
        let result: WorkStateExtractionResult
        do {
            result = try await extractor.extract(from: preparedCase.extractionInput)
        } catch {
            return .failed(caseID: preparedCase.caseID, error: .extractorFailed)
        }

        let slots = Self.slots(in: result)

        var raw: [BenchmarkRawProposal] = []
        raw.reserveCapacity(slots.count)
        var mapped: [BenchmarkMappedProposal] = []
        // Input-stage records first: they describe the case as it was handed to the model, and
        // they exist whether or not the model said anything at all.
        var rejected: [BenchmarkRejectionRecord] = Self.inputRejections(for: preparedCase)

        for (ordinal, slot) in slots.enumerated() {
            raw.append(Self.rawProposal(slot, ordinal: ordinal, preparedCase: preparedCase))

            switch Self.mapOne(slot, ordinal: ordinal, preparedCase: preparedCase, options: options, metadata: result.metadata) {
            case .mapped(let proposal):
                mapped.append(proposal)
            case .rejected(let record):
                rejected.append(record)
            }
        }

        if let mismatch = Self.crossCheck(
            result,
            preparedCase: preparedCase,
            options: options,
            mappedCount: mapped.count,
            rejectedCount: slots.count - mapped.count
        ) {
            rejected.append(mismatch)
        }

        return .produced(
            PredictionArtifact(
                artifactSchemaVersion: PredictionArtifact.schemaVersion,
                artifactKind: PredictionArtifact.artifactKind,
                benchmark: options.benchmark,
                caseID: preparedCase.caseID,
                split: preparedCase.split,
                datasetSchemaVersion: preparedCase.datasetSchemaVersion,
                sourceCaseHash: preparedCase.sourceCaseHash,
                extractionSchemaVersion: options.extractionSchemaVersion,
                promptRevision: options.promptRevision,
                gitRevision: options.gitRevision,
                provider: options.provider.identifier,
                modelID: options.modelID,
                runMode: options.provider.runMode,
                executedAt: now(),
                scoring: Self.scoring(for: preparedCase),
                inputSummary: Self.inputSummary(for: preparedCase),
                raw: raw,
                mapped: mapped,
                rejected: rejected
            )
        )
    }

    // MARK: Proposal ordering

    /// Flattens one extractor result into a single ordered list.
    ///
    /// The order — decisions, action items, open questions, agenda items, each in the order the
    /// model returned them — *is* the `ordinal` numbering, and `ordinal` is what ties a raw
    /// proposal, its mapped form or its rejection, and its derived UUID together. Changing this
    /// order renumbers every artifact ever produced, so it does not change.
    private static func slots(in result: WorkStateExtractionResult) -> [ProposalSlot] {
        result.decisions.map(ProposalSlot.decision)
            + result.actionItems.map(ProposalSlot.actionItem)
            + result.openQuestions.map(ProposalSlot.openQuestion)
            + result.nextAgendaItems.map(ProposalSlot.agendaItem)
    }

    /// One proposal of any of the four kinds, so the runner can walk them in one loop instead of
    /// four near-identical ones — and, crucially, so each can be handed to the mapper *alone*.
    private enum ProposalSlot: Sendable {
        case decision(ProposedDecision)
        case actionItem(ProposedActionItem)
        case openQuestion(ProposedOpenQuestion)
        case agendaItem(ProposedAgendaItem)

        var kind: BenchmarkProposalKind {
            switch self {
            case .decision: return .decision
            case .actionItem: return .actionItem
            case .openQuestion: return .openQuestion
            case .agendaItem: return .agendaItem
            }
        }

        var evidence: ProposedEvidence {
            switch self {
            case .decision(let proposal): return proposal.evidence
            case .actionItem(let proposal): return proposal.evidence
            case .openQuestion(let proposal): return proposal.evidence
            case .agendaItem(let proposal): return proposal.evidence
            }
        }

        /// The statement / title / question, whichever this kind calls its main content.
        var text: String {
            switch self {
            case .decision(let proposal): return proposal.statement
            case .actionItem(let proposal): return proposal.title
            case .openQuestion(let proposal): return proposal.question
            case .agendaItem(let proposal): return proposal.title
            }
        }

        /// The rationale / details / reason, whichever this kind has. Open questions have none.
        var supportingText: String? {
            switch self {
            case .decision(let proposal): return proposal.rationale
            case .actionItem(let proposal): return proposal.details
            case .openQuestion: return nil
            case .agendaItem(let proposal): return proposal.reason
            }
        }

        var assigneeExpression: String? {
            guard case .actionItem(let proposal) = self else {
                return nil
            }
            return proposal.assigneeName
        }

        var dueDate: Date? {
            guard case .actionItem(let proposal) = self else {
                return nil
            }
            return proposal.dueDate
        }

        var confidence: Double {
            switch self {
            case .decision(let proposal): return proposal.confidence
            case .actionItem(let proposal): return proposal.confidence
            case .openQuestion(let proposal): return proposal.confidence
            case .agendaItem(let proposal): return proposal.confidence
            }
        }

        /// This proposal, and nothing else, as a result the mapper will accept.
        ///
        /// Mapping one proposal at a time is the whole reason this type exists: `ValidatedWorkState`
        /// reports rejections as a flat list with no back-reference to the proposal that caused
        /// them, so a batch of six proposals yielding two rejections says nothing about *which*
        /// two. A one-proposal batch yields exactly one accept or one reject, and the attribution
        /// is then a fact rather than an inference from array positions.
        func isolatedResult(metadata: ModelRunMetadata) -> WorkStateExtractionResult {
            switch self {
            case .decision(let proposal):
                return WorkStateExtractionResult(decisions: [proposal], metadata: metadata)
            case .actionItem(let proposal):
                return WorkStateExtractionResult(actionItems: [proposal], metadata: metadata)
            case .openQuestion(let proposal):
                return WorkStateExtractionResult(openQuestions: [proposal], metadata: metadata)
            case .agendaItem(let proposal):
                return WorkStateExtractionResult(nextAgendaItems: [proposal], metadata: metadata)
            }
        }
    }

    // MARK: Raw capture

    /// The model's answer, unedited, with the corpus utterance id added beside the segment id it
    /// cited. Nothing here is trimmed, repaired, or dropped — `raw` is the record of what was
    /// actually said, and the only place a rejected proposal's content survives.
    private static func rawProposal(
        _ slot: ProposalSlot,
        ordinal: Int,
        preparedCase: BenchmarkPreparedCase
    ) -> BenchmarkRawProposal {
        BenchmarkRawProposal(
            ordinal: ordinal,
            kind: slot.kind,
            text: slot.text,
            supportingText: slot.supportingText,
            assigneeExpression: slot.assigneeExpression,
            dueDate: slot.dueDate,
            confidence: slot.confidence,
            citedSegmentID: slot.evidence.segmentID,
            citedUtteranceID: preparedCase.utteranceID(forRawSegmentID: slot.evidence.segmentID),
            quote: slot.evidence.quote
        )
    }

    // MARK: Mapping

    private enum SlotOutcome {
        case mapped(BenchmarkMappedProposal)
        case rejected(BenchmarkRejectionRecord)
    }

    private static func mapOne(
        _ slot: ProposalSlot,
        ordinal: Int,
        preparedCase: BenchmarkPreparedCase,
        options: BenchmarkRunOptions,
        metadata: ModelRunMetadata
    ) -> SlotOutcome {
        // Derived from the case and the ordinal rather than generated, so re-running the same input
        // yields byte-identical artifacts and two runs can be diffed at all.
        let id = BenchmarkIdentity.proposalID(
            benchmark: options.benchmark,
            caseID: preparedCase.caseID,
            ordinal: ordinal
        )
        let validated = WorkStateProposalMapper.map(
            slot.isolatedResult(metadata: metadata),
            meeting: preparedCase.meeting,
            now: mappingDate,
            makeID: { id }
        )

        if let rejection = validated.rejected.first {
            return .rejected(rejectionRecord(for: slot, ordinal: ordinal, reason: benchmarkReason(for: rejection.reason), preparedCase: preparedCase))
        }

        let proposal: BenchmarkMappedProposal?
        switch slot {
        case .decision:
            proposal = validated.decisions.first.flatMap { decision in
                mappedProposal(
                    ordinal: ordinal,
                    kind: .decision,
                    id: decision.id,
                    text: decision.statement,
                    assigneeParticipantID: nil,
                    dueDate: nil,
                    confidence: decision.confidence,
                    evidence: decision.evidence,
                    status: decision.status.rawValue,
                    preparedCase: preparedCase
                )
            }
        case .actionItem:
            proposal = validated.actionItems.first.flatMap { item in
                mappedProposal(
                    ordinal: ordinal,
                    kind: .actionItem,
                    id: item.id,
                    text: item.title,
                    assigneeParticipantID: item.assigneeID,
                    dueDate: item.dueDate,
                    confidence: item.confidence,
                    evidence: item.evidence,
                    status: item.status.rawValue,
                    preparedCase: preparedCase
                )
            }
        case .openQuestion:
            proposal = validated.openQuestions.first.flatMap { question in
                mappedProposal(
                    ordinal: ordinal,
                    kind: .openQuestion,
                    id: question.id,
                    text: question.question,
                    assigneeParticipantID: nil,
                    dueDate: nil,
                    confidence: question.confidence,
                    evidence: question.evidence,
                    status: question.status.rawValue,
                    preparedCase: preparedCase
                )
            }
        case .agendaItem:
            proposal = validated.agendaItems.first.flatMap { item in
                mappedProposal(
                    ordinal: ordinal,
                    kind: .agendaItem,
                    id: item.id,
                    text: item.title,
                    assigneeParticipantID: nil,
                    dueDate: nil,
                    confidence: item.confidence,
                    evidence: item.evidence,
                    status: item.status.rawValue,
                    preparedCase: preparedCase
                )
            }
        }

        guard let proposal else {
            // Neither accepted nor rejected, or accepted without the evidence the mapper is
            // supposed to attach. Not reachable today; recorded rather than dropped, because a
            // proposal that vanishes between `raw` and `mapped` would silently break the
            // `raw.count == mapped.count + mapper rejections` invariant this harness reports on.
            return .rejected(rejectionRecord(for: slot, ordinal: ordinal, reason: .mapperValidationFailed, preparedCase: preparedCase))
        }
        return .mapped(proposal)
    }

    private static func mappedProposal(
        ordinal: Int,
        kind: BenchmarkProposalKind,
        id: UUID,
        text: String,
        assigneeParticipantID: UUID?,
        dueDate: Date?,
        confidence: Confidence?,
        evidence: EvidenceReference?,
        status: String,
        preparedCase: BenchmarkPreparedCase
    ) -> BenchmarkMappedProposal? {
        // `AgendaItem` carries both as optionals, and an accepted proposal without evidence is not
        // something the harness is willing to describe as grounded.
        guard let evidence, let confidence else {
            return nil
        }
        return BenchmarkMappedProposal(
            ordinal: ordinal,
            kind: kind,
            id: id,
            text: text,
            assigneeParticipantID: assigneeParticipantID,
            assigneeSpeakerLabel: speakerLabel(forParticipant: assigneeParticipantID, in: preparedCase),
            dueDate: dueDate,
            confidence: confidence.value,
            evidenceSegmentID: evidence.transcriptSegmentID,
            evidenceUtteranceID: preparedCase.utteranceIDBySegmentID[evidence.transcriptSegmentID],
            evidenceQuote: evidence.quote,
            status: status
        )
    }

    /// Nil whenever the mapper refused to resolve an owner. Read back off the participant the
    /// mapper chose rather than off the model's string, so the artifact records who the *app*
    /// would have assigned, not who the model named.
    private static func speakerLabel(forParticipant id: UUID?, in preparedCase: BenchmarkPreparedCase) -> String? {
        guard let id,
              let participant = preparedCase.meeting.participants.first(where: { $0.id == id }) else {
            return nil
        }
        return participant.speakerLabel ?? participant.displayName
    }

    // MARK: Rejections

    private static func rejectionRecord(
        for slot: ProposalSlot,
        ordinal: Int,
        reason: BenchmarkRejectionReason,
        preparedCase: BenchmarkPreparedCase
    ) -> BenchmarkRejectionRecord {
        BenchmarkRejectionRecord(
            stage: .mapper,
            kind: slot.kind,
            reason: reason,
            proposalOrdinal: ordinal,
            citedSegmentID: slot.evidence.segmentID,
            citedUtteranceID: preparedCase.utteranceID(forRawSegmentID: slot.evidence.segmentID),
            utteranceID: nil
        )
    }

    /// Rejections that exist before any model runs: utterances the corpus could not attribute to a
    /// speaker. Reported per utterance rather than as a count so a reader can go look at the
    /// specific lines the harness could not attribute.
    private static func inputRejections(for preparedCase: BenchmarkPreparedCase) -> [BenchmarkRejectionRecord] {
        preparedCase.unknownSpeakerUtteranceIDs.map { utteranceID in
            BenchmarkRejectionRecord(
                stage: .input,
                kind: nil,
                reason: .unknownSpeaker,
                proposalOrdinal: nil,
                citedSegmentID: nil,
                citedUtteranceID: nil,
                utteranceID: utteranceID
            )
        }
    }

    /// Switched on the raw value rather than on the case list on purpose: a reason added to
    /// `RejectedProposal.Reason` later must land on `.mapperValidationFailed` — "the mapper said no
    /// and the harness does not yet have a word for why" — instead of being mislabelled as one of
    /// the reasons above.
    static func benchmarkReason(for reason: RejectedProposal.Reason) -> BenchmarkRejectionReason {
        switch reason.rawValue {
        case RejectedProposal.Reason.unknownSegment.rawValue:
            return .evidenceNotFound
        case RejectedProposal.Reason.quoteNotInTranscript.rawValue:
            return .quoteNotInTranscript
        case RejectedProposal.Reason.confidenceOutOfRange.rawValue:
            return .confidenceOutOfRange
        case RejectedProposal.Reason.emptyContent.rawValue:
            return .missingRequiredField
        default:
            return .mapperValidationFailed
        }
    }

    /// Re-maps the whole result in one call and checks that it agrees with the per-proposal pass.
    ///
    /// The per-proposal pass can only see proposals `slots(in:)` knows how to flatten. If
    /// `WorkStateExtractionResult` gains a fifth category, or the mapper starts producing more than
    /// one outcome per proposal, this is what notices: the whole-result mapping counts what the
    /// mapper actually did, and a disagreement becomes a recorded rejection rather than a silently
    /// shorter artifact. The domain objects it produces are discarded.
    private static func crossCheck(
        _ result: WorkStateExtractionResult,
        preparedCase: BenchmarkPreparedCase,
        options: BenchmarkRunOptions,
        mappedCount: Int,
        rejectedCount: Int
    ) -> BenchmarkRejectionRecord? {
        var ordinal = 0
        let whole = WorkStateProposalMapper.map(
            result,
            meeting: preparedCase.meeting,
            now: mappingDate,
            makeID: {
                defer { ordinal += 1 }
                return BenchmarkIdentity.proposalID(
                    benchmark: options.benchmark,
                    caseID: preparedCase.caseID,
                    ordinal: ordinal
                )
            }
        )

        let accepted = whole.decisions.count
            + whole.actionItems.count
            + whole.openQuestions.count
            + whole.agendaItems.count
        guard accepted != mappedCount || whole.rejected.count != rejectedCount else {
            return nil
        }

        return BenchmarkRejectionRecord(
            stage: .mapper,
            kind: nil,
            reason: .unsupportedProposalType,
            proposalOrdinal: nil,
            citedSegmentID: nil,
            citedUtteranceID: nil,
            utteranceID: nil
        )
    }

    // MARK: Artifact fields

    /// Always `.unscored`. The reason distinguishes "there is no confirmed gold to score against"
    /// from "there is, and this harness still does not score" — both are honest, and neither is a
    /// number.
    private static func scoring(for preparedCase: BenchmarkPreparedCase) -> BenchmarkScoring {
        BenchmarkScoring(
            status: .unscored,
            reason: preparedCase.isGoldPending ? "human_review_pending" : "scoring_not_implemented"
        )
    }

    /// Shape of the input, not the input itself: counts and speaker labels, never transcript text.
    /// The transcript already exists in the corpus, and copying it into every artifact would turn a
    /// provenance record into a second, un-versioned copy of the dataset.
    private static func inputSummary(for preparedCase: BenchmarkPreparedCase) -> PredictionArtifact.InputSummary {
        PredictionArtifact.InputSummary(
            utteranceCount: preparedCase.utteranceCount,
            participantCount: preparedCase.meeting.participants.count,
            speakerLabels: preparedCase.meeting.participants.map { $0.speakerLabel ?? $0.displayName }.sorted(),
            unknownSpeakerUtteranceCount: preparedCase.unknownSpeakerUtteranceIDs.count
        )
    }

    // MARK: Reporting

    private static func report(
        for outcomes: [BenchmarkCaseOutcome],
        options: BenchmarkRunOptions
    ) -> BenchmarkRunReport {
        var produced = 0
        var failed = 0
        var raw = 0
        var mapped = 0
        var rejected = 0
        var unscored = 0
        var caseIDs: [String] = []
        caseIDs.reserveCapacity(outcomes.count)

        for outcome in outcomes {
            switch outcome {
            case .produced(let artifact):
                produced += 1
                raw += artifact.raw.count
                mapped += artifact.mapped.count
                rejected += artifact.rejected.count
                if artifact.scoring.status == .unscored {
                    unscored += 1
                }
                caseIDs.append(artifact.caseID)
            case .failed(let caseID, _):
                failed += 1
                caseIDs.append(caseID)
            }
        }

        return BenchmarkRunReport(
            benchmark: options.benchmark,
            runMode: options.provider.runMode,
            caseCount: outcomes.count,
            producedCount: produced,
            failedCount: failed,
            rawProposalCount: raw,
            mappedProposalCount: mapped,
            rejectedProposalCount: rejected,
            unscoredCount: unscored,
            caseIDs: caseIDs
        )
    }
}
