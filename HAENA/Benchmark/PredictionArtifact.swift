import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Vocabulary

/// Which of the four work-state kinds a proposal claimed to be.
///
/// A separate type from `RejectedProposal.Kind` because this one is *serialized*: its raw values
/// are part of the `prediction-v0.2` file format and cannot follow refactors of the app's internal
/// enum without breaking every artifact already written.
enum BenchmarkProposalKind: String, Codable, Equatable, Sendable {
    case decision
    case actionItem = "action_item"
    case openQuestion = "open_question"
    case agendaItem = "agenda_item"
}

/// Where in the pipeline a proposal was dropped.
///
/// The distinction matters when reading a report: an `input` rejection is a property of the corpus
/// (the harness knew about it before any model ran), while a `mapper` rejection is a property of
/// the model's answer. Collapsing them would make a noisy dataset look like a bad model.
enum BenchmarkRejectionStage: String, Codable, Equatable, Sendable {
    /// Built before the model ran (e.g. unknown speaker in the corpus).
    case input
    /// `WorkStateProposalMapper` refused the proposal.
    case mapper
}

/// Why a proposal did not become a stored domain object.
///
/// Deliberately a closed vocabulary with stable raw values: these strings are what a human reads
/// when deciding whether a failure is the harness's fault, the corpus's, or the model's.
enum BenchmarkRejectionReason: String, Codable, Equatable, Sendable {
    case evidenceNotFound = "evidence_not_found"
    case quoteNotInTranscript = "quote_not_in_transcript"
    case unknownSpeaker = "unknown_speaker"
    case unsupportedProposalType = "unsupported_proposal_type"
    case missingRequiredField = "missing_required_field"
    case confidenceOutOfRange = "confidence_out_of_range"
    case mapperValidationFailed = "mapper_validation_failed"
}

// MARK: - Records

/// One dropped proposal, with enough context to find it again in the corpus.
struct BenchmarkRejectionRecord: Codable, Equatable, Sendable {
    let stage: BenchmarkRejectionStage
    let kind: BenchmarkProposalKind?
    let reason: BenchmarkRejectionReason
    let proposalOrdinal: Int?
    /// Verbatim from the model, may be malformed. Kept unedited so a malformed id is visibly
    /// malformed in the artifact rather than silently normalized into something plausible.
    let citedSegmentID: String?
    /// Reverse-mapped, nil when unresolvable.
    let citedUtteranceID: String?
    /// For input-stage records, which the model never saw.
    let utteranceID: String?

    /// Defaults for every field a given stage does not have, so a call site records only what it
    /// actually knows instead of spelling out a row of `nil`s.
    init(
        stage: BenchmarkRejectionStage,
        kind: BenchmarkProposalKind? = nil,
        reason: BenchmarkRejectionReason,
        proposalOrdinal: Int? = nil,
        citedSegmentID: String? = nil,
        citedUtteranceID: String? = nil,
        utteranceID: String? = nil
    ) {
        self.stage = stage
        self.kind = kind
        self.reason = reason
        self.proposalOrdinal = proposalOrdinal
        self.citedSegmentID = citedSegmentID
        self.citedUtteranceID = citedUtteranceID
        self.utteranceID = utteranceID
    }

    private enum CodingKeys: String, CodingKey {
        case stage
        case kind
        case reason
        case proposalOrdinal = "proposal_ordinal"
        case citedSegmentID = "cited_segment_id"
        case citedUtteranceID = "cited_utterance_id"
        case utteranceID = "utterance_id"
    }
}

/// The prediction-v0.2 base proposal fields, unedited, with the corpus utterance id added beside
/// the app-side segment id. Provider-local keys and continuity sidecars are not serialized here.
struct BenchmarkRawProposal: Codable, Equatable, Sendable {
    let ordinal: Int
    let kind: BenchmarkProposalKind
    /// statement / title / question, depending on `kind`.
    let text: String
    /// rationale / details / reason, depending on `kind`.
    let supportingText: String?
    /// The provider's finite attribution claim and bounded raw provenance, preserved without
    /// normalization. Nil for proposal kinds that have no assignee.
    let assigneeAttributionBasis: AssigneeAttributionBasis?
    let assigneeReference: String?
    /// Opaque extractor input label (for example `B`), never a participant UUID or display name.
    let assigneeSpeakerLabel: String?
    let dueDate: Date?
    /// Recorded as the model returned it, including out-of-range values. Clamping here would erase
    /// the evidence for a `confidence_out_of_range` rejection sitting in the same artifact.
    let confidence: Double
    let citedSegmentID: String
    let citedUtteranceID: String?
    let quote: String

    init(
        ordinal: Int,
        kind: BenchmarkProposalKind,
        text: String,
        supportingText: String? = nil,
        assigneeAttributionBasis: AssigneeAttributionBasis? = nil,
        assigneeReference: String? = nil,
        assigneeSpeakerLabel: String? = nil,
        dueDate: Date? = nil,
        confidence: Double,
        citedSegmentID: String,
        citedUtteranceID: String? = nil,
        quote: String
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.text = text
        self.supportingText = supportingText
        self.assigneeAttributionBasis = assigneeAttributionBasis
        self.assigneeReference = assigneeReference
        self.assigneeSpeakerLabel = assigneeSpeakerLabel
        self.dueDate = dueDate
        self.confidence = confidence
        self.citedSegmentID = citedSegmentID
        self.citedUtteranceID = citedUtteranceID
        self.quote = quote
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case kind
        case text
        case supportingText = "supporting_text"
        case assigneeAttributionBasis = "assignee_attribution_basis"
        case assigneeReference = "assignee_reference"
        case assigneeSpeakerLabel = "assignee_speaker_label"
        case dueDate = "due_date"
        case confidence
        case citedSegmentID = "cited_segment_id"
        case citedUtteranceID = "cited_utterance_id"
        case quote
    }
}

/// What `WorkStateProposalMapper` accepted, as stored domain models plus corpus back-references.
struct BenchmarkMappedProposal: Codable, Equatable, Sendable {
    let ordinal: Int
    let kind: BenchmarkProposalKind
    /// The app-generated id, derived by the product mapper from project + meeting + kind +
    /// provider-local key so two runs of the same input produce the same value.
    let id: UUID
    let text: String
    let assigneeParticipantID: UUID?
    /// The speaker label the mapper resolved, or nil when it refused to guess.
    let assigneeSpeakerLabel: String?
    /// Finite mapper outcome for an action-item attribution. Nil for other proposal kinds.
    let assigneeAttributionResolution: AssigneeAttributionResolution?
    let dueDate: Date?
    let confidence: Double
    let evidenceSegmentID: UUID
    let evidenceUtteranceID: String?
    let evidenceQuote: String
    /// e.g. "proposed" / "open" / "pending" — the domain status the mapper assigned. A `String`
    /// because the four kinds use four different status enums with no common case.
    let status: String

    init(
        ordinal: Int,
        kind: BenchmarkProposalKind,
        id: UUID,
        text: String,
        assigneeParticipantID: UUID? = nil,
        assigneeSpeakerLabel: String? = nil,
        assigneeAttributionResolution: AssigneeAttributionResolution? = nil,
        dueDate: Date? = nil,
        confidence: Double,
        evidenceSegmentID: UUID,
        evidenceUtteranceID: String? = nil,
        evidenceQuote: String,
        status: String
    ) {
        self.ordinal = ordinal
        self.kind = kind
        self.id = id
        self.text = text
        self.assigneeParticipantID = assigneeParticipantID
        self.assigneeSpeakerLabel = assigneeSpeakerLabel
        self.assigneeAttributionResolution = assigneeAttributionResolution
        self.dueDate = dueDate
        self.confidence = confidence
        self.evidenceSegmentID = evidenceSegmentID
        self.evidenceUtteranceID = evidenceUtteranceID
        self.evidenceQuote = evidenceQuote
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal
        case kind
        case id
        case text
        case assigneeParticipantID = "assignee_participant_id"
        case assigneeSpeakerLabel = "assignee_speaker_label"
        case assigneeAttributionResolution = "assignee_attribution_resolution"
        case dueDate = "due_date"
        case confidence
        case evidenceSegmentID = "evidence_segment_id"
        case evidenceUtteranceID = "evidence_utterance_id"
        case evidenceQuote = "evidence_quote"
        case status
    }
}

// MARK: - Scoring gate

/// The only value this type can hold today.
///
/// A single-case enum rather than a `Bool` or a free `String`: adding a second case is a visible,
/// reviewable change, whereas a boolean would let "scored" appear the moment someone flipped it.
enum BenchmarkScoringStatus: String, Codable, Equatable, Sendable {
    case unscored
}

/// Why this artifact carries no measurement.
///
/// Present rather than omitted so that a reader of the file never has to infer the absence of a
/// score from the absence of a field — the file states it.
struct BenchmarkScoring: Codable, Equatable, Sendable {
    /// Always `.unscored` in this task.
    let status: BenchmarkScoringStatus
    /// e.g. "human_review_pending".
    let reason: String

    init(status: BenchmarkScoringStatus = .unscored, reason: String) {
        self.status = status
        self.reason = reason
    }
}

// MARK: - Artifact

/// One case's prediction run, written to `<output-dir>/<caseID>.prediction.json`.
///
/// The header fields exist so a stale artifact is recognizable without re-running anything: change
/// the dataset file, the prompt, the model, or the extraction schema and the corresponding field
/// changes with it.
struct PredictionArtifact: Codable, Equatable, Sendable {
    static let schemaVersion = "prediction-v0.2"
    /// Distinguishes this file from `model_suggestion` drafts and from human gold at a glance.
    static let artifactKind = "haena_prediction"

    /// The instant substituted for `executedAt` in `reproducibleFields`. Any constant would do;
    /// the epoch matches `BenchmarkExtractionInputAdapter.syntheticMeetingDate`, so a reproducible
    /// comparison has exactly one fixed timestamp in it rather than two.
    static let reproducibilityInstant = Date(timeIntervalSince1970: 0)

    let artifactSchemaVersion: String
    let artifactKind: String
    let benchmark: String
    let caseID: String
    let split: BenchmarkSplit
    let datasetSchemaVersion: String
    let sourceCaseHash: String
    let extractionSchemaVersion: String
    let promptRevision: String
    let gitRevision: String
    let provider: String
    let modelID: String
    /// "offline_stub" | "provider".
    let runMode: String
    /// Provenance that changes on purpose. Excluded from reproducibility comparison.
    let executedAt: Date
    let scoring: BenchmarkScoring
    let inputSummary: InputSummary
    let raw: [BenchmarkRawProposal]
    let mapped: [BenchmarkMappedProposal]
    let rejected: [BenchmarkRejectionRecord]

    /// Shape of the input, as counts and labels only.
    ///
    /// Counts, not content: the transcript itself stays in `data/`, and an artifact that embedded
    /// it would turn every output directory into a second copy of a licensed corpus.
    struct InputSummary: Codable, Equatable, Sendable {
        let utteranceCount: Int
        let participantCount: Int
        let speakerLabels: [String]
        let unknownSpeakerUtteranceCount: Int

        init(
            utteranceCount: Int,
            participantCount: Int,
            speakerLabels: [String],
            unknownSpeakerUtteranceCount: Int
        ) {
            self.utteranceCount = utteranceCount
            self.participantCount = participantCount
            self.speakerLabels = speakerLabels
            self.unknownSpeakerUtteranceCount = unknownSpeakerUtteranceCount
        }

        private enum CodingKeys: String, CodingKey {
            case utteranceCount = "utterance_count"
            case participantCount = "participant_count"
            case speakerLabels = "speaker_labels"
            case unknownSpeakerUtteranceCount = "unknown_speaker_utterance_count"
        }
    }

    init(
        artifactSchemaVersion: String = PredictionArtifact.schemaVersion,
        artifactKind: String = PredictionArtifact.artifactKind,
        benchmark: String,
        caseID: String,
        split: BenchmarkSplit,
        datasetSchemaVersion: String,
        sourceCaseHash: String,
        extractionSchemaVersion: String,
        promptRevision: String,
        gitRevision: String,
        provider: String,
        modelID: String,
        runMode: String,
        executedAt: Date,
        scoring: BenchmarkScoring,
        inputSummary: InputSummary,
        raw: [BenchmarkRawProposal],
        mapped: [BenchmarkMappedProposal],
        rejected: [BenchmarkRejectionRecord]
    ) {
        self.artifactSchemaVersion = artifactSchemaVersion
        self.artifactKind = artifactKind
        self.benchmark = benchmark
        self.caseID = caseID
        self.split = split
        self.datasetSchemaVersion = datasetSchemaVersion
        self.sourceCaseHash = sourceCaseHash
        self.extractionSchemaVersion = extractionSchemaVersion
        self.promptRevision = promptRevision
        self.gitRevision = gitRevision
        self.provider = provider
        self.modelID = modelID
        self.runMode = runMode
        self.executedAt = executedAt
        self.scoring = scoring
        self.inputSummary = inputSummary
        self.raw = raw
        self.mapped = mapped
        self.rejected = rejected
    }

    /// Everything except `executedAt`, for asserting two runs of the same input agree.
    ///
    /// Returns a whole artifact rather than a hash or a field list so a failing equality assertion
    /// prints the field that actually diverged.
    var reproducibleFields: PredictionArtifact {
        PredictionArtifact(
            artifactSchemaVersion: artifactSchemaVersion,
            artifactKind: artifactKind,
            benchmark: benchmark,
            caseID: caseID,
            split: split,
            datasetSchemaVersion: datasetSchemaVersion,
            sourceCaseHash: sourceCaseHash,
            extractionSchemaVersion: extractionSchemaVersion,
            promptRevision: promptRevision,
            gitRevision: gitRevision,
            provider: provider,
            modelID: modelID,
            runMode: runMode,
            executedAt: Self.reproducibilityInstant,
            scoring: scoring,
            inputSummary: inputSummary,
            raw: raw,
            mapped: mapped,
            rejected: rejected
        )
    }

    // MARK: - Coding

    /// A computed property rather than a shared `static let` instance: `JSONEncoder` is a mutable
    /// reference type, and a single shared one would be global mutable state under Swift 6 strict
    /// concurrency. Building a fresh encoder costs nothing next to writing a file.
    ///
    /// `.sortedKeys` is not cosmetic — it is what makes two runs of the same case produce
    /// byte-identical files that `diff` can compare.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder, so a written artifact can be read back and compared field by field.
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum CodingKeys: String, CodingKey {
        case artifactSchemaVersion = "artifact_schema_version"
        case artifactKind = "artifact_kind"
        case benchmark
        case caseID = "case_id"
        case split
        case datasetSchemaVersion = "dataset_schema_version"
        case sourceCaseHash = "source_case_hash"
        case extractionSchemaVersion = "extraction_schema_version"
        case promptRevision = "prompt_revision"
        case gitRevision = "git_revision"
        case provider
        case modelID = "model_id"
        case runMode = "run_mode"
        case executedAt = "executed_at"
        case scoring
        case inputSummary = "input_summary"
        case raw
        case mapped
        case rejected
    }
}
