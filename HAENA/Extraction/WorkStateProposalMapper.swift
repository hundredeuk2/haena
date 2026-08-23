import CryptoKit
import Foundation

/// Why a proposal was thrown away instead of stored. Kept as data (not just a log line) so a
/// caller can report "the model returned 6 items, 2 could not be grounded in the transcript"
/// without re-running the extraction.
struct RejectedProposal: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case decision
        case actionItem
        case openQuestion
        case agendaItem
    }

    enum Reason: String, Equatable, Sendable {
        /// `segmentID` was malformed, or named a segment that is not part of this meeting.
        case unknownSegment
        /// The quote is not a verbatim substring of the cited segment's text.
        case quoteNotInTranscript
        case confidenceOutOfRange
        case emptyContent
        case invalidProviderLocalKey
        case duplicateProposalKey
    }

    let kind: Kind
    let reason: Reason
}

/// The result of validating one extractor run: domain models ready to store, plus the proposals
/// that failed validation. Both halves matter — a partially wrong model response must still yield
/// its verifiable items.
struct ValidatedWorkState: Equatable, Sendable {
    var decisions: [Decision] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [OpenQuestion] = []
    var agendaItems: [AgendaItem] = []
    var rejected: [RejectedProposal] = []

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty && agendaItems.isEmpty
    }
}

/// Which sidecar signal was rejected. Finite by construction so reports and persistence cannot
/// accidentally capture transcript text, a title, a name, or provider error prose.
struct RejectedContinuitySignal: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case progress
        case openQuestionResolution
        case decisionDerivedActionItem
        case decisionChange
    }

    enum Reason: String, Equatable, Sendable, CaseIterable {
        case missingEvidence
        case foreignMeetingEvidence
        case unknownPriorReference
        case unknownProposalKey
        case duplicateProposalKey
        case invalidTargetKind
        case stalePriorState
        case ambiguousSourceReference
        case invalidSignalKind
    }

    let kind: Kind
    let reason: Reason
}

/// Engine-ready sidecar values, kept separate from base work state so rejecting or persisting a
/// signal can never decide whether a grounded base object survives.
struct ValidatedContinuitySignals: Equatable, Sendable {
    var progressSignals: [WorkStateProgressSignal] = []
    var openQuestionResolutionLinks: [OpenQuestionResolutionLink] = []
    var decisionDerivedActionItemLinks: [DecisionDerivedActionItemLink] = []
    var decisionChangeLinks: [DecisionChangeLink] = []
    var rejected: [RejectedContinuitySignal] = []

    /// Re-checks every accepted prior UUID against a freshly built approved snapshot immediately
    /// before persistence. A stale prior reference rejects only its signal; incoming base state is
    /// deliberately not an argument that can be mutated.
    func revalidated(
        against currentPrior: ApprovedWorkStateSnapshot,
        incoming: ValidatedWorkState
    ) -> ValidatedContinuitySignals {
        let approvedQuestionIDs = Set(currentPrior.openQuestions.filter {
            $0.projectID == currentPrior.projectID && ApprovedWorkStatePolicy.isApproved($0)
        }.map(\.id))
        let approvedDecisionIDs = Set(currentPrior.decisions.filter {
            $0.projectID == currentPrior.projectID && ApprovedWorkStatePolicy.isApproved($0)
        }.map(\.id))
        let incomingDecisionIDs = Set(incoming.decisions.map(\.id))
        let approvedActionItemIDs = Set(currentPrior.actionItems.filter {
            $0.projectID == currentPrior.projectID && ApprovedWorkStatePolicy.isApproved($0)
        }.map(\.id))

        var acceptedProgressSignals: [WorkStateProgressSignal] = []
        var acceptedResolutionLinks: [OpenQuestionResolutionLink] = []
        var acceptedDerivedLinks: [DecisionDerivedActionItemLink] = []
        var acceptedChangeLinks: [DecisionChangeLink] = []
        var rejections = rejected

        for signal in progressSignals {
            // Only the prior-target form names stored state that can go stale between mapping and
            // persistence. An incoming target lives in this same run's `ValidatedWorkState`.
            guard let priorID = signal.priorActionItemID else {
                acceptedProgressSignals.append(signal)
                continue
            }
            if approvedActionItemIDs.contains(priorID) {
                acceptedProgressSignals.append(signal)
            } else {
                rejections.append(
                    RejectedContinuitySignal(kind: .progress, reason: .stalePriorState)
                )
            }
        }
        for link in decisionChangeLinks {
            if approvedDecisionIDs.contains(link.priorDecisionID),
               incomingDecisionIDs.contains(link.incomingDecisionID) {
                acceptedChangeLinks.append(link)
            } else {
                rejections.append(
                    RejectedContinuitySignal(kind: .decisionChange, reason: .stalePriorState)
                )
            }
        }

        for link in openQuestionResolutionLinks {
            if approvedQuestionIDs.contains(link.priorOpenQuestionID) {
                acceptedResolutionLinks.append(link)
            } else {
                rejections.append(
                    RejectedContinuitySignal(kind: .openQuestionResolution, reason: .stalePriorState)
                )
            }
        }
        for link in decisionDerivedActionItemLinks {
            if incomingDecisionIDs.contains(link.decisionID)
                || approvedDecisionIDs.contains(link.decisionID) {
                acceptedDerivedLinks.append(link)
            } else {
                rejections.append(
                    RejectedContinuitySignal(kind: .decisionDerivedActionItem, reason: .stalePriorState)
                )
            }
        }
        return ValidatedContinuitySignals(
            progressSignals: acceptedProgressSignals,
            openQuestionResolutionLinks: acceptedResolutionLinks,
            decisionDerivedActionItemLinks: acceptedDerivedLinks,
            decisionChangeLinks: acceptedChangeLinks,
            rejected: rejections
        )
    }
}

/// Complete two-stage mapper output. `workState` is safe to save independently; continuity is a
/// sidecar that may be partly or wholly rejected without changing the base arrays.
struct ValidatedWorkStateExtraction: Equatable, Sendable {
    var workState: ValidatedWorkState
    var continuitySignals: ValidatedContinuitySignals
    let providerLocalKeyToDomainID: [String: UUID]
}

/// Turns a provider's raw proposals into HAE.NA domain models, rejecting anything it cannot
/// ground in the stored transcript.
///
/// Three rules drive everything here:
/// 1. **Identity is ours.** Any ID a model returns is ignored; every stored object gets an
///    app-generated `UUID`. A model must not be able to overwrite an existing record by echoing
///    its ID back.
/// 2. **Evidence is verified, never repaired.** A quote must appear verbatim in the cited
///    segment. Items that fail are dropped and reported — never "fixed up" to fit.
/// 3. **Nothing is guessed.** An assignee resolves only on an unambiguous participant match; an
///    absent or unparseable due date stays nil rather than becoming an invented date.
enum WorkStateProposalMapper {
    static func map(
        _ result: WorkStateExtractionResult,
        meeting: Meeting,
        now: Date,
        priorReferenceMap: PriorWorkStateReferenceMap = .empty
    ) -> ValidatedWorkStateExtraction {
        var state = ValidatedWorkState()
        var acceptedKeys: [String: (kind: WorkStateKind, id: UUID)] = [:]
        let keyCounts = proposalKeyCounts(in: result)
        let duplicateKeys = Set(keyCounts.compactMap { $0.value > 1 ? $0.key : nil })

        for proposal in result.decisions {
            guard validateBaseKey(
                proposal.providerLocalKey,
                expectedKind: .decision,
                duplicateKeys: duplicateKeys,
                rejected: &state.rejected
            ) else { continue }
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.statement, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .decision, reason: reason))
            case .grounded(let grounded):
                state.decisions.append(
                    Decision(
                        id: deterministicID(for: proposal.providerLocalKey, kind: .decision, meeting: meeting),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        statement: proposal.statement.trimmed,
                        rationale: proposal.rationale?.trimmedNonEmpty,
                        status: .proposed,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                acceptedKeys[proposal.providerLocalKey] = (.decision, state.decisions.last!.id)
            }
        }

        for proposal in result.actionItems {
            guard validateBaseKey(
                proposal.providerLocalKey,
                expectedKind: .actionItem,
                duplicateKeys: duplicateKeys,
                rejected: &state.rejected
            ) else { continue }
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.title, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .actionItem, reason: reason))
            case .grounded(let grounded):
                // Attribution is intentionally resolved only after the evidence ID and quote have
                // been grounded. In particular, a model cannot name a real participant while
                // citing a fabricated segment and still cause that participant to own work.
                let attribution = resolve(
                    proposal.assigneeAttribution,
                    evidenceSegment: grounded.segment,
                    in: meeting
                )
                state.actionItems.append(
                    ActionItem(
                        id: deterministicID(for: proposal.providerLocalKey, kind: .actionItem, meeting: meeting),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        title: proposal.title.trimmed,
                        details: proposal.details?.trimmedNonEmpty,
                        assigneeID: attribution.assigneeID,
                        dueDate: proposal.dueDate,
                        status: .proposed,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        proposedAssigneeAttribution: attribution.provenance,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                acceptedKeys[proposal.providerLocalKey] = (.actionItem, state.actionItems.last!.id)
            }
        }

        for proposal in result.openQuestions {
            guard validateBaseKey(
                proposal.providerLocalKey,
                expectedKind: .openQuestion,
                duplicateKeys: duplicateKeys,
                rejected: &state.rejected
            ) else { continue }
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.question, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .openQuestion, reason: reason))
            case .grounded(let grounded):
                // `OpenQuestion` has no `.proposed` case — `.open` is its un-acted-on state, and
                // the accompanying evidence marks it as AI-derived rather than user-entered.
                state.openQuestions.append(
                    OpenQuestion(
                        id: deterministicID(for: proposal.providerLocalKey, kind: .openQuestion, meeting: meeting),
                        projectID: meeting.projectID,
                        meetingID: meeting.id,
                        question: proposal.question.trimmed,
                        status: .open,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence,
                        createdAt: now,
                        resolvedAt: nil
                    )
                )
                acceptedKeys[proposal.providerLocalKey] = (.openQuestion, state.openQuestions.last!.id)
            }
        }

        for proposal in result.nextAgendaItems {
            guard validateBaseKey(
                proposal.providerLocalKey,
                expectedKind: .agendaItem,
                duplicateKeys: duplicateKeys,
                rejected: &state.rejected
            ) else { continue }
            switch validate(proposal.evidence, confidence: proposal.confidence, content: proposal.title, in: meeting) {
            case .rejected(let reason):
                state.rejected.append(RejectedProposal(kind: .agendaItem, reason: reason))
            case .grounded(let grounded):
                state.agendaItems.append(
                    AgendaItem(
                        id: deterministicID(for: proposal.providerLocalKey, kind: .agendaItem, meeting: meeting),
                        projectID: meeting.projectID,
                        title: proposal.title.trimmed,
                        reason: proposal.reason.trimmed,
                        sourceMeetingID: meeting.id,
                        relatedActionItemID: nil,
                        relatedOpenQuestionID: nil,
                        status: .pending,
                        createdAt: now,
                        evidence: grounded.evidence,
                        confidence: grounded.confidence
                    )
                )
                acceptedKeys[proposal.providerLocalKey] = (.agendaItem, state.agendaItems.last!.id)
            }
        }

        let signals = mapSignals(
            result,
            meeting: meeting,
            acceptedKeys: acceptedKeys,
            duplicateKeys: duplicateKeys,
            priorReferenceMap: priorReferenceMap
        )
        return ValidatedWorkStateExtraction(
            workState: state,
            continuitySignals: signals,
            providerLocalKeyToDomainID: acceptedKeys.mapValues { $0.id }
        )
    }

    // MARK: - Provider-local identity

    private static func proposalKeyCounts(in result: WorkStateExtractionResult) -> [String: Int] {
        let keys = result.decisions.map(\.providerLocalKey)
            + result.actionItems.map(\.providerLocalKey)
            + result.openQuestions.map(\.providerLocalKey)
            + result.nextAgendaItems.map(\.providerLocalKey)
        return keys.reduce(into: [:]) { counts, key in counts[key, default: 0] += 1 }
    }

    private static func validateBaseKey(
        _ key: String,
        expectedKind: WorkStateKind,
        duplicateKeys: Set<String>,
        rejected: inout [RejectedProposal]
    ) -> Bool {
        let proposalKind = rejectedProposalKind(for: expectedKind)
        guard !duplicateKeys.contains(key) else {
            rejected.append(RejectedProposal(kind: proposalKind, reason: .duplicateProposalKey))
            return false
        }
        guard isValidProviderLocalKey(key, expectedKind: expectedKind) else {
            rejected.append(RejectedProposal(kind: proposalKind, reason: .invalidProviderLocalKey))
            return false
        }
        return true
    }

    /// Canonical shape is `<kind-prefix>_<positive integer>`, bounded to 32 ASCII
    /// lowercase/digit/underscore bytes and the provider schema's six-digit ordinal ceiling.
    /// Canonical positive integers do not have leading zeroes.
    static func isValidProviderLocalKey(_ key: String, expectedKind: WorkStateKind) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 32,
              key.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
              }) else {
            return false
        }
        let prefix: String
        switch expectedKind {
        case .decision: prefix = "decision_"
        case .actionItem: prefix = "action_"
        case .openQuestion: prefix = "question_"
        case .agendaItem: prefix = "agenda_"
        }
        guard key.hasPrefix(prefix) else { return false }
        let suffix = key.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.count <= 6,
              suffix.allSatisfy(\.isNumber), suffix.first != "0" else { return false }
        return suffix.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func rejectedProposalKind(for kind: WorkStateKind) -> RejectedProposal.Kind {
        switch kind {
        case .decision: return .decision
        case .actionItem: return .actionItem
        case .openQuestion: return .openQuestion
        case .agendaItem: return .agendaItem
        }
    }

    private static func deterministicID(
        for providerLocalKey: String,
        kind: WorkStateKind,
        meeting: Meeting
    ) -> UUID {
        let identity = [
            "haena.work-state-extraction.v1",
            meeting.projectID.uuidString.lowercased(),
            meeting.id.uuidString.lowercased(),
            kind.rawValue,
            providerLocalKey
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Continuity sidecar mapping

    private enum SignalEvidenceOutcome {
        case grounded(EvidenceReference)
        case rejected(RejectedContinuitySignal.Reason)
    }

    private static func validateSignalEvidence(
        _ proposed: ProposedEvidence?,
        in meeting: Meeting
    ) -> SignalEvidenceOutcome {
        guard let proposed else { return .rejected(.missingEvidence) }
        guard let segmentID = UUID(uuidString: proposed.segmentID),
              let segment = meeting.transcriptSegments.first(where: { $0.id == segmentID }) else {
            return .rejected(.foreignMeetingEvidence)
        }
        let quote = proposed.quote.trimmed
        guard !quote.isEmpty, segment.text.contains(quote) else {
            return .rejected(.missingEvidence)
        }
        return .grounded(
            EvidenceReference(
                meetingID: meeting.id,
                transcriptSegmentID: segment.id,
                quote: quote
            )
        )
    }

    private static func mapSignals(
        _ result: WorkStateExtractionResult,
        meeting: Meeting,
        acceptedKeys: [String: (kind: WorkStateKind, id: UUID)],
        duplicateKeys: Set<String>,
        priorReferenceMap: PriorWorkStateReferenceMap
    ) -> ValidatedContinuitySignals {
        var mapped = ValidatedContinuitySignals()

        for signal in result.progressSignals {
            let rejectionKind = RejectedContinuitySignal.Kind.progress
            guard let evidence = groundedSignalEvidence(
                signal.evidence,
                kind: rejectionKind,
                meeting: meeting,
                rejected: &mapped.rejected
            ) else { continue }
            guard let kind = signal.kind else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidSignalKind))
                continue
            }
            guard let targetType = signal.targetType else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                continue
            }
            switch targetType {
            case .incomingActionItem:
                guard !duplicateKeys.contains(signal.targetReference) else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .duplicateProposalKey))
                    continue
                }
                guard let target = acceptedKeys[signal.targetReference] else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownProposalKey))
                    continue
                }
                guard target.kind == .actionItem else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                    continue
                }
                mapped.progressSignals.append(
                    WorkStateProgressSignal(
                        kind: kind,
                        target: .incomingActionItem(target.id),
                        evidence: evidence
                    )
                )
            case .priorActionItem:
                // A prior reference is only ever resolved through the request-scoped allow-list, so
                // a model cannot name stored work by guessing an identifier, and a reference to the
                // wrong kind of object is a rejection rather than a coerced lookup.
                guard let prior = priorReferenceMap.domainReference(for: signal.targetReference),
                      prior.kind == .actionItem else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownPriorReference))
                    continue
                }
                mapped.progressSignals.append(
                    WorkStateProgressSignal(
                        kind: kind,
                        target: .priorActionItem(prior.domainID),
                        evidence: evidence
                    )
                )
            }
        }

        for link in result.decisionChangeLinks {
            let rejectionKind = RejectedContinuitySignal.Kind.decisionChange
            guard let evidence = groundedSignalEvidence(
                link.evidence,
                kind: rejectionKind,
                meeting: meeting,
                rejected: &mapped.rejected
            ) else { continue }
            guard let prior = priorReferenceMap.domainReference(for: link.priorDecisionReference),
                  prior.kind == .decision else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownPriorReference))
                continue
            }
            guard !duplicateKeys.contains(link.decisionKey) else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .duplicateProposalKey))
                continue
            }
            guard let incoming = acceptedKeys[link.decisionKey] else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownProposalKey))
                continue
            }
            guard incoming.kind == .decision else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                continue
            }
            mapped.decisionChangeLinks.append(
                DecisionChangeLink(
                    priorDecisionID: prior.domainID,
                    incomingDecisionID: incoming.id,
                    evidence: evidence
                )
            )
        }

        for link in result.openQuestionResolutionLinks {
            let rejectionKind = RejectedContinuitySignal.Kind.openQuestionResolution
            guard let evidence = groundedSignalEvidence(
                link.evidence,
                kind: rejectionKind,
                meeting: meeting,
                rejected: &mapped.rejected
            ) else { continue }
            guard let targetKind = link.targetKind else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                continue
            }
            guard let prior = priorReferenceMap.domainReference(for: link.priorOpenQuestionReference),
                  prior.kind == .openQuestion else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownPriorReference))
                continue
            }
            guard !duplicateKeys.contains(link.targetProviderLocalKey) else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .duplicateProposalKey))
                continue
            }
            guard let target = acceptedKeys[link.targetProviderLocalKey] else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownProposalKey))
                continue
            }
            guard target.kind == workStateKind(for: targetKind) else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                continue
            }
            mapped.openQuestionResolutionLinks.append(
                OpenQuestionResolutionLink(
                    priorOpenQuestionID: prior.domainID,
                    targetKind: targetKind,
                    targetObjectID: target.id,
                    evidence: evidence
                )
            )
        }

        for link in result.decisionDerivedActionItemLinks {
            let rejectionKind = RejectedContinuitySignal.Kind.decisionDerivedActionItem
            guard let evidence = groundedSignalEvidence(
                link.evidence,
                kind: rejectionKind,
                meeting: meeting,
                rejected: &mapped.rejected
            ) else { continue }
            let sourceKey = link.sourceDecisionKey?.trimmedNonEmpty
            let priorReference = link.priorDecisionReference?.trimmedNonEmpty
            guard (sourceKey == nil) != (priorReference == nil) else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .ambiguousSourceReference))
                continue
            }
            guard !duplicateKeys.contains(link.actionItemKey) else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .duplicateProposalKey))
                continue
            }
            guard let action = acceptedKeys[link.actionItemKey] else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownProposalKey))
                continue
            }
            guard action.kind == .actionItem else {
                mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                continue
            }

            let decisionID: UUID
            if let sourceKey {
                guard !duplicateKeys.contains(sourceKey) else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .duplicateProposalKey))
                    continue
                }
                guard let source = acceptedKeys[sourceKey] else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownProposalKey))
                    continue
                }
                guard source.kind == .decision else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .invalidTargetKind))
                    continue
                }
                decisionID = source.id
            } else {
                guard let prior = priorReferenceMap.domainReference(for: priorReference!),
                      prior.kind == .decision else {
                    mapped.rejected.append(.init(kind: rejectionKind, reason: .unknownPriorReference))
                    continue
                }
                decisionID = prior.domainID
            }

            mapped.decisionDerivedActionItemLinks.append(
                DecisionDerivedActionItemLink(
                    decisionID: decisionID,
                    actionItemID: action.id,
                    evidence: evidence
                )
            )
        }

        return mapped
    }

    private static func groundedSignalEvidence(
        _ evidence: ProposedEvidence?,
        kind: RejectedContinuitySignal.Kind,
        meeting: Meeting,
        rejected: inout [RejectedContinuitySignal]
    ) -> EvidenceReference? {
        switch validateSignalEvidence(evidence, in: meeting) {
        case .grounded(let grounded):
            return grounded
        case .rejected(let reason):
            rejected.append(RejectedContinuitySignal(kind: kind, reason: reason))
            return nil
        }
    }

    private static func workStateKind(for targetKind: WorkStateResolutionTargetKind) -> WorkStateKind {
        switch targetKind {
        case .decision: return .decision
        case .actionItem: return .actionItem
        case .agendaItem: return .agendaItem
        }
    }

    // MARK: - Validation

    private struct GroundedProposal {
        let evidence: EvidenceReference
        let confidence: Confidence
        /// The exact segment whose id and quote were validated above. Attribution must use this
        /// value rather than independently looking up untrusted proposal input a second time.
        let segment: TranscriptSegment
    }

    /// A hand-rolled two-case result rather than `Result`, whose `Failure` would have to conform
    /// to `Error` — a rejection reason is data for a report, not a thrown error.
    private enum ValidationOutcome {
        case grounded(GroundedProposal)
        case rejected(RejectedProposal.Reason)
    }

    private static func validate(
        _ evidence: ProposedEvidence,
        confidence: Double,
        content: String,
        in meeting: Meeting
    ) -> ValidationOutcome {
        guard !content.trimmed.isEmpty else {
            return .rejected(.emptyContent)
        }

        // Checked rather than clamped: a score outside [0, 1] means the response did not follow
        // the requested schema, which is a reason to distrust the whole item — not to silently
        // round it into range.
        guard confidence.isFinite, confidence >= 0, confidence <= 1 else {
            return .rejected(.confidenceOutOfRange)
        }

        guard let segmentID = UUID(uuidString: evidence.segmentID),
              let segment = meeting.transcriptSegments.first(where: { $0.id == segmentID }) else {
            return .rejected(.unknownSegment)
        }

        // Only surrounding whitespace is forgiven. Anything else — a paraphrase, a translation,
        // re-punctuation — fails: repairing a quote would fabricate the evidence it claims.
        let quote = evidence.quote.trimmed
        guard !quote.isEmpty, segment.text.contains(quote) else {
            return .rejected(.quoteNotInTranscript)
        }

        return .grounded(
            GroundedProposal(
                evidence: EvidenceReference(
                    meetingID: meeting.id,
                    transcriptSegmentID: segment.id,
                    quote: quote
                ),
                confidence: Confidence(confidence),
                segment: segment
            )
        )
    }

    // MARK: - Assignee attribution

    private struct ResolvedAttribution {
        let assigneeID: UUID?
        let provenance: AssigneeAttribution
    }

    /// Resolves only the finite attribution claims supported by the validated evidence segment.
    /// A bad attribution is not a bad action item: the work remains reviewable with a nil assignee
    /// and a finite resolution explaining why no owner was selected.
    private static func resolve(
        _ proposed: ProposedAssigneeAttribution,
        evidenceSegment: TranscriptSegment,
        in meeting: Meeting
    ) -> ResolvedAttribution {
        guard isValidShape(proposed) else {
            return resolvedAttribution(proposed, assigneeID: nil, resolution: .invalidAttribution)
        }

        let outcome: (UUID?, AssigneeAttributionResolution)

        switch proposed.basis {
        case .explicitName:
            // Shape validation above guarantees the required reference is non-empty.
            let reference = proposed.reference!.trimmed

            let matches = meeting.participants.filter { participant in
                normalizedExactMatch(participant.displayName, reference)
                    || normalizedExactMatch(participant.speakerLabel, reference)
            }
            switch matches.count {
            case 1:
                outcome = (matches[0].id, .resolved)
            case 0:
                outcome = (nil, .noParticipantMatch)
            default:
                outcome = (nil, .ambiguousParticipantMatch)
            }

        case .selfReference, .speakerCommitment:
            guard let evidenceSpeakerID = evidenceSegment.speakerID else {
                outcome = (nil, .missingEvidenceSpeaker)
                break
            }
            guard let participant = meeting.participants.first(where: { $0.id == evidenceSpeakerID }) else {
                outcome = (nil, .evidenceSpeakerNotParticipant)
                break
            }
            // Shape validation above guarantees the required opaque speaker label is non-empty.
            let proposedLabel = proposed.speakerLabel!.trimmed

            // This is the same label the extractor actually received for the cited segment.
            // Requiring it to round-trip prevents a model from using a valid quote from speaker A
            // while claiming that speaker B volunteered for the work.
            let extractorLabel = participant.speakerLabel ?? participant.displayName
            guard normalizedExactMatch(extractorLabel, proposedLabel) else {
                outcome = (nil, .speakerLabelMismatch)
                break
            }
            outcome = (participant.id, .resolved)

        case .teamOrRole:
            outcome = (nil, .nonIndividual)
        case .unspecified:
            outcome = (nil, .unspecified)
        }

        return resolvedAttribution(proposed, assigneeID: outcome.0, resolution: outcome.1)
    }

    /// Enforces the same finite basis/field combinations regardless of which provider produced the
    /// proposal. Provider DTO validation is defense in depth, not a reason to trust stubs or future
    /// adapters that enter through the provider-neutral seam directly.
    private static func isValidShape(_ proposed: ProposedAssigneeAttribution) -> Bool {
        let hasReference = proposed.reference?.trimmedNonEmpty != nil
        let hasSpeaker = proposed.speakerLabel?.trimmedNonEmpty != nil

        switch proposed.basis {
        case .explicitName:
            return hasReference && proposed.speakerLabel == nil
        case .selfReference:
            return hasReference && hasSpeaker
        case .speakerCommitment:
            return (proposed.reference == nil || hasReference) && hasSpeaker
        case .teamOrRole:
            return hasReference && proposed.speakerLabel == nil
        case .unspecified:
            return proposed.reference == nil && proposed.speakerLabel == nil
        }
    }

    private static func resolvedAttribution(
        _ proposed: ProposedAssigneeAttribution,
        assigneeID: UUID?,
        resolution: AssigneeAttributionResolution
    ) -> ResolvedAttribution {
        ResolvedAttribution(
            assigneeID: assigneeID,
            provenance: AssigneeAttribution(
                basis: proposed.basis,
                // Preserve the provider's bounded raw provenance. Normalization is comparison-only.
                reference: proposed.reference,
                speakerLabel: proposed.speakerLabel,
                resolution: resolution
            )
        )
    }

    /// Trimmed, Unicode-canonically-normalized, full-string equality. This is deliberately not a
    /// fuzzy or substring comparison; it also preserves the prior case/diacritic tolerance for a
    /// display name while requiring the result to be unique across the participant roster.
    private static func normalizedExactMatch(_ candidate: String?, _ reference: String) -> Bool {
        guard let candidate = candidate?.trimmedNonEmpty else {
            return false
        }
        let normalizedCandidate = candidate.precomposedStringWithCanonicalMapping
        let normalizedReference = reference.trimmed.precomposedStringWithCanonicalMapping
        return normalizedCandidate.compare(
            normalizedReference,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
