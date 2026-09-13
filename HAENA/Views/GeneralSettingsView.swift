import SwiftUI

struct GeneralSettingsView: View {
    private var settings: AppLanguageSettings { .shared }

    var body: some View {
        Form {
            Section(L10n.text("일반")) {
                Picker(L10n.text("앱 언어"), selection: Binding(
                    get: { settings.selection }, set: { settings.select($0) }
                )) {
                    Text(L10n.text("시스템 설정 사용")).tag(AppLanguage.system)
                    Text(verbatim: "한국어").tag(AppLanguage.ko)
                    Text(verbatim: "English").tag(AppLanguage.en)
                }
                .accessibilityIdentifier("app-language-picker")
                Text(L10n.text("앱의 표시 언어만 바뀝니다. 회의 원문과 분석 결과는 번역하지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.format("현재 표시 언어: %@", settings.effectiveLanguage == .ko ? "한국어" : "English"))
                    .accessibilityIdentifier("effective-app-language")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 240)
        .navigationTitle(L10n.text("설정"))
        .accessibilityIdentifier("general-settings-screen")
    }
}
