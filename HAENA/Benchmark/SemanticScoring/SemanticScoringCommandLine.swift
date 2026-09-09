import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Pure parser for the explicit `haena-benchmark score` command.
///
/// It reads no file, environment variable, process, credential, or network resource. Selection is
/// intentionally explicit: a scoring run must name cases or opt into every development case.
struct SemanticScoringCommandLine: Equatable, Sendable {
    enum Selection: Equatable, Sendable {
        case caseIDs([String])
        case allDevelopment
    }

    struct Options: Equatable, Sendable {
        let scorerRoot: String
        let predictionDirectory: String
        let matchingMapDirectory: String
        let observationDirectory: String
        let outputFile: String
        let benchmark: String
        let split: BenchmarkSplit
        let selection: Selection
        let developmentScoringAuthorized: Bool
    }

    enum ParseError: Error, Equatable, Sendable {
        case missingValue(flag: String)
        case missingRequired(flag: String)
        case duplicateFlag(String)
        case unknownFlag(String)
        case unknownSplit(String)
        case missingCaseSelection
        case conflictingCaseSelection
        case duplicateCaseID
    }

    static let scorerRootFlag = "--scorer-root"
    static let predictionDirectoryFlag = "--prediction-dir"
    static let matchingMapDirectoryFlag = "--matching-map-dir"
    static let observationDirectoryFlag = "--observation-dir"
    static let outputFileFlag = "--output-file"
    static let benchmarkFlag = "--benchmark"
    static let splitFlag = "--split"
    static let caseFlag = "--case"
    static let allDevelopmentFlag = "--all-development"
    static let authorizeDevelopmentFlag = "--authorize-development-scoring"
    static let helpFlag = "--help"

    static func wantsHelp(_ arguments: [String]) -> Bool {
        arguments.contains(helpFlag)
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var scorerRoot: String?
        var predictionDirectory: String?
        var matchingMapDirectory: String?
        var observationDirectory: String?
        var outputFile: String?
        var benchmark: String?
        var split = BenchmarkSplit.development
        var splitWasSet = false
        var caseIDs: [String] = []
        var allDevelopment = false
        var developmentScoringAuthorized = false

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            index += 1
            switch flag {
            case scorerRootFlag:
                try setOnce(
                    &scorerRoot,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case predictionDirectoryFlag:
                try setOnce(
                    &predictionDirectory,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case matchingMapDirectoryFlag:
                try setOnce(
                    &matchingMapDirectory,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case observationDirectoryFlag:
                try setOnce(
                    &observationDirectory,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case outputFileFlag:
                try setOnce(
                    &outputFile,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case benchmarkFlag:
                try setOnce(
                    &benchmark,
                    value: try value(for: flag, from: arguments, at: &index),
                    flag: flag
                )
            case splitFlag:
                guard !splitWasSet else { throw ParseError.duplicateFlag(flag) }
                let raw = try value(for: flag, from: arguments, at: &index)
                guard let parsed = BenchmarkSplit(rawValue: raw) else {
                    throw ParseError.unknownSplit(raw)
                }
                split = parsed
                splitWasSet = true
            case caseFlag:
                caseIDs.append(try value(for: flag, from: arguments, at: &index))
            case allDevelopmentFlag:
                guard !allDevelopment else { throw ParseError.duplicateFlag(flag) }
                allDevelopment = true
            case authorizeDevelopmentFlag:
                guard !developmentScoringAuthorized else {
                    throw ParseError.duplicateFlag(flag)
                }
                developmentScoringAuthorized = true
            case helpFlag:
                continue
            default:
                throw ParseError.unknownFlag(flag)
            }
        }

        guard let scorerRoot else { throw ParseError.missingRequired(flag: scorerRootFlag) }
        guard let predictionDirectory else {
            throw ParseError.missingRequired(flag: predictionDirectoryFlag)
        }
        guard let matchingMapDirectory else {
            throw ParseError.missingRequired(flag: matchingMapDirectoryFlag)
        }
        guard let observationDirectory else {
            throw ParseError.missingRequired(flag: observationDirectoryFlag)
        }
        guard let outputFile else { throw ParseError.missingRequired(flag: outputFileFlag) }
        guard let benchmark else { throw ParseError.missingRequired(flag: benchmarkFlag) }
        guard developmentScoringAuthorized else {
            throw ParseError.missingRequired(flag: authorizeDevelopmentFlag)
        }
        guard !caseIDs.isEmpty || allDevelopment else {
            throw ParseError.missingCaseSelection
        }
        guard caseIDs.isEmpty || !allDevelopment else {
            throw ParseError.conflictingCaseSelection
        }
        guard Set(caseIDs).count == caseIDs.count else {
            throw ParseError.duplicateCaseID
        }

        return Options(
            scorerRoot: scorerRoot,
            predictionDirectory: predictionDirectory,
            matchingMapDirectory: matchingMapDirectory,
            observationDirectory: observationDirectory,
            outputFile: outputFile,
            benchmark: benchmark,
            split: split,
            selection: allDevelopment ? .allDevelopment : .caseIDs(caseIDs),
            developmentScoringAuthorized: developmentScoringAuthorized
        )
    }

    private static func value(
        for flag: String,
        from arguments: [String],
        at index: inout Int
    ) throws -> String {
        guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else {
            throw ParseError.missingValue(flag: flag)
        }
        defer { index += 1 }
        return arguments[index]
    }

    private static func setOnce(
        _ destination: inout String?,
        value: String,
        flag: String
    ) throws {
        guard destination == nil else { throw ParseError.duplicateFlag(flag) }
        destination = value
    }

    static let usage = """
    haena-benchmark score — explicit fail-closed semantic scoring

    USAGE:
      haena-benchmark score --scorer-root <path> --prediction-dir <path>
        --matching-map-dir <path> --observation-dir <path> --output-file <path>
        --benchmark <id> (--case <ID>... | --all-development)
        --authorize-development-scoring

    REQUIRED:
      --scorer-root <path>            Metadata index and authorized gold payload root
      --prediction-dir <path>         prediction-v0.2 artifact directory
      --matching-map-dir <path>       Versioned exact matching-map directory
      --observation-dir <path>        Typed metric-observation directory
      --output-file <path>            New regression report file; never overwritten
      --benchmark <id>                Exact benchmark identity
      --case <ID>                     Explicit case; repeatable
      --all-development               Explicitly select every development case
      --authorize-development-scoring Required runtime authorization; never persisted

    OPTIONS:
      --split development|sealed_holdout  Default: development. sealed_holdout is refused.
      --help                              Print this message without reading any file.

    INPUT FILES:
      <prediction-dir>/<CASE-ID>.prediction.json
      <matching-map-dir>/<CASE-ID>.matching-map.json
      <observation-dir>/<CASE-ID>.observations.json

    The command never runs a model or provider and never opens a network connection.
    """
}
