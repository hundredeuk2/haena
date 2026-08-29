import Foundation

enum OpenAILiveTestKind: Equatable {
    case workStateExtraction
    case transcription
}

enum OpenAILiveTestGateDecision: Equatable {
    case disabled
    case missingCredential
    case missingAudioPath
    case allowed
}

/// Pure policy for live OpenAI tests. It never reads credentials, files, or audio paths.
/// Callers must check `isExplicitlyEnabled` before resolving any of those inputs.
struct OpenAILiveTestGate {
    static let optInEnvironmentKey = "HAENA_RUN_LIVE_OPENAI_TESTS"

    static func isExplicitlyEnabled(environment: [String: String]) -> Bool {
        environment[optInEnvironmentKey] == "1"
    }

    static func evaluate(
        environment: [String: String],
        kind: OpenAILiveTestKind,
        hasCredential: Bool,
        hasAudioPath: Bool = false
    ) -> OpenAILiveTestGateDecision {
        guard isExplicitlyEnabled(environment: environment) else {
            return .disabled
        }
        guard hasCredential else {
            return .missingCredential
        }
        if kind == .transcription, !hasAudioPath {
            return .missingAudioPath
        }
        return .allowed
    }
}
