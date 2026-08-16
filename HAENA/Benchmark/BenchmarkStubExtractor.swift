import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// A `WorkStateExtractor` for the harness's default offline run: it opens no socket, reads no
/// credential, and returns the same proposals for the same case every time.
///
/// Deliberately separate from `DeterministicWorkStateExtractor`, which exists to drive the app's
/// UI tests: the harness needs proposals that exercise *rejection* paths too, and the app's
/// double must not grow benchmark-only behaviour.
///
/// The six proposals below are chosen so that one pass over any non-empty case exercises every
/// mapper outcome the harness can record — two accepted items and one instance of each of the four
/// `RejectedProposal.Reason` values. A run that produces only well-formed proposals would leave the
/// rejection plumbing untested, and an untested rejection path is how a real provider's bad output
/// ends up silently dropped.
struct BenchmarkStubExtractor: WorkStateExtractor, Sendable {
    static let modelID = "benchmark-stub-v1"
    static let promptRevision = "benchmark-stub-v1"

    /// Written inline instead of being added to `ModelProvider` as a static member: the app's
    /// provider list describes backends a *user* can be served by, and a benchmark-only stub is
    /// not one of them. `ModelProvider` is a `RawRepresentable` struct precisely so a value can be
    /// spelled out at the edge without editing the domain.
    static let provider = ModelProvider(rawValue: "benchmark-stub")

    /// A well-formed UUID string that names no segment of any case.
    ///
    /// The nil UUID is safe to use as "definitely absent": `BenchmarkIdentity` always stamps the
    /// version nibble to 8 and the variant to RFC, so it can never mint this value, and the
    /// adapter derives every segment id through `BenchmarkIdentity`.
    static let absentSegmentID = "00000000-0000-0000-0000-000000000000"

    /// A quote that cannot be a substring of any transcript.
    ///
    /// `\u{1F}` (ASCII unit separator) is a control character; corpus utterance text is prose, so
    /// the mapper's verbatim-substring check is guaranteed to fail rather than merely likely to —
    /// the same reasoning `BenchmarkIdentity` uses for its name-scope separator.
    static let absentQuote = "\u{1F}BENCHMARK_STUB_ABSENT_QUOTE\u{1F}"

    /// Only ever reaches `ModelRunMetadata.completedAt`. Defaulted to the epoch rather than to
    /// `Date.init` so a stub run is reproducible by default; the harness never stores this value in
    /// an artifact, but a moving default would make the extractor's own output non-deterministic.
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }) {
        self.now = now
    }

    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        let metadata = ModelRunMetadata(provider: Self.provider, modelID: Self.modelID, completedAt: now())

        // No usable text means there is nothing to ground a quote in, and an ungrounded proposal
        // would only ever test the rejection path twice. The adapter rejects empty transcripts
        // before this point; this guard exists so the stub cannot fabricate evidence if it ever
        // sees one anyway.
        guard let excerpt = input.excerpts.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return WorkStateExtractionResult(metadata: metadata)
        }

        // Grounded by construction: a prefix of the stored segment text, citing that segment.
        let grounded = ProposedEvidence(
            segmentID: excerpt.segmentID.uuidString,
            quote: Self.leadingQuote(from: excerpt.text)
        )
        // Real quote, unreal segment.
        let unknownSegment = ProposedEvidence(segmentID: Self.absentSegmentID, quote: grounded.quote)
        // Real segment, unreal quote.
        let ungroundedQuote = ProposedEvidence(segmentID: excerpt.segmentID.uuidString, quote: Self.absentQuote)

        return WorkStateExtractionResult(
            decisions: [
                // 1. Accepted.
                ProposedDecision(
                    statement: "벤치마크 스텁 결정",
                    rationale: "첫 번째 발화에서 근거를 확보함",
                    confidence: 0.6,
                    evidence: grounded
                ),
                // 5. Empty content -> RejectedProposal.Reason.emptyContent -> .missingRequiredField.
                ProposedDecision(
                    statement: "",
                    rationale: nil,
                    confidence: 0.6,
                    evidence: grounded
                )
            ],
            actionItems: [
                // 2. Accepted. The owner is the speaker label exactly as the transcript labels it;
                //    the stub does not interpret self-reference, and neither does the harness.
                ProposedActionItem(
                    title: "벤치마크 스텁 실행 항목",
                    details: nil,
                    assigneeName: excerpt.speakerLabel,
                    dueDate: nil,
                    confidence: 0.6,
                    evidence: grounded
                ),
                // 6. Confidence outside [0, 1] -> .confidenceOutOfRange.
                ProposedActionItem(
                    title: "신뢰도가 범위를 벗어난 실행 항목",
                    details: nil,
                    assigneeName: nil,
                    dueDate: nil,
                    confidence: 1.5,
                    evidence: grounded
                )
            ],
            openQuestions: [
                // 3. Cites a segment that does not exist -> .unknownSegment -> .evidenceNotFound.
                ProposedOpenQuestion(
                    question: "근거 세그먼트가 존재하지 않는 질문",
                    confidence: 0.6,
                    evidence: unknownSegment
                )
            ],
            nextAgendaItems: [
                // 4. Quote is not in the cited segment -> .quoteNotInTranscript.
                ProposedAgendaItem(
                    title: "전사에 없는 인용을 단 안건",
                    reason: "인용 검증 경로를 확인하기 위한 항목",
                    confidence: 0.6,
                    evidence: ungroundedQuote
                )
            ],
            metadata: metadata
        )
    }

    /// First line (or first 80 characters, whichever is shorter) of the segment. Trimming only
    /// removes characters from the ends, so the result stays a contiguous substring of `text` and
    /// therefore passes the same verbatim-quote check a real provider's output has to pass.
    private static func leadingQuote(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return String(firstLine.prefix(80)).trimmingCharacters(in: .whitespaces)
    }
}
