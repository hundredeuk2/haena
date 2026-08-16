import Foundation

#if BENCHMARK_TEST_TARGET
@testable import HAENA
#endif

/// Pure parser for the development-only `haena-benchmark audio` command.
///
/// Audio has a separate source root because the ignored benchmark definition contains only a
/// relative pointer to the original local corpus. There is intentionally no inferred default: an
/// inference could point a run at unrelated user audio.
struct AudioBenchmarkCommandLine: Sendable {
    enum Provider: String, Equatable, Sendable {
        case offlineFake = "fake"
        case openAI = "openai"
    }

    struct Options: Equatable, Sendable {
        let datasetRoot: String
        let sourceRoot: String
        let outputDirectory: String
        let selection: AudioBenchmarkSelection
        let provider: Provider
    }

    enum ParseError: Error, Equatable, Sendable {
        case missingValue
        case missingRequired
        case unknownFlag
        case unknownSplit
        case unknownProvider
    }

    static let helpFlag = "--help"

    static func wantsHelp(_ arguments: [String]) -> Bool {
        arguments.contains(helpFlag)
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var datasetRoot: String?
        var sourceRoot: String?
        var outputDirectory: String?
        var split = AudioBenchmarkSplit.development
        var caseIDs: [String] = []
        var provider = Provider.offlineFake

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            index += 1
            switch flag {
            case "--dataset-root":
                datasetRoot = try value(arguments, at: &index)
            case "--source-root":
                sourceRoot = try value(arguments, at: &index)
            case "--output-dir":
                outputDirectory = try value(arguments, at: &index)
            case "--split":
                guard let parsed = AudioBenchmarkSplit(rawValue: try value(arguments, at: &index)) else {
                    throw ParseError.unknownSplit
                }
                split = parsed
            case "--case":
                caseIDs.append(try value(arguments, at: &index))
            case "--provider":
                guard let parsed = Provider(rawValue: try value(arguments, at: &index)) else {
                    throw ParseError.unknownProvider
                }
                provider = parsed
            case helpFlag:
                continue
            default:
                throw ParseError.unknownFlag
            }
        }

        guard let datasetRoot, let sourceRoot, let outputDirectory else {
            throw ParseError.missingRequired
        }
        let selection: AudioBenchmarkSelection = if caseIDs.isEmpty {
            split == .development ? .development : .sealedHoldout
        } else {
            .caseIDs(caseIDs)
        }
        return Options(
            datasetRoot: datasetRoot,
            sourceRoot: sourceRoot,
            outputDirectory: outputDirectory,
            selection: selection,
            provider: provider
        )
    }

    private static func value(_ arguments: [String], at index: inout Int) throws -> String {
        guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else {
            throw ParseError.missingValue
        }
        defer { index += 1 }
        return arguments[index]
    }

    static let usage = """
    haena-benchmark audio — offline Audio/STT Benchmark Runner & Scorer v0

    USAGE:
      haena-benchmark audio --dataset-root <path> --source-root <path> --output-dir <path> [options]

    REQUIRED:
      --dataset-root <path>  audio-robustness-v0 directory containing source-index.jsonl
      --source-root <path>   local root used to resolve authorized development WAV paths
      --output-dir <path>    transcript-free reports; there is no default

    OPTIONS:
      --split development|sealed_holdout   default: development
      --case <ID>                          one development case; repeatable
      --provider fake|openai               default: fake; openai is implemented but execution is
                                           disabled pending separate operator approval
      --help

    The fake provider validates the pipeline only. Its metrics are not STT quality measurements.
    """
}
