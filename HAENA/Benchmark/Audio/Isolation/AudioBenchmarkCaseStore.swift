import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Unforgeable development-read capability issued only by `authorizedEntries(for:)`.
///
/// Its initializer and stored source entry are file-private, so another harness component cannot
/// turn sealed metadata into a development entry by changing a public `split` field.
struct AudioBenchmarkAuthorizedEntry: Equatable, Sendable {
    fileprivate let sourceEntry: AudioBenchmarkSourceIndexEntry

    var caseID: String { sourceEntry.caseID }
    var split: AudioBenchmarkSplit { sourceEntry.split }
    var schemaVersion: String { sourceEntry.schemaVersion }
    var benchmark: String { sourceEntry.benchmark }
    var reviewStatus: String { sourceEntry.reviewStatus }
}

/// Filesystem boundary for audio benchmark discovery and authorized content reads.
///
/// `datasetRoot` is the `audio-robustness-v0` directory. `sourceAssetRoot` is the root against
/// which a case's source WAV path is resolved only after the case has passed development
/// authorization. Every read goes through the injected `FileManager`, allowing regression tests to
/// prove that discovery and development execution never ask for a manifest or holdout asset.
struct AudioBenchmarkCaseStore: @unchecked Sendable {
    static let benchmark = "audio-robustness-v0"
    static let schemaVersion = "haena-benchmark-v0.1"
    static let reviewStatus = "source_aligned_label"
    static let sourceIndexFileName = "source-index.jsonl"

    private static let sourceIndexKeys: Set<String> = [
        "schema_version", "benchmark", "case_id", "split", "review_status", "case_path",
    ]

    let datasetRoot: URL
    let sourceAssetRoot: URL
    let fileManager: FileManager

    init(
        datasetRoot: URL,
        sourceAssetRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.datasetRoot = datasetRoot.standardizedFileURL
        self.sourceAssetRoot = (sourceAssetRoot ?? datasetRoot).standardizedFileURL
        self.fileManager = fileManager
    }

    /// Reads exactly one file: the metadata-only source index.
    func sourceIndexEntries() throws -> [AudioBenchmarkSourceIndexEntry] {
        guard let data = fileManager.contents(atPath: sourceIndexURL.path) else {
            throw AudioBenchmarkIsolationError.sourceIndexNotFound
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AudioBenchmarkIsolationError.malformedSourceIndexLine(lineNumber: 1)
        }

        let decoder = JSONDecoder()
        var entries: [AudioBenchmarkSourceIndexEntry] = []
        var seenCaseIDs: Set<String> = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let entry: AudioBenchmarkSourceIndexEntry
            do {
                let lineData = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      Set(object.keys) == Self.sourceIndexKeys else {
                    throw AudioSourceIndexValidationError.invalidKeys
                }
                entry = try decoder.decode(AudioBenchmarkSourceIndexEntry.self, from: lineData)
                try validate(entry)
            } catch {
                throw AudioBenchmarkIsolationError.malformedSourceIndexLine(lineNumber: offset + 1)
            }

            guard seenCaseIDs.insert(entry.caseID).inserted else {
                throw AudioBenchmarkIsolationError.duplicateCaseID
            }
            entries.append(entry)
        }
        return entries
    }

    /// Resolves a requested run set while touching no case, gold, audio, or manifest.
    ///
    /// A whole sealed split is refused before even the metadata index is read. For explicit ids the
    /// index is the minimum information needed to decide their split; the refusal carries no ids and
    /// no sealed case file is formed or opened.
    func authorizedEntries(for selection: AudioBenchmarkSelection) throws -> [AudioBenchmarkAuthorizedEntry] {
        switch selection {
        case .sealedHoldout:
            throw AudioBenchmarkIsolationError.sealedHoldoutLocked
        case .development:
            return try sourceIndexEntries()
                .filter { $0.split == .development }
                .map(AudioBenchmarkAuthorizedEntry.init(sourceEntry:))
        case .caseIDs(let requestedIDs):
            let all = try sourceIndexEntries()
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.caseID, $0) })
            let resolved = try requestedIDs.map { caseID in
                guard let entry = byID[caseID] else {
                    throw AudioBenchmarkIsolationError.unknownCaseID
                }
                return entry
            }
            try authorize(resolved)
            return resolved.map(AudioBenchmarkAuthorizedEntry.init(sourceEntry:))
        }
    }

    /// Opens an authorized development case/gold payload. The caller owns schema decoding.
    func caseData(for entry: AudioBenchmarkAuthorizedEntry) throws -> Data {
        guard let url = safelyResolvedURL(relativePath: entry.sourceEntry.casePath, under: datasetRoot) else {
            throw AudioBenchmarkIsolationError.invalidRelativePath
        }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw AudioBenchmarkIsolationError.caseFileNotFound
        }
        return data
    }

    /// Opens a source asset only for an already-authorized development entry.
    ///
    /// The relative source path is deliberately absent from the discovery index. It may be decoded
    /// from development case data only after `caseData(for:)` succeeds, then passed here so the same
    /// authorization and recording boundary covers the WAV read.
    func sourceAssetData(relativePath: String, for entry: AudioBenchmarkAuthorizedEntry) throws -> Data {
        guard let url = safelyResolvedURL(relativePath: relativePath, under: sourceAssetRoot) else {
            throw AudioBenchmarkIsolationError.invalidRelativePath
        }
        guard let data = fileManager.contents(atPath: url.path) else {
            throw AudioBenchmarkIsolationError.sourceAssetNotFound
        }
        return data
    }

    /// Returns a safely resolved URL for streaming WAV extraction after development authorization.
    /// It performs no filesystem access; the runner must keep using the same injected FileManager or
    /// another explicitly recording reader if it opens the URL.
    func authorizedSourceAssetURL(
        relativePath: String,
        for entry: AudioBenchmarkAuthorizedEntry
    ) throws -> URL {
        guard let url = safelyResolvedURL(relativePath: relativePath, under: sourceAssetRoot) else {
            throw AudioBenchmarkIsolationError.invalidRelativePath
        }
        return url
    }

    var sourceIndexURL: URL {
        datasetRoot.appendingPathComponent(Self.sourceIndexFileName, isDirectory: false)
    }

    private func authorize(_ entries: [AudioBenchmarkSourceIndexEntry]) throws {
        guard entries.allSatisfy({ $0.split == .development }) else {
            throw AudioBenchmarkIsolationError.sealedHoldoutLocked
        }
    }

    private func validate(_ entry: AudioBenchmarkSourceIndexEntry) throws {
        guard entry.benchmark == Self.benchmark,
              entry.schemaVersion == Self.schemaVersion,
              entry.reviewStatus == Self.reviewStatus,
              isSafeComponent(entry.caseID),
              entry.caseID.count <= 80,
              entry.casePath == "gold/\(entry.caseID).json",
              isLexicallySafeRelativePath(entry.casePath) else {
            throw AudioSourceIndexValidationError.invalidValue
        }
    }

    private func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                .contains(scalar)
        }
    }

    private func isLexicallySafeRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    }

    /// Resolves symlinks only after split authorization. Discovery calls lexical validation above,
    /// so it still performs exactly one index read and never probes case paths.
    private func safelyResolvedURL(relativePath: String, under root: URL) -> URL? {
        guard isLexicallySafeRelativePath(relativePath) else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)

        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { return nil }
        return candidate
    }
}

private enum AudioSourceIndexValidationError: Error {
    case invalidKeys
    case invalidValue
}
