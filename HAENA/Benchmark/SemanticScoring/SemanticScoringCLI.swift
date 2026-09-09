import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Explicit semantic-scoring entry point. It has no provider/model dependency and performs no
/// asynchronous work: every input is an already-produced local, versioned artifact.
enum SemanticScoringCLI {
    enum ExitCode {
        static let success: Int32 = 0
        static let usage: Int32 = 2
    }

    static func run(
        arguments: [String],
        fileManager: FileManager = .default,
        reportPolicy: SemanticScoringReportPolicy = .current
    ) -> Int32 {
        if SemanticScoringCommandLine.wantsHelp(arguments) {
            print(SemanticScoringCommandLine.usage)
            return ExitCode.success
        }

        let options: SemanticScoringCommandLine.Options
        do {
            options = try SemanticScoringCommandLine.parse(arguments)
        } catch {
            printError("semantic scoring refused: invalid_arguments")
            print(SemanticScoringCommandLine.usage)
            return ExitCode.usage
        }

        do {
            let report = try execute(
                options: options,
                fileManager: fileManager,
                reportPolicy: reportPolicy
            )
            print("semantic scoring cases: \(report.aggregate.caseCount)")
            return ExitCode.success
        } catch let refusal as SemanticScoringCLIRefusal {
            printError("semantic scoring refused: \(refusal.code)")
            return ExitCode.usage
        } catch {
            printError("semantic scoring refused: internal_failure")
            return ExitCode.usage
        }
    }

    /// The testable execution seam. All global state is explicit, and the only write is delegated
    /// to `SemanticScoringArtifactStore` after every selected case has become an authorized metric
    /// scoring capability and the report has reconciled successfully.
    @discardableResult
    static func execute(
        options: SemanticScoringCommandLine.Options,
        fileManager: FileManager = .default,
        reportPolicy: SemanticScoringReportPolicy = .current
    ) throws -> SemanticRegressionReport {
        guard options.developmentScoringAuthorized else {
            throw SemanticScoringCLIRefusal.authorizationMissing
        }
        guard options.split == .development else {
            throw SemanticScoringCLIRefusal.sealedSplit
        }
        guard reportPolicy.schemaVersion == SemanticRegressionReport.schemaVersion else {
            throw SemanticScoringCLIRefusal.unknownReportPolicyVersion
        }

        let store = SemanticScoringArtifactStore(options: options, fileManager: fileManager)
        try store.validateOutputBoundary()
        let caseIDs = try store.selectedCaseIDs(options.selection, benchmark: options.benchmark)

        var authorizedCases: [AuthorizedSemanticMetricScoringCase] = []
        authorizedCases.reserveCapacity(caseIDs.count)
        for caseID in caseIDs {
            authorizedCases.append(
                try store.loadCase(
                    caseID: caseID,
                    benchmark: options.benchmark,
                    runtimeAuthorization: .development()
                )
            )
        }

        let report: SemanticRegressionReport
        do {
            report = try SemanticRegressionReportBuilder.build(from: authorizedCases)
        } catch {
            throw SemanticScoringCLIRefusal.reportConstructionFailed
        }
        try store.write(report)
        return report
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
