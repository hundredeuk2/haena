import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, ko, en
    var id: Self { self }

    static func stored(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .system }

    func resolved(preferredLanguages: [String]) -> Self {
        guard self == .system else { return self }
        for preferred in preferredLanguages {
            let language = preferred.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
            if language == "ko" { return .ko }
            if language == "en" { return .en }
        }
        return .en
    }
}

/// Local UI preferences only. No repository, credential, recorder or provider dependencies.
@MainActor @Observable
final class AppLanguageSettings {
    static let storageKey = "appLanguage"
    static let shared: AppLanguageSettings = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HAENA_UI_TESTING"] == "1" {
            // Reuses the existing isolated UI assembly. Never reads the user's standard settings.
            let supplied = ProcessInfo.processInfo.environment["HAENA_UI_TEST_LANGUAGE_SUITE"]
            let suite = supplied.flatMap { $0.hasPrefix("com.haena.ui-language-test.") ? $0 : nil }
                ?? "com.haena.ui-language-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            if let initial = ProcessInfo.processInfo.environment["HAENA_UI_TEST_LANGUAGE"] {
                defaults.set(AppLanguage.stored(initial).rawValue, forKey: storageKey)
            }
            return AppLanguageSettings(defaults: defaults)
        }
        #endif
        return AppLanguageSettings(defaults: .standard)
    }()

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private(set) var selection: AppLanguage

    init(defaults: UserDefaults, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        selection = AppLanguage.stored(defaults.string(forKey: Self.storageKey))
    }

    var effectiveLanguage: AppLanguage { selection.resolved(preferredLanguages: preferredLanguages()) }
    /// Language is independent from region and timezone. Never changes a stored Date.
    var locale: Locale {
        Locale(identifier: effectiveLanguage.rawValue + "_" + (Locale.current.region?.identifier ?? "US"))
    }

    func select(_ language: AppLanguage) {
        guard language != selection else { return }
        selection = language
        defaults.set(language.rawValue, forKey: Self.storageKey)
    }
}

/// Only app-authored copy enters this API. User titles/transcripts/names remain verbatim.
@MainActor
enum L10n {
    static func text(_ key: String) -> String {
        text(key, language: AppLanguageSettings.shared.effectiveLanguage)
    }

    static func text(_ key: String, language: AppLanguage, bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: String...) -> String {
        String(format: text(key), locale: AppLanguageSettings.shared.locale, arguments: arguments)
    }
}
