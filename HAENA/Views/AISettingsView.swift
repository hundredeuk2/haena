import SwiftUI

/// Where the user supplies their own OpenAI API key.
///
/// Phase 0 is a Developer Preview distributed as a DMG, so the app ships with no key of its own and
/// asks the user to bring theirs. That is a deliberate boundary, not a shortcut: shipping a shared
/// developer key would put every install on one bill and one rate limit, and adding a backend to
/// hold keys would mean accounts, which this product does not have.
///
/// The key is written to the Keychain and never read back into this screen. Once saved, the only
/// thing shown is that it is set.
struct AISettingsView: View {
    let resolver: OpenAICredentialResolver
    let verifier: any OpenAICredentialVerifying
    var onChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var typedKey = ""
    @State private var status: CredentialStatus = .notConfigured
    @State private var message: String?
    @State private var isError = false
    @State private var isVerifying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI 설정")
                    .font(.title2)
                    .bold()

                statusRow
                keyEntry
                Divider()
                guidance

                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-settings-message")
                }

                HStack {
                    Spacer()
                    Button("닫기") {
                        dismiss()
                    }
                    .accessibilityIdentifier("close-ai-settings-button")
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 540, minHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-settings-screen")
        .task {
            refreshStatus()
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 8) {
            Text("OpenAI")
                .font(.headline)
            Text(statusText)
                .font(.callout)
                .foregroundStyle(status.isConfigured ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .accessibilityIdentifier("openai-credential-status")
        }
    }

    /// States the situation and, when relevant, which source is winning — never any part of the key
    /// itself, masked or otherwise.
    private var statusText: String {
        switch status {
        case .notConfigured:
            return "미설정"
        case .configured(.keychain):
            return "설정됨 (이 Mac의 키체인)"
        case .configured(.environment):
            return "설정됨 (환경변수 OPENAI_API_KEY — 저장된 키보다 우선합니다)"
        case .unavailable:
            return "키체인을 읽지 못했습니다"
        }
    }

    // MARK: - Entry

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API 키")
                .font(.headline)

            SecureField("sk-…", text: $typedKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("openai-api-key-field")

            Text("입력한 키는 이 Mac의 키체인에만 저장되며, 저장한 뒤에는 화면에 다시 표시되지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(status.isConfigured ? "키 교체" : "저장") {
                    save()
                }
                .accessibilityIdentifier("save-openai-key-button")
                .disabled(CredentialNormalisation.normalised(typedKey) == nil)

                Button("연결 확인") {
                    Task { await verify() }
                }
                .accessibilityIdentifier("verify-openai-key-button")
                .disabled(isVerifying || CredentialNormalisation.normalised(typedKey) == nil)

                if isVerifying {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer(minLength: 0)

                Button("삭제", role: .destructive) {
                    deleteKey()
                }
                .accessibilityIdentifier("delete-openai-key-button")
                .disabled(status != .configured(.keychain))
            }

            Text("연결 확인은 모델을 실행하지 않는 목록 조회로 인증만 검사하므로 사용료가 발생하지 않습니다. 확인은 입력한 키만 검사하며, 이미 저장된 키를 바꾸거나 지우지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Guidance

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("알아두실 점")
                .font(.headline)

            ForEach(Self.guidanceLines, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ai-settings-guidance")
    }

    static let guidanceLines = [
        "이 버전은 Phase 0 Developer Preview이며, 사용자가 자신의 OpenAI API 키를 직접 넣는 방식(BYOK)입니다.",
        "API 사용료는 입력한 키의 OpenAI 계정에서 발생합니다. ChatGPT 구독료와 API 사용료는 서로 별개입니다.",
        "본인 계정의 키만 사용하세요. 다른 사람의 키를 입력하면 그 사람에게 요금이 청구됩니다.",
        "권한을 제한한 Project API 키를 만들고 OpenAI에서 사용 한도를 설정해두시길 권합니다.",
        "전사와 AI 추출을 실행하면 회의 오디오와 전사 내용이 OpenAI로 전송됩니다.",
        "키를 삭제해도 이미 저장된 프로젝트·녹음·전사는 지워지지 않습니다. 새 전사와 추출만 중단됩니다."
    ]

    // MARK: - Actions

    private func refreshStatus() {
        status = resolver.status()
    }

    private func save() {
        do {
            try resolver.save(typedKey)
            // Cleared immediately: nothing that holds the key should outlive the save, and an
            // untouched field would read as the stored value being shown back.
            typedKey = ""
            refreshStatus()
            onChanged?()
            show("저장했습니다.", isError: false)
        } catch CredentialStoreError.blankCredential {
            show("키를 입력해주세요.", isError: true)
        } catch CredentialStoreError.accessDenied {
            show("키체인 접근이 거부되었습니다. 다시 시도하면 시스템이 다시 물어봅니다.", isError: true)
        } catch {
            show("키체인에 저장하지 못했습니다.", isError: true)
        }
    }

    private func deleteKey() {
        do {
            try resolver.delete()
            typedKey = ""
            refreshStatus()
            onChanged?()
            show("삭제했습니다. 저장된 프로젝트와 녹음은 그대로 있습니다.", isError: false)
        } catch CredentialStoreError.accessDenied {
            show("키체인 접근이 거부되었습니다.", isError: true)
        } catch {
            show("키체인에서 삭제하지 못했습니다.", isError: true)
        }
    }

    /// Checks the key in the field. Never writes — a failed check must not be able to disturb a
    /// working key the user already saved.
    private func verify() async {
        guard let candidate = CredentialNormalisation.normalised(typedKey) else {
            show("키를 입력해주세요.", isError: true)
            return
        }
        isVerifying = true
        let result = await verifier.verify(candidate)
        isVerifying = false

        switch result {
        case .valid:
            show("이 키로 인증에 성공했습니다. 아직 저장되지는 않았습니다 — 저장하려면 저장을 눌러주세요.", isError: false)
        case .unauthorized:
            show("키가 올바르지 않거나 만료되었습니다. (401)", isError: true)
        case .forbidden:
            show("이 키에는 권한이 없습니다. Project 키의 권한 설정을 확인해주세요. (403)", isError: true)
        case .rateLimitedOrBillingIssue:
            show("요청이 제한되었습니다. 사용 한도나 결제 상태를 확인해주세요. (429)", isError: true)
        case .networkUnavailable:
            show("네트워크에 연결하지 못했습니다. 저장된 키는 그대로입니다.", isError: true)
        case .unexpected(let status):
            show("확인하지 못했습니다. (HTTP \(status))", isError: true)
        }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}
