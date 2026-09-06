import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// The complete discovery record. It contains identities and gate metadata only: no transcript,
/// output text, evidence quote, reviewer note, participant identity, or absolute path.
struct SemanticScorerSourceIndexEntry: Codable, Equatable, Sendable {
    let indexSchemaVersion: String
    let inputSchemaVersion: String
    let benchmark: String
    let caseID: String
    let split: BenchmarkSplit
    let status: String
    let scorerReady: Bool
    let secondaryReviewComplete: Bool
    let predictionArtifactHash: String
    /// SHA-256 of the exact raw scorer payload bytes, including whitespace/newlines.
    let goldInputHash: String
    let matchingPolicyVersion: String
    let goldReferences: [SemanticGoldReference]

    private enum CodingKeys: String, CodingKey {
        case indexSchemaVersion = "index_schema_version"
        case inputSchemaVersion = "input_schema_version"
        case benchmark
        case caseID = "case_id"
        case split
        case status
        case scorerReady = "scorer_ready"
        case secondaryReviewComplete = "secondary_review_complete"
        case predictionArtifactHash = "prediction_artifact_hash"
        case goldInputHash = "gold_input_hash"
        case matchingPolicyVersion = "matching_policy_version"
        case goldReferences = "gold_references"
    }
}

/// Explicit per-run consent. It has no default value and is never persisted.
struct SemanticScorerRuntimeAuthorization: Equatable, Sendable {
    fileprivate enum Scope: Equatable, Sendable {
        case development
    }

    fileprivate let scope: Scope

    static func development() -> SemanticScorerRuntimeAuthorization {
        SemanticScorerRuntimeAuthorization(scope: .development)
    }
}

struct SemanticScorerAuthorizationRequest: Equatable, Sendable {
    let runtimeAuthorization: SemanticScorerRuntimeAuthorization?
    let requestedSplit: BenchmarkSplit
    let benchmark: String
    let caseID: String
    let predictionArtifactFingerprint: PredictionArtifactFingerprint
    let availablePredictions: [SemanticPredictionReference]
    let matchingMap: SemanticMatchingMap
}

/// A development-only payload-read capability. Its initializer and source metadata are file-private,
/// so no external caller can forge one from a raw or stale index entry.
struct AuthorizedSemanticScorerEntry: Equatable, Sendable {
    fileprivate let sourceEntry: SemanticScorerSourceIndexEntry

    var benchmark: String { sourceEntry.benchmark }
    var caseID: String { sourceEntry.caseID }
    var split: BenchmarkSplit { sourceEntry.split }
    var inputSchemaVersion: String { sourceEntry.inputSchemaVersion }
    var predictionArtifactHash: String { sourceEntry.predictionArtifactHash }
    var goldInputHash: String { sourceEntry.goldInputHash }
    var matchingPolicyVersion: String { sourceEntry.matchingPolicyVersion }
}

/// Every refusal is a closed code with no payload, path, transcript, identifier, or free-text error.
enum SemanticScorerRefusal: Error, Codable, CaseIterable, Equatable, Sendable {
    case sealedHoldout
    case authorizationMissing
    case sourceIndexNotFound
    case malformedSourceIndex
    case duplicateCaseID
    case unknownCaseID
    case unknownIndexSchemaVersion
    case unknownInputSchemaVersion
    case pendingInput
    case primaryNormalizedInput
    case secondaryReviewIncomplete
    case inputNotScorerReady
    case unknownInputStatus
    case caseIdentityMismatch
    case predictionArtifactHashMismatch
    case goldInputHashMismatch
    case unknownMatchingMapVersion
    case unknownMatchingPolicyVersion
    case duplicatePredictionReference
    case duplicateGoldReference
    case duplicatePredictionUse
    case duplicateGoldUse
    case danglingPredictionReference
    case danglingGoldReference
    case crossCasePair
    case crossKindPair
    case invalidIdentity
    case payloadFileNotFound
    case payloadHashMismatch
    case malformedPayload
    case payloadMetadataMismatch
    case payloadIdentityMismatch
    case unknownAmbiguityPolicyVersion
}

/// Metadata-first filesystem boundary for semantic scoring.
///
/// Authorization compares only the transcript-free index, the already-loaded prediction identity
/// inventory, and the explicit matching map. A payload URL does not exist until this store has
/// returned `AuthorizedSemanticScorerEntry`.
struct SemanticScorerInputStore: @unchecked Sendable {
    static let indexSchemaVersion = "haena-semantic-scorer-index-v0.1"
    static let sourceIndexFileName = "semantic-scorer-source-index.jsonl"

    private static let sourceIndexKeys: Set<String> = [
        "index_schema_version", "input_schema_version", "benchmark", "case_id", "split",
        "status", "scorer_ready", "secondary_review_complete", "prediction_artifact_hash",
        "gold_input_hash", "matching_policy_version", "gold_references",
    ]
    private static let goldReferenceKeys: Set<String> = [
        "input_schema_version", "case_id", "kind", "output_id",
    ]

    let root: URL
    let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Reads exactly one metadata-only file. It never forms or probes a scorer payload path.
    func sourceIndexEntries() throws -> [SemanticScorerSourceIndexEntry] {
        guard let data = fileManager.contents(atPath: sourceIndexURL.path),
              let text = String(data: data, encoding: .utf8) else {
            throw SemanticScorerRefusal.sourceIndexNotFound
        }

        var entries: [SemanticScorerSourceIndexEntry] = []
        var seenCaseIDs: Set<String> = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            do {
                let lineData = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      Set(object.keys) == Self.sourceIndexKeys,
                      let rawReferences = object["gold_references"] as? [[String: Any]],
                      rawReferences.allSatisfy({ Set($0.keys) == Self.goldReferenceKeys }) else {
                    throw SemanticScorerRefusal.malformedSourceIndex
                }
                let entry = try JSONDecoder().decode(SemanticScorerSourceIndexEntry.self, from: lineData)
                guard Self.isSafeIdentifier(entry.benchmark, maximumLength: 80),
                      Self.isSafeIdentifier(entry.caseID, maximumLength: 80) else {
                    throw SemanticScorerRefusal.malformedSourceIndex
                }
                guard seenCaseIDs.insert(entry.caseID).inserted else {
                    throw SemanticScorerRefusal.duplicateCaseID
                }
                entries.append(entry)
            } catch let refusal as SemanticScorerRefusal {
                throw refusal
            } catch {
                throw SemanticScorerRefusal.malformedSourceIndex
            }
        }
        return entries
    }

    /// Issues the only capability that can reach `loadInput(for:)`.
    ///
    /// All failures here occur before a payload URL is formed and therefore before a payload open.
    func authorize(_ request: SemanticScorerAuthorizationRequest) throws -> AuthorizedSemanticScorerEntry {
        guard request.requestedSplit == .development else {
            throw SemanticScorerRefusal.sealedHoldout
        }
        guard request.runtimeAuthorization?.scope == .development else {
            throw SemanticScorerRefusal.authorizationMissing
        }
        guard Self.isSafeIdentifier(request.benchmark, maximumLength: 80),
              Self.isSafeIdentifier(request.caseID, maximumLength: 80) else {
            throw SemanticScorerRefusal.invalidIdentity
        }

        let entries = try sourceIndexEntries()
        guard let entry = entries.first(where: { $0.caseID == request.caseID }) else {
            throw SemanticScorerRefusal.unknownCaseID
        }

        guard entry.indexSchemaVersion == Self.indexSchemaVersion else {
            throw SemanticScorerRefusal.unknownIndexSchemaVersion
        }
        guard entry.inputSchemaVersion == SemanticScorerInput.schemaVersion else {
            throw SemanticScorerRefusal.unknownInputSchemaVersion
        }
        guard entry.split == .development else {
            throw SemanticScorerRefusal.sealedHoldout
        }
        try Self.validateStatus(entry)
        guard entry.benchmark == request.benchmark,
              request.matchingMap.caseID == request.caseID else {
            throw SemanticScorerRefusal.caseIdentityMismatch
        }
        guard SemanticSHA256Digest.isCanonical(entry.predictionArtifactHash),
              SemanticSHA256Digest.isCanonical(entry.goldInputHash),
              SemanticSHA256Digest.isCanonical(request.matchingMap.predictionArtifactHash),
              SemanticSHA256Digest.isCanonical(request.matchingMap.goldInputHash) else {
            throw SemanticScorerRefusal.invalidIdentity
        }
        let verifiedPredictionHash = request.predictionArtifactFingerprint.rawValue
        guard entry.predictionArtifactHash == verifiedPredictionHash,
              request.matchingMap.predictionArtifactHash == verifiedPredictionHash else {
            throw SemanticScorerRefusal.predictionArtifactHashMismatch
        }
        guard entry.goldInputHash == request.matchingMap.goldInputHash else {
            throw SemanticScorerRefusal.goldInputHashMismatch
        }
        guard request.matchingMap.schemaVersion == SemanticMatchingMap.schemaVersion else {
            throw SemanticScorerRefusal.unknownMatchingMapVersion
        }
        guard entry.matchingPolicyVersion == SemanticMatchingMap.policyVersion,
              request.matchingMap.policyVersion == SemanticMatchingMap.policyVersion else {
            throw SemanticScorerRefusal.unknownMatchingPolicyVersion
        }

        try Self.validateGoldInventory(entry.goldReferences, entry: entry)
        try Self.validateMatchingMap(request.matchingMap, request: request, entry: entry)
        return AuthorizedSemanticScorerEntry(sourceEntry: entry)
    }

    /// Forms and opens the payload path only for a capability returned by `authorize(_:)`.
    func loadInput(for authorizedEntry: AuthorizedSemanticScorerEntry) throws -> SemanticScorerInput {
        guard let url = safelyResolvedPayloadURL(for: authorizedEntry) else {
            throw SemanticScorerRefusal.malformedSourceIndex
        }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw SemanticScorerRefusal.payloadFileNotFound
        }
        guard SemanticSHA256Digest.rawBytes(data) == authorizedEntry.sourceEntry.goldInputHash else {
            throw SemanticScorerRefusal.payloadHashMismatch
        }
        guard Self.hasExactPayloadShape(data) else {
            throw SemanticScorerRefusal.malformedPayload
        }

        let input: SemanticScorerInput
        do {
            input = try SemanticScorerInput.decoder.decode(SemanticScorerInput.self, from: data)
        } catch {
            throw SemanticScorerRefusal.malformedPayload
        }
        try Self.validate(input, against: authorizedEntry.sourceEntry)
        return input
    }

    var sourceIndexURL: URL {
        root.appendingPathComponent(Self.sourceIndexFileName, isDirectory: false)
    }

    private static func validateStatus(_ entry: SemanticScorerSourceIndexEntry) throws {
        switch entry.status {
        case SemanticScorerInputStatus.pending.rawValue:
            throw SemanticScorerRefusal.pendingInput
        case SemanticScorerInputStatus.primaryNormalizedPendingSecondaryReview.rawValue:
            throw SemanticScorerRefusal.primaryNormalizedInput
        case SemanticScorerInputStatus.secondaryReviewInProgress.rawValue:
            throw SemanticScorerRefusal.secondaryReviewIncomplete
        case SemanticScorerInputStatus.scorerReady.rawValue:
            break
        default:
            throw SemanticScorerRefusal.unknownInputStatus
        }
        guard entry.scorerReady else {
            throw SemanticScorerRefusal.inputNotScorerReady
        }
        guard entry.secondaryReviewComplete else {
            throw SemanticScorerRefusal.secondaryReviewIncomplete
        }
    }

    private static func validateGoldInventory(
        _ references: [SemanticGoldReference],
        entry: SemanticScorerSourceIndexEntry
    ) throws {
        guard references.allSatisfy({
            $0.inputSchemaVersion == entry.inputSchemaVersion
                && $0.caseID == entry.caseID
                && isSafeIdentifier($0.outputID.rawValue, maximumLength: 120)
        }) else {
            throw SemanticScorerRefusal.caseIdentityMismatch
        }
        guard Set(references).count == references.count,
              Set(references.map(\.outputID)).count == references.count else {
            throw SemanticScorerRefusal.duplicateGoldReference
        }
    }

    private static func validateMatchingMap(
        _ map: SemanticMatchingMap,
        request: SemanticScorerAuthorizationRequest,
        entry: SemanticScorerSourceIndexEntry
    ) throws {
        guard request.availablePredictions.allSatisfy({
            $0.caseID == request.caseID
                && $0.artifactFingerprint == request.predictionArtifactFingerprint.rawValue
        }) else {
            throw SemanticScorerRefusal.caseIdentityMismatch
        }
        guard Set(request.availablePredictions).count == request.availablePredictions.count else {
            throw SemanticScorerRefusal.duplicatePredictionReference
        }

        let predictions = Set(request.availablePredictions)
        let gold = Set(entry.goldReferences)
        var usedPredictions: Set<SemanticPredictionReference> = []
        var usedGold: Set<SemanticGoldReference> = []

        for pair in map.pairs {
            guard pair.prediction.caseID == map.caseID,
                  pair.gold.caseID == map.caseID else {
                throw SemanticScorerRefusal.crossCasePair
            }
            guard pair.prediction.kind == pair.gold.kind else {
                throw SemanticScorerRefusal.crossKindPair
            }
            guard pair.prediction.artifactFingerprint
                == request.predictionArtifactFingerprint.rawValue else {
                throw SemanticScorerRefusal.predictionArtifactHashMismatch
            }
            guard pair.gold.inputSchemaVersion == entry.inputSchemaVersion else {
                throw SemanticScorerRefusal.unknownInputSchemaVersion
            }
            guard predictions.contains(pair.prediction) else {
                throw SemanticScorerRefusal.danglingPredictionReference
            }
            guard gold.contains(pair.gold) else {
                throw SemanticScorerRefusal.danglingGoldReference
            }
            guard usedPredictions.insert(pair.prediction).inserted else {
                throw SemanticScorerRefusal.duplicatePredictionUse
            }
            guard usedGold.insert(pair.gold).inserted else {
                throw SemanticScorerRefusal.duplicateGoldUse
            }
        }
    }

    private static func validate(
        _ input: SemanticScorerInput,
        against entry: SemanticScorerSourceIndexEntry
    ) throws {
        guard input.schemaVersion == entry.inputSchemaVersion,
              input.status == .scorerReady,
              input.scorerReady,
              input.secondaryReviewComplete,
              input.benchmark == entry.benchmark,
              input.caseID == entry.caseID,
              input.split == .development,
              input.predictionArtifactHash == entry.predictionArtifactHash,
              input.matchingPolicyVersion == entry.matchingPolicyVersion else {
            throw SemanticScorerRefusal.payloadMetadataMismatch
        }
        guard input.ambiguityPolicy.schemaVersion == SemanticAmbiguityPolicy.schemaVersion else {
            throw SemanticScorerRefusal.unknownAmbiguityPolicyVersion
        }

        let payloadReferences = input.outputs.referencesByKind.map { kind, output in
            SemanticGoldReference(
                inputSchemaVersion: input.schemaVersion,
                caseID: input.caseID,
                kind: kind,
                outputID: output.id
            )
        }
        guard Set(payloadReferences) == Set(entry.goldReferences),
              payloadReferences.count == entry.goldReferences.count else {
            throw SemanticScorerRefusal.payloadIdentityMismatch
        }
        try validatePayloadSemantics(input)
    }

    private static func validatePayloadSemantics(_ input: SemanticScorerInput) throws {
        let references = input.outputs.referencesByKind
        guard Set(references.map { $0.1.id }).count == references.count else {
            throw SemanticScorerRefusal.duplicateGoldReference
        }

        for (kind, output) in references {
            guard isSafeIdentifier(output.id.rawValue, maximumLength: 120),
                  isValidEvidence(output.evidenceUtteranceIDs) else {
                throw SemanticScorerRefusal.invalidIdentity
            }
            if kind == .actionItem {
                guard let assignee = output.assignee, let due = output.due else {
                    throw SemanticScorerRefusal.malformedPayload
                }
                try validate(assignee)
                try validate(due)
            } else if output.assignee != nil || output.due != nil {
                throw SemanticScorerRefusal.malformedPayload
            }
        }

        guard Set(input.forbiddenInferences.map(\.id)).count == input.forbiddenInferences.count else {
            throw SemanticScorerRefusal.invalidIdentity
        }
        for item in input.forbiddenInferences {
            guard isSafeIdentifier(item.id, maximumLength: 120) else {
                throw SemanticScorerRefusal.invalidIdentity
            }
            switch item.basis {
            case .utterance:
                guard isValidEvidence(item.evidenceUtteranceIDs) else {
                    throw SemanticScorerRefusal.invalidIdentity
                }
            case .absenceInWindow, .reviewMethod:
                guard item.evidenceUtteranceIDs.isEmpty else {
                    throw SemanticScorerRefusal.malformedPayload
                }
            }
        }

        guard Set(input.ambiguityPolicy.ambiguityIDs).count == input.ambiguityPolicy.ambiguityIDs.count,
              input.ambiguityPolicy.ambiguityIDs.allSatisfy({
                  isSafeIdentifier($0, maximumLength: 120)
              }) else {
            throw SemanticScorerRefusal.invalidIdentity
        }
    }

    private static func validate(_ assignee: SemanticAssigneeExpectation) throws {
        guard isUniqueSafeReferences(assignee.evidenceUtteranceIDs) else {
            throw SemanticScorerRefusal.invalidIdentity
        }
        switch assignee.basis {
        case .absentMustStayEmpty:
            guard assignee.valueReference == nil, assignee.evidenceUtteranceIDs.isEmpty else {
                throw SemanticScorerRefusal.malformedPayload
            }
        case .speakerCommitment, .supportedByUtterance:
            guard let reference = assignee.valueReference,
                  isSafeIdentifier(reference, maximumLength: 120),
                  !assignee.evidenceUtteranceIDs.isEmpty else {
                throw SemanticScorerRefusal.invalidIdentity
            }
        }
    }

    private static func validate(_ due: SemanticDueExpectation) throws {
        guard isUniqueSafeReferences(due.evidenceUtteranceIDs) else {
            throw SemanticScorerRefusal.invalidIdentity
        }
        switch due.status {
        case .absent:
            guard due.value == nil, due.evidenceUtteranceIDs.isEmpty else {
                throw SemanticScorerRefusal.malformedPayload
            }
        case .explicit, .explicitRelative:
            guard let value = due.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 120,
                  !due.evidenceUtteranceIDs.isEmpty else {
                throw SemanticScorerRefusal.invalidIdentity
            }
        case .unresolved:
            guard let value = due.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 120 else {
                throw SemanticScorerRefusal.invalidIdentity
            }
        }
    }

    private static func isValidEvidence(_ values: [String]) -> Bool {
        !values.isEmpty && isUniqueSafeReferences(values)
    }

    private static func isUniqueSafeReferences(_ values: [String]) -> Bool {
        Set(values).count == values.count
            && values.allSatisfy { isSafeIdentifier($0, maximumLength: 120) }
    }

    private static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
                .contains($0)
        }
    }

    private static func isLexicallySafeRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            return false
        }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func safelyResolvedPayloadURL(for entry: AuthorizedSemanticScorerEntry) -> URL? {
        let relativePath = "semantic-scorer-inputs/\(entry.sourceEntry.caseID).json"
        guard Self.isLexicallySafeRelativePath(relativePath) else { return nil }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }

    private static func hasExactPayloadShape(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                  "schema_version", "status", "scorer_ready", "secondary_review_complete",
                  "benchmark", "case_id", "split", "prediction_artifact_hash",
                  "matching_policy_version", "outputs", "forbidden_inferences", "ambiguity_policy",
              ],
              let outputs = root["outputs"] as? [String: Any],
              Set(outputs.keys) == ["decisions", "action_items", "open_questions", "next_agenda"],
              outputs.values.allSatisfy({ value in
                  guard let records = value as? [[String: Any]] else { return false }
                  return records.allSatisfy(hasExactOutputShape)
              }),
              let forbidden = root["forbidden_inferences"] as? [[String: Any]],
              forbidden.allSatisfy({ Set($0.keys) == ["id", "output_kind", "basis", "evidence_utterance_ids"] }),
              let ambiguity = root["ambiguity_policy"] as? [String: Any],
              Set(ambiguity.keys) == ["schema_version", "handling", "ambiguity_ids"] else {
            return false
        }
        return true
    }

    private static func hasExactOutputShape(_ output: [String: Any]) -> Bool {
        let required: Set<String> = [
            "id", "evidence_utterance_ids", "inference_class", "target_speaker_responsibility",
        ]
        let allowed = required.union(["assignee", "due"])
        guard required.isSubset(of: Set(output.keys)), Set(output.keys).isSubset(of: allowed) else {
            return false
        }
        if let assignee = output["assignee"] as? [String: Any],
           Set(assignee.keys) != ["scope", "basis", "value_reference", "evidence_utterance_ids"] {
            return false
        }
        if let due = output["due"] as? [String: Any],
           Set(due.keys) != ["status", "value", "evidence_utterance_ids"] {
            return false
        }
        return true
    }
}
