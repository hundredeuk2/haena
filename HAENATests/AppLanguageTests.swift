import XCTest
@testable import HAENA

@MainActor
final class AppLanguageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "com.haena.ui-language-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testAbsentSettingIsSystemWithoutWritingDefault() {
        let d = defaults()
        XCTAssertEqual(AppLanguageSettings(defaults: d).selection, .system)
        XCTAssertNil(d.object(forKey: AppLanguageSettings.storageKey))
    }
    func testKoreanSystem() { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ko"]), .ko) }
    func testEnglishSystem() { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en"]), .en) }
    func testUnsupportedFallback() { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr", "ja"]), .en) }
    func testEmptyFallback() { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .en) }
    func testExplicitOverridesSystem() {
        XCTAssertEqual(AppLanguage.en.resolved(preferredLanguages: ["ko"]), .en)
        XCTAssertEqual(AppLanguage.ko.resolved(preferredLanguages: ["en"]), .ko)
    }
    func testRegionalVariants() {
        for value in ["ko-KR", "ko_KR"] { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [value]), .ko) }
        for value in ["en-US", "en-GB", "en_US"] { XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [value]), .en) }
    }
    func testSupportedPreferenceOrder() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ko-KR", "en-US"]), .ko)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "ko-KR"]), .en)
    }
    func testInvalidSavedSelectionFallback() {
        let d = defaults(); d.set("invalid", forKey: AppLanguageSettings.storageKey)
        XCTAssertEqual(AppLanguageSettings(defaults: d).selection, .system)
    }
    func testSelectionSurvivesNewInstance() {
        let d = defaults(); AppLanguageSettings(defaults: d).select(.en)
        XCTAssertEqual(AppLanguageSettings(defaults: d).selection, .en)
    }
    func testReturnToSystemKeepsSystemNotResolvedLanguage() {
        let d = defaults(); let settings = AppLanguageSettings(defaults: d, preferredLanguages: { ["ko-KR"] })
        settings.select(.en); settings.select(.system)
        XCTAssertEqual(settings.effectiveLanguage, .ko)
        XCTAssertEqual(d.string(forKey: AppLanguageSettings.storageKey), "system")
    }
    func testResourcesInActualAppBundle() {
        XCTAssertEqual(L10n.text("앱 언어", language: .en), "App Language")
        XCTAssertEqual(L10n.text("앱 언어", language: .ko), "앱 언어")
        XCTAssertNotNil(Bundle.main.path(forResource: "en", ofType: "lproj"))
        XCTAssertNotNil(Bundle.main.path(forResource: "ko", ofType: "lproj"))
    }
}
