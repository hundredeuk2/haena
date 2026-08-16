import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Parses the harness's command line into an intent, and nothing else.
///
/// Deliberately pure: it opens no file, spawns no process, and reads no environment variable, so
/// every flag combination — including the dangerous ones — can be asserted in a unit test without a
/// dataset on disk. It also does not *enforce* the access rules it parses; it fills in a
/// `BenchmarkAccessPolicy` and leaves the refusal to that type, so the same gate protects a run
/// started from code as one started from a terminal.
struct BenchmarkCommandLine: Equatable, Sendable {
    struct Options: Equatable, Sendable {
        var datasetRoot: String
        /// No default, on purpose. A default output directory is how prediction files end up
        /// written into a user's data directory — or into the corpus itself — by someone who
        /// forgot the flag.
        var outputDirectory: String
        var benchmark: String = "meeting-execution-v0"
        var split: BenchmarkSplit = .development
        /// Empty means "the whole split". Non-empty overrides `split` entirely.
        var caseIDs: [String] = []
        var provider: BenchmarkProviderSelection = .offlineStub
        var policy: BenchmarkAccessPolicy = .offlineDefault
        /// Nil means "ask git". Resolving it is the caller's job, because doing so needs a process.
        var gitRevision: String?
    }

    enum ParseError: Error, Equatable, Sendable {
        case missingValue(flag: String)
        case unknownFlag(String)
        case missingRequired(flag: String)
        case unknownProvider(String)
        case unknownSplit(String)
    }

    // MARK: - Flags

    static let datasetRootFlag = "--dataset-root"
    static let outputDirectoryFlag = "--output-dir"
    static let benchmarkFlag = "--benchmark"
    static let splitFlag = "--split"
    static let caseFlag = "--case"
    static let providerFlag = "--provider"
    static let allowNetworkFlag = "--allow-network"
    static let datasetTransferFlag = "--i-accept-dataset-transfer"
    static let unlockSealedHoldoutFlag = "--unlock-sealed-holdout"
    static let gitRevisionFlag = "--git-revision"
    static let helpFlag = "--help"

    // MARK: - Parsing

    /// True when the user asked for help. Checked before `parse`, because help must work without
    /// the two required flags — `haena-benchmark --help` is the one invocation that should never
    /// be answered with "missing --dataset-root".
    static func wantsHelp(_ arguments: [String]) -> Bool {
        arguments.contains(helpFlag)
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var datasetRoot: String?
        var outputDirectory: String?
        var benchmark = "meeting-execution-v0"
        var split = BenchmarkSplit.development
        var caseIDs: [String] = []
        var provider = BenchmarkProviderSelection.offlineStub
        var policy = BenchmarkAccessPolicy.offlineDefault
        var gitRevision: String?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            index += 1

            switch flag {
            case datasetRootFlag:
                datasetRoot = try value(for: flag, from: arguments, at: &index)
            case outputDirectoryFlag:
                outputDirectory = try value(for: flag, from: arguments, at: &index)
            case benchmarkFlag:
                benchmark = try value(for: flag, from: arguments, at: &index)
            case splitFlag:
                let raw = try value(for: flag, from: arguments, at: &index)
                guard let parsed = BenchmarkSplit(rawValue: raw) else {
                    throw ParseError.unknownSplit(raw)
                }
                split = parsed
            case caseFlag:
                // Repeatable, and order-preserving: the run reports cases in the order asked for.
                caseIDs.append(try value(for: flag, from: arguments, at: &index))
            case providerFlag:
                let raw = try value(for: flag, from: arguments, at: &index)
                provider = try providerSelection(raw)
            case allowNetworkFlag:
                policy.allowNetwork = true
            case datasetTransferFlag:
                policy.datasetTransferConfirmed = true
            case unlockSealedHoldoutFlag:
                policy.unlockedSealedHoldout = true
            case gitRevisionFlag:
                gitRevision = try value(for: flag, from: arguments, at: &index)
            case helpFlag:
                // Handled by `wantsHelp` before parsing; skipped here only so that
                // `--dataset-root x --help` is not reported as an unknown flag.
                continue
            default:
                throw ParseError.unknownFlag(flag)
            }
        }

        guard let datasetRoot else {
            throw ParseError.missingRequired(flag: datasetRootFlag)
        }
        guard let outputDirectory else {
            throw ParseError.missingRequired(flag: outputDirectoryFlag)
        }

        // Naming a provider on the command line *is* the explicit allow-listing the policy's
        // `allowedProviders` set exists for. The two consequential gates — reaching a network and
        // sending corpus transcripts to a third party — stay separate flags, and stay off.
        if case .external(let identifier) = provider {
            policy.allowedProviders.insert(identifier)
        }

        return Options(
            datasetRoot: datasetRoot,
            outputDirectory: outputDirectory,
            benchmark: benchmark,
            split: split,
            caseIDs: caseIDs,
            provider: provider,
            policy: policy,
            gitRevision: gitRevision
        )
    }

    /// A value that itself looks like a flag is treated as a missing value rather than consumed:
    /// `--dataset-root --output-dir /tmp/out` should fail loudly, not quietly use "--output-dir" as
    /// a dataset path and then report that the corpus was not found.
    private static func value(for flag: String, from arguments: [String], at index: inout Int) throws -> String {
        guard index < arguments.endIndex else {
            throw ParseError.missingValue(flag: flag)
        }
        let value = arguments[index]
        guard !value.hasPrefix("--") else {
            throw ParseError.missingValue(flag: flag)
        }
        index += 1
        return value
    }

    /// Only the two providers the harness knows how to construct. An unrecognised name fails here
    /// rather than at run time, so a typo cannot silently fall back to the offline stub and produce
    /// artifacts labelled as something they are not.
    private static func providerSelection(_ raw: String) throws -> BenchmarkProviderSelection {
        switch raw {
        case BenchmarkProviderSelection.offlineStub.identifier:
            return .offlineStub
        case ModelProvider.openAI.rawValue:
            return .external(identifier: ModelProvider.openAI.rawValue)
        default:
            throw ParseError.unknownProvider(raw)
        }
    }

    // MARK: - Usage

    static let usage = """
    haena-benchmark — HAE.NA gold-independent benchmark harness

    Runs the app's real extraction seam over a benchmark corpus and writes one prediction
    artifact per case. It computes no score: the corpus has no confirmed gold yet, and a
    fabricated number would be worse than no number.

    USAGE:
      haena-benchmark --dataset-root <path> --output-dir <path> [options]

    REQUIRED:
      --dataset-root <path>       Corpus root, e.g. data/benchmarks/haena-v0/meeting-execution-v0
      --output-dir <path>         Where artifacts are written. There is no default, so predictions
                                  cannot land in a user's data directory by omission.

    OPTIONS:
      --benchmark <name>          Benchmark id recorded in every artifact.
                                  Default: meeting-execution-v0
      --split <name>              development | sealed_holdout. Default: development
      --case <ID>                 Run one case. Repeatable. Overrides --split when given.
      --provider <name>           stub | openai. Default: stub — offline, no network, no credential.
      --allow-network             Permit an external provider to open a network connection.
      --i-accept-dataset-transfer Acknowledge that an external provider run sends corpus
                                  transcripts to that provider.
      --unlock-sealed-holdout     Permit reading sealed-holdout cases. Without it a holdout case is
                                  not merely left unscored — its file is never opened.
      --git-revision <sha>        Recorded in every artifact. Defaults to the current short HEAD,
                                  or "unknown" when git cannot be reached.
      --help                      Print this message.

    OUTPUT:
      <output-dir>/<CASE-ID>.prediction.json   one artifact per case
      <output-dir>/run-report.json             counts only

    EXIT CODES:
      0  every requested case produced an artifact
      1  at least one case failed
      2  usage or configuration error
    """
}
