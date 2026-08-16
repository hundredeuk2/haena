import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

// MARK: - Errors

/// Corpus-loading failures.
///
/// No case carries a filesystem path. A prediction artifact, a CI log, and a bug report all end up
/// somewhere the dataset root does not belong, and `/Users/<name>/...` is exactly the kind of
/// detail that leaks into all three by accident. The case id and the relative file name are enough
/// to act on.
enum BenchmarkCaseStoreError: Error, Equatable, Sendable {
    /// Payload is the relative file name (`source-index.jsonl`), deliberately not the absolute path.
    case sourceIndexNotFound(String)
    case caseFileNotFound(caseID: String)
    case unknownCaseID(String)
    case sourceIndexEntryMismatch(caseID: String)
    /// 1-based, counting every physical line including blank ones, so the number points straight
    /// at the offending line of the file.
    case malformedSourceIndexLine(lineNumber: Int)
    case malformedCaseFile(caseID: String)
}

// MARK: - Store

/// Reads the local corpus. The only component that touches the filesystem under `data/`.
///
/// The sealed-holdout gate lives here, not in the runner: a locked case must not be *read*, not
/// merely left unscored — an unlocked file that was opened is already contaminated. Concretely,
/// `prepared(_:)` consults the policy *before* it forms a URL, so a locked case fails identically
/// whether or not its file exists on disk.
///
/// `@unchecked Sendable` for one reason: `FileManager` declares its `Sendable` conformance
/// unavailable, yet the only operations used here — `contents(atPath:)` and `fileExists(atPath:)`
/// on an instance with no delegate — are documented as safe to call from multiple threads. Every
/// other stored property is a value type. Reads go through `fileManager` rather than
/// `Data(contentsOf:)` so that the injected file manager sees every access, which is what lets a
/// test assert that a locked case file was never opened.
struct BenchmarkCaseStore: @unchecked Sendable {
    /// `.../haena-v0/meeting-execution-v0`
    let datasetRoot: URL
    let benchmark: String
    let policy: BenchmarkAccessPolicy
    let fileManager: FileManager
    private let sourceIndexCache: BenchmarkSourceIndexCache

    static let sourceIndexFileName = "source-index.jsonl"
    private static let sourceIndexKeys: Set<String> = [
        "case_id", "split", "benchmark", "schema_version", "review_status", "case_path"
    ]

    init(
        datasetRoot: URL,
        benchmark: String = "meeting-execution-v0",
        policy: BenchmarkAccessPolicy = .offlineDefault,
        fileManager: FileManager = .default
    ) {
        self.datasetRoot = datasetRoot
        self.benchmark = benchmark
        self.policy = policy
        self.fileManager = fileManager
        self.sourceIndexCache = BenchmarkSourceIndexCache()
    }

    // MARK: - Discovery

    /// Every transcript-free source-index entry, unfiltered. Reads no case file or manifest.
    func sourceIndexEntries() throws -> [BenchmarkSourceIndexEntry] {
        if let cached = sourceIndexCache.value {
            return cached
        }

        let url = sourceIndexURL
        guard let data = fileManager.contents(atPath: url.path) else {
            throw BenchmarkCaseStoreError.sourceIndexNotFound(Self.sourceIndexFileName)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BenchmarkCaseStoreError.malformedSourceIndexLine(lineNumber: 1)
        }

        let decoder = JSONDecoder()
        var entries: [BenchmarkSourceIndexEntry] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            do {
                let lineData = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      Set(object.keys) == Self.sourceIndexKeys else {
                    throw SourceIndexValidationError.invalidKeys
                }
                let entry = try decoder.decode(BenchmarkSourceIndexEntry.self, from: lineData)
                guard entry.casePath == "cases/\(entry.caseID).json" else {
                    throw SourceIndexValidationError.invalidCasePath
                }
                entries.append(entry)
            } catch {
                // The underlying decoding error is dropped so corpus metadata cannot be copied
                // into a log through an error description.
                throw BenchmarkCaseStoreError.malformedSourceIndexLine(lineNumber: index + 1)
            }
        }
        sourceIndexCache.store(entries)
        return entries
    }

    /// Entries for one split. Throws via the policy when the split is sealed and locked.
    ///
    /// Authorization runs before the source index is opened, so a locked request costs no read at
    /// all.
    func entries(in split: BenchmarkSplit) throws -> [BenchmarkSourceIndexEntry] {
        try policy.authorizeSplit(split)
        return try sourceIndexEntries().filter { $0.split == split }
    }

    /// Entries for explicit ids, in the order given. Throws on an unknown id, and via the policy
    /// when any id belongs to a locked split.
    func entries(caseIDs: [String]) throws -> [BenchmarkSourceIndexEntry] {
        let all = try sourceIndexEntries()
        var index: [String: BenchmarkSourceIndexEntry] = [:]
        for entry in all {
            index[entry.caseID] = entry
        }

        var resolved: [BenchmarkSourceIndexEntry] = []
        for caseID in caseIDs {
            guard let entry = index[caseID] else {
                throw BenchmarkCaseStoreError.unknownCaseID(caseID)
            }
            resolved.append(entry)
        }

        try policy.authorizeCases(resolved)
        return resolved
    }

    // MARK: - Loading

    /// Loads and prepares one case. Re-checks the policy before opening the file.
    ///
    /// The re-check is not redundant with `entries(caseIDs:)`. An entry is an ordinary value that a
    /// caller can construct, cache, or pass along; the guarantee has to hold at the moment of the
    /// read, in the one place that performs it.
    func prepared(_ entry: BenchmarkSourceIndexEntry) throws -> BenchmarkPreparedCase {
        // Preserve the strongest early refusal: an explicitly sealed value is rejected without
        // even opening the metadata index. A value claiming to be development is not trusted,
        // however, because entries are ordinary values and could be forged or stale. Resolve it
        // against the index again, then authorize that canonical split before opening a case file.
        if entry.split == .sealedHoldout {
            try policy.authorizeCases([entry])
        }

        guard let indexedEntry = try sourceIndexEntries().first(where: { $0.caseID == entry.caseID }) else {
            throw BenchmarkCaseStoreError.unknownCaseID(entry.caseID)
        }
        try policy.authorizeCases([indexedEntry])
        guard indexedEntry == entry else {
            throw BenchmarkCaseStoreError.sourceIndexEntryMismatch(caseID: entry.caseID)
        }

        let url = caseFileURL(entry: indexedEntry)
        guard let data = fileManager.contents(atPath: url.path) else {
            throw BenchmarkCaseStoreError.caseFileNotFound(caseID: entry.caseID)
        }

        let caseFile: BenchmarkCaseFile
        do {
            // The schema's own decoder, so a future configuration change lands in one place.
            caseFile = try BenchmarkCaseFile.decoder.decode(BenchmarkCaseFile.self, from: data)
        } catch {
            // Same reasoning as the manifest: a decoding error would carry case content.
            throw BenchmarkCaseStoreError.malformedCaseFile(caseID: entry.caseID)
        }

        guard caseFile.caseID == indexedEntry.caseID,
              caseFile.benchmark == indexedEntry.benchmark,
              caseFile.schemaVersion == indexedEntry.schemaVersion else {
            throw BenchmarkCaseStoreError.malformedCaseFile(caseID: entry.caseID)
        }

        return try BenchmarkExtractionInputAdapter.prepare(
            caseFile: caseFile,
            rawCaseBytes: data,
            authorizedSplit: indexedEntry.split
        )
    }

    // MARK: - Paths

    var sourceIndexURL: URL {
        datasetRoot.appendingPathComponent(Self.sourceIndexFileName)
    }

    func caseFileURL(entry: BenchmarkSourceIndexEntry) -> URL {
        datasetRoot.appendingPathComponent(entry.casePath)
    }
}

private enum SourceIndexValidationError: Error {
    case invalidKeys
    case invalidCasePath
}

/// A store instance treats its validated metadata index as an immutable discovery snapshot.
/// This keeps a whole development run to one index read while still letting `prepared(_:)`
/// compare caller-supplied values with the canonical entry before any case file is opened.
private final class BenchmarkSourceIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [BenchmarkSourceIndexEntry]?

    var value: [BenchmarkSourceIndexEntry]? {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func store(_ entries: [BenchmarkSourceIndexEntry]) {
        lock.lock()
        if self.entries == nil {
            self.entries = entries
        }
        lock.unlock()
    }
}
