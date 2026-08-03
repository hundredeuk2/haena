import Foundation

/// How certain an AI-derived result is, normalized to the closed interval [0, 1].
///
/// Values are clamped rather than rejected: confidence is an advisory signal from a model,
/// not a value whose validity gates correctness, so a soft clamp keeps every call site simple
/// instead of forcing failure handling for a harmless out-of-range or floating-point-drifted score.
struct Confidence: Codable, Equatable, Sendable {
    let value: Double

    init(_ value: Double) {
        self.value = min(max(value, 0.0), 1.0)
    }

    static let minimum = Confidence(0.0)
    static let maximum = Confidence(1.0)
}
