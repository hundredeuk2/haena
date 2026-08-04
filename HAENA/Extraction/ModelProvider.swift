import Foundation

/// Identifies which model backend produced an extraction result.
///
/// A `String`-backed value type rather than a closed `enum`: adding a provider (another
/// commercial API, a locally hosted model, an SKT model) must not require editing this file or
/// updating exhaustive switches across the domain layer.
struct ModelProvider: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ModelProvider {
    static let openAI = ModelProvider(rawValue: "openai")

    /// In-process extractor used by tests and UI-test launches. Never selected as a production
    /// fallback when a real provider fails — the assembly point in `HAENAApp` chooses exactly one.
    static let deterministic = ModelProvider(rawValue: "deterministic")
}

/// Which model actually produced a result, recorded alongside every extraction run so a stored
/// proposal can later be traced back to the provider and model version that suggested it.
struct ModelRunMetadata: Codable, Equatable, Sendable {
    let provider: ModelProvider
    let modelID: String
    let completedAt: Date
}
