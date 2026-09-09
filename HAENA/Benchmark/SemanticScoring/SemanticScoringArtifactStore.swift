import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

enum SemanticScoringCLIRefusal: Error, Equatable, Sendable {
    case sealedSplit
    case authorizationMissing
    case noDevelopmentCases
    case invalidIdentity
    case unsafeInputPath
    case outputExists
    case outputInsideInputRoot
    case predictionFileNotFound
    case malformedPredictionArtifact
    case unknownPredictionSchema
    case unknownPredictionArtifactKind
    case predictionIdentityMismatch
    case duplicatePredictionReference
    case matchingMapFileNotFound
    case malformedMatchingMap
    case observationFileNotFound
    case malformedObservationSet
    case unknownReportPolicyVersion
    case scorer(SemanticScorerRefusal)
    case reportConstructionFailed
    case outputWriteFailed

    var code: String {
        switch self {
        case .sealedSplit: "sealed_split"
        case .authorizationMissing: "authorization_missing"
        case .noDevelopmentCases: "no_development_cases"
        case .invalidIdentity: "invalid_identity"
        case .unsafeInputPath: "unsafe_input_path"
        case .outputExists: "output_exists"
        case .outputInsideInputRoot: "output_inside_input_root"
        case .predictionFileNotFound: "prediction_file_not_found"
        case .malformedPredictionArtifact: "malformed_prediction_artifact"
        case .unknownPredictionSchema: "unknown_prediction_schema"
        case .unknownPredictionArtifactKind: "unknown_prediction_artifact_kind"
        case .predictionIdentityMismatch: "prediction_identity_mismatch"
        case .duplicatePredictionReference: "duplicate_prediction_reference"
        case .matchingMapFileNotFound: "matching_map_file_not_found"
        case .malformedMatchingMap: "malformed_matching_map"
        case .observationFileNotFound: "observation_file_not_found"
        case .malformedObservationSet: "malformed_observation_set"
        case .unknownReportPolicyVersion: "unknown_report_policy_version"
        case .scorer(let refusal): "scorer_\(String(describing: refusal))"
        case .reportConstructionFailed: "report_construction_failed"
        case .outputWriteFailed: "output_write_failed"
        }
    }
}

struct SemanticScoringReportPolicy: Equatable, Sendable {
    static let current = SemanticScoringReportPolicy(
        schemaVersion: SemanticRegressionReport.schemaVersion
    )

    let schemaVersion: String
}

/// Filesystem adapter for the explicit semantic scorer CLI.
///
/// Every read uses `FileManager.contents(atPath:)`, allowing tests to count the exact files opened.
/// Input roots are resolved before a case filename is appended, and a symlinked case file may not
/// escape its declared root. The final report is the only write surface.
struct SemanticScoringArtifactStore: @unchecked Sendable {
    static let predictionSuffix = ".prediction.json"
    static let matchingMapSuffix = ".matching-map.json"
    static let observationSuffix = ".observations.json"

    let scorerRoot: URL
    let predictionDirectory: URL
    let matchingMapDirectory: URL
    let observationDirectory: URL
    let outputFile: URL
    let fileManager: FileManager

    init(options: SemanticScoringCommandLine.Options, fileManager: FileManager = .default) {
        scorerRoot = URL(fileURLWithPath: options.scorerRoot, isDirectory: true).standardizedFileURL
        predictionDirectory = URL(
            fileURLWithPath: options.predictionDirectory,
            isDirectory: true
        ).standardizedFileURL
        matchingMapDirectory = URL(
            fileURLWithPath: options.matchingMapDirectory,
            isDirectory: true
        ).standardizedFileURL
        observationDirectory = URL(
            fileURLWithPath: options.observationDirectory,
            isDirectory: true
        ).standardizedFileURL
        outputFile = URL(fileURLWithPath: options.outputFile, isDirectory: false)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    func validateOutputBoundary() throws {
        let output = resolvedOutputFile
        let roots = [scorerRoot, predictionDirectory, matchingMapDirectory, observationDirectory]
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard roots.allSatisfy({ !Self.contains(output, root: $0) }) else {
            throw SemanticScoringCLIRefusal.outputInsideInputRoot
        }
        if fileManager.fileExists(atPath: output.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: output.path)) != nil {
            throw SemanticScoringCLIRefusal.outputExists
        }
    }

    func selectedCaseIDs(
        _ selection: SemanticScoringCommandLine.Selection,
        benchmark: String
    ) throws -> [String] {
        guard Self.isSafeIdentifier(benchmark, maximumLength: 80) else {
            throw SemanticScoringCLIRefusal.invalidIdentity
        }
        switch selection {
        case .caseIDs(let caseIDs):
            guard Set(caseIDs).count == caseIDs.count,
                  caseIDs.allSatisfy({ Self.isSafeIdentifier($0, maximumLength: 80) }) else {
                throw SemanticScoringCLIRefusal.invalidIdentity
            }
            return caseIDs
        case .allDevelopment:
            let entries: [SemanticScorerSourceIndexEntry]
            do {
                entries = try SemanticScorerInputStore(
                    root: scorerRoot,
                    fileManager: fileManager
                ).sourceIndexEntries()
            } catch let refusal as SemanticScorerRefusal {
                throw SemanticScoringCLIRefusal.scorer(refusal)
            }
            let caseIDs = entries.filter {
                $0.split == .development && $0.benchmark == benchmark
            }.map(\.caseID).sorted()
            guard !caseIDs.isEmpty else {
                throw SemanticScoringCLIRefusal.noDevelopmentCases
            }
            return caseIDs
        }
    }

    /// Executes the ordered case-loading contract. No report bytes are written here.
    func loadCase(
        caseID: String,
        benchmark: String,
        runtimeAuthorization: SemanticScorerRuntimeAuthorization
    ) throws -> AuthorizedSemanticMetricScoringCase {
        guard Self.isSafeIdentifier(caseID, maximumLength: 80),
              Self.isSafeIdentifier(benchmark, maximumLength: 80) else {
            throw SemanticScoringCLIRefusal.invalidIdentity
        }

        // 1-6: open exact prediction bytes, fingerprint those bytes, decode the immutable v0.2
        // artifact contract, validate identity, then derive exact typed prediction references.
        let predictionData = try read(
            root: predictionDirectory,
            fileName: caseID + Self.predictionSuffix,
            missing: .predictionFileNotFound
        )
        let fingerprint = PredictionArtifactFingerprint.rawArtifactBytes(predictionData)
        let artifact: PredictionArtifact
        do {
            artifact = try PredictionArtifact.decoder.decode(
                PredictionArtifact.self,
                from: predictionData
            )
        } catch {
            throw SemanticScoringCLIRefusal.malformedPredictionArtifact
        }
        guard artifact.artifactSchemaVersion == PredictionArtifact.schemaVersion else {
            throw SemanticScoringCLIRefusal.unknownPredictionSchema
        }
        guard artifact.artifactKind == PredictionArtifact.artifactKind else {
            throw SemanticScoringCLIRefusal.unknownPredictionArtifactKind
        }
        guard artifact.caseID == caseID,
              artifact.benchmark == benchmark,
              artifact.split == .development,
              artifact.scoring.status == .unscored else {
            throw SemanticScoringCLIRefusal.predictionIdentityMismatch
        }
        let predictions = artifact.mapped.map {
            SemanticPredictionReference(
                artifactFingerprint: fingerprint.rawValue,
                caseID: caseID,
                kind: SemanticScoringOutputKind($0.kind),
                proposalID: $0.id
            )
        }
        guard Set(predictions).count == predictions.count else {
            throw SemanticScoringCLIRefusal.duplicatePredictionReference
        }

        // 7: only a valid prediction artifact can cause matching and observation files to open.
        let matchingMap: SemanticMatchingMap
        do {
            matchingMap = try SemanticMatchingMap.decoder.decode(
                SemanticMatchingMap.self,
                from: read(
                    root: matchingMapDirectory,
                    fileName: caseID + Self.matchingMapSuffix,
                    missing: .matchingMapFileNotFound
                )
            )
        } catch let refusal as SemanticScoringCLIRefusal {
            throw refusal
        } catch {
            throw SemanticScoringCLIRefusal.malformedMatchingMap
        }

        let observationSet: SemanticPredictionMetricObservationSet
        do {
            observationSet = try JSONDecoder().decode(
                SemanticPredictionMetricObservationSet.self,
                from: read(
                    root: observationDirectory,
                    fileName: caseID + Self.observationSuffix,
                    missing: .observationFileNotFound
                )
            )
        } catch let refusal as SemanticScoringCLIRefusal {
            throw refusal
        } catch {
            throw SemanticScoringCLIRefusal.malformedObservationSet
        }

        // 8-10: the existing metadata-only gate runs before it can form the gold payload URL;
        // gold raw-byte hash, shape, schema, identities, and forbidden references are then checked.
        let scorerStore = SemanticScorerInputStore(root: scorerRoot, fileManager: fileManager)
        do {
            let entry = try scorerStore.authorizeMetrics(
                SemanticMetricAuthorizationRequest(
                    scorerRequest: SemanticScorerAuthorizationRequest(
                        runtimeAuthorization: runtimeAuthorization,
                        requestedSplit: .development,
                        benchmark: benchmark,
                        caseID: caseID,
                        predictionArtifactFingerprint: fingerprint,
                        availablePredictions: predictions,
                        matchingMap: matchingMap
                    ),
                    predictionObservations: observationSet
                )
            )
            return try scorerStore.loadMetricScoringCase(for: entry)
        } catch let refusal as SemanticScorerRefusal {
            throw SemanticScoringCLIRefusal.scorer(refusal)
        }
    }

    /// Encodes with the report's sole encoder, writes a private sibling, then atomically renames.
    /// A second collision check closes the race between initial validation and final persistence.
    func write(_ report: SemanticRegressionReport) throws {
        try validateOutputBoundary()
        let data: Data
        do {
            data = try SemanticRegressionReport.encoder.encode(report)
        } catch {
            throw SemanticScoringCLIRefusal.outputWriteFailed
        }

        let output = resolvedOutputFile
        let parent = output.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SemanticScoringCLIRefusal.outputWriteFailed
        }

        let temporary = parent.appendingPathComponent(
            ".\(output.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? fileManager.removeItem(at: temporary)
            throw SemanticScoringCLIRefusal.outputWriteFailed
        }
        do {
            guard !fileManager.fileExists(atPath: output.path) else {
                throw SemanticScoringCLIRefusal.outputExists
            }
            try fileManager.moveItem(at: temporary, to: output)
        } catch let refusal as SemanticScoringCLIRefusal {
            try? fileManager.removeItem(at: temporary)
            throw refusal
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SemanticScoringCLIRefusal.outputWriteFailed
        }
    }

    private func read(
        root: URL,
        fileName: String,
        missing: SemanticScoringCLIRefusal
    ) throws -> Data {
        guard let url = Self.safelyResolvedFile(root: root, fileName: fileName) else {
            throw SemanticScoringCLIRefusal.unsafeInputPath
        }
        guard let data = fileManager.contents(atPath: url.path) else { throw missing }
        return data
    }

    private var resolvedOutputFile: URL {
        let standardized = outputFile.standardizedFileURL
        return standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
    }

    private static func safelyResolvedFile(root: URL, fileName: String) -> URL? {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\\") else {
            return nil
        }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = root.appendingPathComponent(fileName, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return contains(candidate, root: root) ? candidate : nil
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private static func isSafeIdentifier(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty,
              value.count <= maximumLength,
              !value.contains("..") else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
