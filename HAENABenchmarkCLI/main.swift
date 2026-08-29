import CryptoKit
import Foundation

/// Entry point for the development-only benchmark harness.
///
/// This is the only place in the harness that touches a process, an environment, or a path. Every
/// decision it makes is delegated: what the flags mean to `BenchmarkCommandLine`, what may be read
/// to `BenchmarkAccessPolicy` and `BenchmarkCaseStore`, what a prediction *is* to `BenchmarkRunner`.
/// Keeping it that thin is what makes those rules testable without spawning this binary.
///
/// Nothing here writes an absolute path, an API key, or a transcript into an artifact: paths stay in
/// this file, and the artifacts carry only the corpus identifiers a reader needs to look a case up
/// for themselves.
enum BenchmarkCLI {
    enum ExitCode {
        static let success: Int32 = 0
        /// At least one case produced no artifact. Non-zero so a script cannot mistake a partial
        /// run for a complete one.
        static let caseFailures: Int32 = 1
        /// The run never started: bad flags, a refused policy, an unreadable corpus, or an
        /// unwritable output directory.
        static let usage: Int32 = 2
    }

    static func run(arguments: [String]) async -> Int32 {
        if arguments.isEmpty {
            print(BenchmarkCommandLine.usage)
            return ExitCode.usage
        }
        if BenchmarkCommandLine.wantsHelp(arguments) {
            print(BenchmarkCommandLine.usage)
            return ExitCode.success
        }

        let options: BenchmarkCommandLine.Options
        do {
            options = try BenchmarkCommandLine.parse(arguments)
        } catch {
            printError("인자를 해석할 수 없습니다: \(error)")
            print(BenchmarkCommandLine.usage)
            return ExitCode.usage
        }

        // Checked before a single case file is opened. An unauthorised provider must not be able to
        // see the corpus even for the moment it takes to fail later.
        do {
            try options.policy.authorizeProvider(options.provider)
        } catch {
            printError("이 실행은 요청한 provider를 사용할 수 없습니다: \(error)")
            return ExitCode.usage
        }

        let store = BenchmarkCaseStore(
            datasetRoot: URL(fileURLWithPath: options.datasetRoot, isDirectory: true),
            benchmark: options.benchmark,
            policy: options.policy
        )

        let entries: [BenchmarkSourceIndexEntry]
        do {
            entries = options.caseIDs.isEmpty
                ? try store.entries(in: options.split)
                : try store.entries(caseIDs: options.caseIDs)
        } catch let error as BenchmarkAccessError {
            // Reported separately from a lookup failure on purpose. A sealed holdout that was
            // refused and a case id that does not exist are opposite situations, and describing a
            // deliberate refusal as "not found" is how someone concludes the seal is not working.
            printError("이 실행은 요청한 case를 읽을 수 없습니다: \(error)")
            printError("봉인된 holdout은 --unlock-sealed-holdout 없이는 파일을 열지 않습니다.")
            return ExitCode.usage
        } catch {
            printError("실행할 case를 찾지 못했습니다: \(error)")
            return ExitCode.usage
        }

        // A case that cannot be prepared is reported and skipped rather than aborting the run: the
        // other cases' artifacts are still worth producing, and the failure still reaches the
        // report and the exit code.
        var preparedCases: [BenchmarkPreparedCase] = []
        var adapterFailures: [String] = []
        for entry in entries {
            do {
                preparedCases.append(try store.prepared(entry))
            } catch {
                adapterFailures.append(entry.caseID)
                printError("[\(entry.caseID)] 케이스를 준비하지 못했습니다: \(error)")
            }
        }

        let runOptions = BenchmarkRunOptions(
            benchmark: options.benchmark,
            provider: options.provider,
            modelID: modelID(for: options.provider),
            promptRevision: promptRevision(for: options.provider),
            extractionSchemaVersion: OpenAIExtractionSchema.name,
            gitRevision: options.gitRevision ?? resolvedGitRevision()
        )
        let runner = BenchmarkRunner(extractor: makeExtractor(for: options.provider))
        let (runReport, outcomes) = await runner.run(preparedCases, options: runOptions)
        let report = runReport.including(failedCaseIDs: adapterFailures)

        do {
            try write(outcomes: outcomes, report: report, toDirectory: options.outputDirectory)
        } catch {
            printError("산출물을 기록하지 못했습니다: \(error)")
            return ExitCode.usage
        }

        printSummary(report, outcomes: outcomes)
        return report.failedCount == 0 ? ExitCode.success : ExitCode.caseFailures
    }

    // MARK: - Provider wiring

    /// The offline stub is the default for a reason: a harness run must be possible — and
    /// reproducible — with no credential, no network, and no cost.
    private static func makeExtractor(for provider: BenchmarkProviderSelection) -> any WorkStateExtractor {
        switch provider {
        case .offlineStub:
            return BenchmarkStubExtractor()
        case .external:
            // The parser only ever produces the OpenAI identifier, and the policy has already
            // authorised it by this point.
            return OpenAIWorkStateExtractor()
        }
    }

    private static func modelID(for provider: BenchmarkProviderSelection) -> String {
        switch provider {
        case .offlineStub:
            return BenchmarkStubExtractor.modelID
        case .external:
            return OpenAIConfiguration.fromEnvironment().modelID
        }
    }

    /// Identifies the prompt the model was actually given.
    ///
    /// For a provider run that is a digest of the instruction text rather than a hand-maintained
    /// version string: a version someone forgets to bump is worse than no version, because it
    /// claims two different prompts were the same one.
    private static func promptRevision(for provider: BenchmarkProviderSelection) -> String {
        switch provider {
        case .offlineStub:
            return BenchmarkStubExtractor.promptRevision
        case .external:
            let digest = SHA256.hash(data: Data(OpenAIExtractionSchema.instructions.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "sha256:" + String(hex.prefix(12))
        }
    }

    // MARK: - Git revision

    /// The commit the harness code came from, so an artifact can be traced to the code that made
    /// it. `"unknown"` when git is unavailable — an unmarked artifact is better than a wrong mark.
    private static func resolvedGitRevision() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--short", "HEAD"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return "unknown"
        }

        // Read before waiting: a full pipe buffer would deadlock a process that is waiting to write
        // into it while this one waits for it to exit.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let revision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty else {
            return "unknown"
        }
        return revision
    }

    // MARK: - Output

    private static func write(
        outcomes: [BenchmarkCaseOutcome],
        report: BenchmarkRunReport,
        toDirectory directory: String
    ) throws {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // One encoder configuration for both files, so a prediction and the report that counts it
        // are formatted — and therefore diffable — the same way.
        let encoder = PredictionArtifact.encoder

        for outcome in outcomes {
            guard case .produced(let artifact) = outcome else {
                continue
            }
            let data = try encoder.encode(artifact)
            try data.write(to: root.appendingPathComponent("\(artifact.caseID).prediction.json"), options: .atomic)
        }

        let reportData = try encoder.encode(report)
        try reportData.write(to: root.appendingPathComponent("run-report.json"), options: .atomic)
    }

    /// Counts only. No accuracy, no rate, no "looks good" — there is no confirmed gold to compare
    /// against, and a summary line is exactly where an invented number would get quoted from.
    private static func printSummary(_ report: BenchmarkRunReport, outcomes: [BenchmarkCaseOutcome]) {
        print("")
        print("benchmark          : \(report.benchmark)")
        print("run mode           : \(report.runMode)")
        print("cases              : \(report.caseCount) (produced \(report.producedCount), failed \(report.failedCount))")
        print("raw proposals      : \(report.rawProposalCount)")
        print("mapped proposals   : \(report.mappedProposalCount)")
        print("rejected proposals : \(report.rejectedProposalCount)")
        print("unscored artifacts : \(report.unscoredCount)")

        for outcome in outcomes {
            if case .failed(let caseID, let failure) = outcome {
                print("failed             : \(caseID) (\(failure.rawValue))")
            }
        }

        print("")
        print("이 하네스는 점수를 계산하지 않습니다. 확정된 gold가 없기 때문입니다.")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

let benchmarkArguments = Array(CommandLine.arguments.dropFirst())
let benchmarkExitCode: Int32
if benchmarkArguments.first == "audio" {
    benchmarkExitCode = await AudioBenchmarkCLI.run(arguments: Array(benchmarkArguments.dropFirst()))
} else {
    // Existing meeting-execution invocation intentionally remains the default command.
    benchmarkExitCode = await BenchmarkCLI.run(arguments: benchmarkArguments)
}
exit(benchmarkExitCode)
