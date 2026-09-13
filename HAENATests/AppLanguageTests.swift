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

    func testCatalogKeysAndPlaceholdersAgree() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        }
        let ko = try catalog("ko"), en = try catalog("en")
        XCTAssertGreaterThan(en.count, 400)
        XCTAssertEqual(Set(ko.keys), Set(en.keys))
        for key in ko.keys {
            let english = try XCTUnwrap(en[key])
            XCTAssertFalse(english.isEmpty, key)
            XCTAssertEqual(key.components(separatedBy: "%@").count, english.components(separatedBy: "%@").count, key)
        }
    }

    func testDynamicCountsAndUserNameStayVerbatim() {
        for language in [AppLanguage.ko, .en] {
            let format = L10n.text("회의 %@개", language: language)
            for count in [0, 1, 17] {
                let result = String(format: format, String(count))
                XCTAssertTrue(result.contains(String(count)))
                XCTAssertFalse(result.contains("%@"))
            }
            let result = String(format: L10n.text("담당 %@", language: language), "저장")
            XCTAssertTrue(result.contains("저장"), "A user's name must not become a localization key")
        }
    }

    func testLanguageChangeLeavesSyntheticDomainBytesAndDeadlineUnchanged() throws {
        let seed = ManualContinuityBriefUITestSeed.make()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(seed.project)
        let deadlines = seed.project.actionItems.map(\.dueDate)
        let statuses = seed.project.actionItems.map(\.status)
        let settings = AppLanguageSettings(defaults: defaults(), preferredLanguages: { ["ko-KR"] })
        for selection in [AppLanguage.en, .ko, .system] {
            settings.select(selection)
            _ = L10n.text("승인", language: settings.effectiveLanguage)
            XCTAssertEqual(try encoder.encode(seed.project), before)
            XCTAssertEqual(seed.project.actionItems.map(\.dueDate), deadlines)
            XCTAssertEqual(seed.project.actionItems.map(\.status), statuses)
        }
    }
}
