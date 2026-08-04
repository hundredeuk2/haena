import Foundation

/// Everything the OpenAI adapter needs except the credential, which is fetched separately and
/// never stored in a value that could be logged or encoded.
///
/// The default model ID lives here and nowhere else: domain code must not name a model, and
/// changing the default must be a one-line edit in one file.
struct OpenAIConfiguration: Equatable, Sendable {
    /// The single source of truth for which model HAE.NA asks for by default.
    static let defaultModelID = "gpt-5.6"
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!

    static let modelEnvironmentKey = "OPENAI_MODEL"
    static let apiKeyEnvironmentKey = "OPENAI_API_KEY"

    var endpoint: URL
    var modelID: String
    var requestTimeout: TimeInterval
    /// Retries *after* the first attempt. Bounded on purpose — a provider outage must surface as
    /// an error the user sees, not as an app that hangs retrying forever.
    var maxRetries: Int
    var retryDelay: TimeInterval

    init(
        endpoint: URL = OpenAIConfiguration.defaultEndpoint,
        modelID: String = OpenAIConfiguration.defaultModelID,
        requestTimeout: TimeInterval = 60,
        maxRetries: Int = 2,
        retryDelay: TimeInterval = 1
    ) {
        self.endpoint = endpoint
        self.modelID = modelID
        self.requestTimeout = requestTimeout
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }

    /// `OPENAI_MODEL` overrides the default model when set; everything else keeps its default.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OpenAIConfiguration {
        var configuration = OpenAIConfiguration()
        if let model = environment[modelEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            configuration.modelID = model
        }
        return configuration
    }

    /// Reads the development-stage credential from the process environment.
    ///
    /// Deliberately the *only* credential source in the app: no key is compiled in, written to a
    /// plist or xcconfig, cached in UserDefaults, or requested through a settings screen. Absent
    /// or blank yields nil, which the extractor turns into `.missingCredential` — never a crash,
    /// and never a request sent without authorization.
    static func apiKey(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let key = environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }
}
