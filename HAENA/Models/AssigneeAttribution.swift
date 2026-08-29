import Foundation

/// The finite evidence basis asserted by an AI-proposed action-item assignee.
///
/// Raw values are part of both the extraction and on-disk contracts. An unknown future value must
/// fail decoding rather than silently degrade to `.unspecified`, because that would rewrite the
/// provenance of an existing proposal.
enum AssigneeAttributionBasis: String, Codable, Equatable, Sendable, CaseIterable {
    case explicitName = "explicit_name"
    case selfReference = "self_reference"
    case speakerCommitment = "speaker_commitment"
    case teamOrRole = "team_or_role"
    case unspecified
}

/// The finite result of resolving proposed assignee evidence against meeting participants.
enum AssigneeAttributionResolution: String, Codable, Equatable, Sendable, CaseIterable {
    case resolved
    case noParticipantMatch = "no_participant_match"
    case ambiguousParticipantMatch = "ambiguous_participant_match"
    case missingEvidenceSpeaker = "missing_evidence_speaker"
    case evidenceSpeakerNotParticipant = "evidence_speaker_not_participant"
    case speakerLabelMismatch = "speaker_label_mismatch"
    case nonIndividual = "non_individual"
    case unspecified
    case invalidAttribution = "invalid_attribution"
}

/// Immutable provenance for the assignee originally proposed by extraction and mapping.
///
/// `reference` is the bounded assignee surface form supplied by extraction, when one exists.
/// `speakerLabel` is the anonymized transcript label used for evidence-first resolution, never a
/// participant or user name. Neither field is inferred during persistence.
///
/// This value deliberately does not mirror later edits to `ActionItem.assigneeID`: preserving the
/// original proposal lets review and metrics distinguish what AI proposed from what a user chose.
struct AssigneeAttribution: Codable, Equatable, Sendable {
    let basis: AssigneeAttributionBasis
    let reference: String?
    let speakerLabel: String?
    let resolution: AssigneeAttributionResolution

    init(
        basis: AssigneeAttributionBasis,
        reference: String?,
        speakerLabel: String?,
        resolution: AssigneeAttributionResolution
    ) {
        self.basis = basis
        self.reference = reference
        self.speakerLabel = speakerLabel
        self.resolution = resolution
    }
}
