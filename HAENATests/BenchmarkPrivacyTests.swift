import XCTest
@testable import HAENA

/// What a prediction artifact is allowed to contain.
///
/// An artifact is the one file this harness produces, and it is the file most likely to be
/// attached to an issue, pasted into a chat, or copied out of `data/` by someone tidying up. So it
/// is checked for the three things that must never travel with it:
///
/// 1. **A credential.** No key, header, or environment value.
/// 2. **A filesystem path.** The corpus lives under someone's home directory; the artifact must be
///    readable without revealing whose.
/// 3. **The transcript.** Only what the model actually quoted may appear. An artifact that carried
///    every utterance would be a second copy of the corpus in a directory nobody treats as one.
///
/// Each check is preceded by a control asserting that it can fail, because a containment check
/// against an empty or mis-encoded payload passes for the wrong reason.
final class BenchmarkPrivacyTests: XCTestCase {
    private static let fixedNow = Date(timeIntervalSince1970: 0)

    /// Substrings that would betray a credential. `Bearer ` and `Authorization` are here because a
    /// leak is at least as likely to arrive as a captured request header as it is as a bare key.
    private static let credentialMarkers = [
        "sk-", "OPENAI_API_KEY", "Authorization", "Bearer ", "api_key", "apiKey", "secretKey"
    ]

    /// Keys that would mean gold, a draft suggestion, or corpus bookkeeping had been copied into
    /// the artifact. Checked against decoded key names rather than raw bytes, so a Korean quote
    /// that happens to contain one of these as a substring cannot fail the test.
    private static let forbiddenKeys = [
        "gold", "model_suggestion", "modelSuggestion", "forbidden_inferences", "prior_state",
        "reviewer_notes", "drafts", "transcript", "label_path"
    ]

    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: - Producing an artifact

    private struct NoArtifactProduced: Error {}

    private func artifact(
        for prepared: BenchmarkPreparedCase,
        extractor: any WorkStateExtractor = BenchmarkStubExtractor()
    ) async throws -> PredictionArtifact {
        let runner = BenchmarkRunner(extractor: extractor, now: { Self.fixedNow })
        let outcome = await runner.run(prepared, options: BenchmarkFixtures.runOptions)
        guard case .produced(let artifact) = outcome else {
            XCTFail("the offline stub must produce an artifact for a well-formed case")
            throw NoArtifactProduced()
        }
        return artifact
    }

    private func encoded(_ artifact: PredictionArtifact) throws -> String {
        try XCTUnwrap(String(data: try PredictionArtifact.encoder.encode(artifact), encoding: .utf8))
    }

    // MARK: - The checks must be capable of failing

    /// Without this, an artifact that encoded to `{}` would pass every assertion below.
    func testTheDetectorsFindTheForbiddenContentWhenItIsActuallyPresent() throws {
        // Encoded with the artifact's own encoder, not a default one. A bare `JSONEncoder` escapes
        // forward slashes, so `/Users/` would arrive as `\/Users\/` and this control would report
        // that the path detector cannot work — when in fact it is the control that does not match
        // how artifacts are actually written.
        let control = try XCTUnwrap(
            String(
                data: try PredictionArtifact.encoder.encode(
                    Self.credentialMarkers + Self.forbiddenKeys + ["/Users/someone/data", "전사 원문 한 줄"]
                ),
                encoding: .utf8
            )
        )

        for marker in Self.credentialMarkers + Self.forbiddenKeys {
            XCTAssertTrue(control.contains(marker), "the detector must be able to find \(marker)")
        }
        XCTAssertTrue(control.contains("/Users/"))
        XCTAssertTrue(control.contains("전사 원문 한 줄"))
    }

    // MARK: - Credentials

    func testAnEncodedArtifactCarriesNothingThatLooksLikeACredential() async throws {
        let json = try encoded(try await artifact(for: try BenchmarkFixtures.prepared()))

        for marker in Self.credentialMarkers {
            XCTAssertFalse(json.contains(marker), "a prediction artifact must not contain \(marker)")
        }

        // If this machine happens to have a real key in the environment, assert its exact value is
        // absent too. The value is never printed — only tested for containment.
        if let key = ProcessInfo.processInfo.environment[OpenAIConfiguration.apiKeyEnvironmentKey],
           key.count > 8 {
            XCTAssertFalse(json.contains(key), "the environment's API key reached the artifact")
        }
    }

    // MARK: - Filesystem paths

    /// Structural rather than substring-based: every string value in the document is checked, so a
    /// path stored under a field nobody thought to forbid fails here too.
    func testNoStringInAnEncodedArtifactIsAFilesystemPath() async throws {
        let artifact = try await artifact(for: try BenchmarkFixtures.prepared())
        let json = try encoded(artifact)

        XCTAssertFalse(json.contains("/Users/"), "a home-directory path reached the artifact")
        XCTAssertFalse(json.contains(NSHomeDirectory()))
        XCTAssertFalse(json.contains(FileManager.default.temporaryDirectory.path))

        for string in try Self.strings(in: artifact) {
            XCTAssertFalse(
                string.hasPrefix("/") || string.hasPrefix("file://"),
                "\(string) reads like a filesystem path"
            )
        }
    }

    /// The dataset root is known only to the process that ran the harness, and it stays that way.
    func testTheDatasetRootDoesNotReachTheArtifactEvenWhenTheCaseWasLoadedFromDisk() async throws {
        let root = try BenchmarkFixtures.writeTemporaryDataset(
            developmentCaseIDs: ["SYN-D1"],
            sealedHoldoutCaseIDs: []
        )
        temporaryRoots.append(root)
        let store = BenchmarkCaseStore(datasetRoot: root)
        let entry = try XCTUnwrap(try store.entries(in: .development).first)

        let json = try encoded(try await artifact(for: try store.prepared(entry)))

        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(json.contains(root.lastPathComponent))
    }

    // MARK: - Structure

    func testContinuitySidecarsDoNotChangePredictionV02OrCopySignalEvidence() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let baseExcerpt = prepared.extractionInput.excerpts[0]
        let signalExcerpt = prepared.extractionInput.excerpts[1]
        let signalOnlyQuote = "지표 정의를 맡겠습니다"
        XCTAssertTrue(signalExcerpt.text.contains(signalOnlyQuote), "control: signal evidence must be grounded")

        let result = WorkStateExtractionResult(
            actionItems: [
                ProposedActionItem(
                    providerLocalKey: "action_1",
                    title: "artifact base action",
                    details: nil,
                    assigneeAttribution: ProposedAssigneeAttribution(
                        basis: .unspecified,
                        reference: nil,
                        speakerLabel: nil
                    ),
                    dueDate: nil,
                    confidence: 0.8,
                    evidence: ProposedEvidence(
                        segmentID: baseExcerpt.segmentID.uuidString,
                        quote: "다음 주까지"
                    )
                )
            ],
            progressSignals: [
                ProposedProgressSignal(
                    kind: .completed,
                    targetType: .incomingActionItem,
                    targetReference: "action_1",
                    evidence: ProposedEvidence(
                        segmentID: signalExcerpt.segmentID.uuidString,
                        quote: signalOnlyQuote
                    )
                )
            ],
            openQuestionResolutionLinks: [
                ProposedOpenQuestionResolutionLink(
                    priorOpenQuestionReference: "prior_question_missing",
                    targetKind: .decision,
                    targetProviderLocalKey: "decision_missing",
                    evidence: nil
                )
            ],
            metadata: ExtractionFixtures.metadata
        )

        let artifact = try await artifact(
            for: prepared,
            extractor: StubWorkStateExtractor(.success(result))
        )
        let json = try encoded(artifact)

        XCTAssertEqual(artifact.artifactSchemaVersion, "prediction-v0.2")
        XCTAssertEqual(artifact.raw.count, 1)
        XCTAssertEqual(artifact.mapped.count, 1)
        XCTAssertTrue(artifact.rejected.isEmpty, "malformed sidecars must not reject a grounded base item")
        XCTAssertFalse(json.contains(signalOnlyQuote))
        XCTAssertFalse(json.contains("progress_signals"))
        XCTAssertFalse(json.contains("open_question_resolution_links"))
        XCTAssertFalse(json.contains("decision_derived_action_item_links"))
        XCTAssertFalse(json.contains("prior_question_missing"))
    }

    func testAggregateReportCannotContainRawAttributionReferenceSpeakerOrParticipantName() throws {
        let rawReference = "제가-민수-원문"
        let rawSpeaker = "opaque-speaker-private"
        let participantName = "민수-개인명"
        let control = try XCTUnwrap(
            String(data: try JSONEncoder().encode([rawReference, rawSpeaker, participantName]), encoding: .utf8)
        )
        XCTAssertTrue(control.contains(rawReference))
        XCTAssertTrue(control.contains(rawSpeaker))
        XCTAssertTrue(control.contains(participantName))

        let report = BenchmarkRunReport(
            benchmark: "meeting-execution-v0",
            runMode: "offline_stub",
            caseCount: 1,
            producedCount: 1,
            failedCount: 0,
            rawProposalCount: 1,
            mappedProposalCount: 1,
            rejectedProposalCount: 0,
            unscoredCount: 1,
            caseIDs: ["SYN-D1"]
        )
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(report), encoding: .utf8))

        XCTAssertFalse(json.contains(rawReference))
        XCTAssertFalse(json.contains(rawSpeaker))
        XCTAssertFalse(json.contains(participantName))
        XCTAssertFalse(json.contains("assignee_reference"))
        XCTAssertFalse(json.contains("assignee_speaker_label"))
        XCTAssertFalse(json.contains("participant_name"))
    }

    func testNoKeyInAnEncodedArtifactBelongsToGoldADraftOrTheCorpusBookkeeping() async throws {
        let artifact = try await artifact(for: try BenchmarkFixtures.prepared())

        let keys = try Self.keys(in: artifact)
        XCTAssertFalse(keys.isEmpty, "an artifact with proposals must encode some keys")
        for key in keys {
            for forbidden in Self.forbiddenKeys {
                XCTAssertFalse(
                    key.localizedCaseInsensitiveContains(forbidden),
                    "\(key) reads like a \(forbidden) field"
                )
            }
        }
    }

    /// Speaker labels are the corpus's own `A`/`B`/`C`, never a name. Anything longer would mean
    /// the adapter had started inventing or importing identities.
    func testTheInputSummaryCarriesSpeakerLabelsRatherThanNames() async throws {
        let artifact = try await artifact(for: try BenchmarkFixtures.prepared())

        XCTAssertFalse(artifact.inputSummary.speakerLabels.isEmpty)
        for label in artifact.inputSummary.speakerLabels {
            XCTAssertTrue(label.count <= 4, "\(label) is too long to be a corpus speaker label")
            XCTAssertTrue(label.allSatisfy { $0.isASCII }, "\(label) is not a corpus speaker label")
        }
    }

    // MARK: - The transcript

    /// The property, stated exactly: an utterance's text may appear in the artifact only if the
    /// model quoted it. Everything else stays in the corpus.
    ///
    /// Asserted as an implication rather than as a list of forbidden strings, so it holds whatever
    /// the fixture's utterances happen to say — and the non-vacuity assertion at the end fails if
    /// the case ever becomes one where every utterance was quoted anyway.
    func testOnlyQuotedUtterancesAppearInTheArtifact() async throws {
        let prepared = try BenchmarkFixtures.prepared()
        let artifact = try await artifact(for: prepared)

        try assertOnlyQuotedTextAppears(in: artifact, from: prepared)
    }

    /// The same property against real corpus text, which is the content that actually matters.
    /// Skipped where the local-only corpus is absent.
    func testOnlyQuotedUtterancesAppearInAnArtifactBuiltFromARealDevelopmentCase() async throws {
        let store = try realCorpusStore()
        let entry = try XCTUnwrap(try store.entries(in: .development).first)
        let prepared = try store.prepared(entry)

        let artifact = try await artifact(for: prepared)

        try assertOnlyQuotedTextAppears(in: artifact, from: prepared)
        XCTAssertGreaterThan(
            prepared.utteranceCount,
            10,
            "a real case has enough utterances for the check above to be meaningful"
        )
    }

    private func assertOnlyQuotedTextAppears(
        in artifact: PredictionArtifact,
        from prepared: BenchmarkPreparedCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let json = try encoded(artifact)
        let quotes = artifact.raw.map(\.quote) + artifact.mapped.map(\.evidenceQuote)
        let texts = prepared.extractionInput.excerpts
            .map(\.text)
            .filter { $0.count >= 4 }

        XCTAssertGreaterThanOrEqual(texts.count, 2, "too few utterances to prove anything", file: file, line: line)

        var appeared = 0
        for text in texts where json.contains(text) {
            appeared += 1
            XCTAssertTrue(
                quotes.contains { $0.contains(text) },
                "an utterance the model never quoted appears in the artifact",
                file: file,
                line: line
            )
        }

        XCTAssertLessThan(
            appeared,
            texts.count,
            "every utterance appears in the artifact — that is a second copy of the transcript",
            file: file,
            line: line
        )
    }

    // MARK: - Plumbing

    private func realCorpusStore() throws -> BenchmarkCaseStore {
        // `#filePath` rather than an environment variable: `xcodebuild` does not forward the shell
        // environment to the test host. The literal is expanded at compile time, so no path is
        // committed by this file.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("data/benchmarks/haena-v0/meeting-execution-v0", isDirectory: true)

        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("source-index.jsonl").path) else {
            throw XCTSkip("The meeting-execution-v0 corpus is local-only and is not present here.")
        }
        return BenchmarkCaseStore(datasetRoot: root)
    }

    private static func keys(in artifact: PredictionArtifact) throws -> Set<String> {
        var keys = Set<String>()
        var strings: [String] = []
        walk(try JSONSerialization.jsonObject(with: try PredictionArtifact.encoder.encode(artifact)),
             keys: &keys, strings: &strings)
        return keys
    }

    private static func strings(in artifact: PredictionArtifact) throws -> [String] {
        var keys = Set<String>()
        var strings: [String] = []
        walk(try JSONSerialization.jsonObject(with: try PredictionArtifact.encoder.encode(artifact)),
             keys: &keys, strings: &strings)
        return strings
    }

    private static func walk(_ value: Any, keys: inout Set<String>, strings: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                keys.insert(key)
                walk(child, keys: &keys, strings: &strings)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(child, keys: &keys, strings: &strings)
            }
        } else if let string = value as? String {
            strings.append(string)
        }
    }
}
