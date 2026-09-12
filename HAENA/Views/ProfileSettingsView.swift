import SwiftUI

/// Where the user says who they are and which meeting participants are them.
///
/// Not an account screen and not onboarding: it is reachable, skippable, and everything else in the
/// app works without it. Nothing here creates people — it only lets the user point at participants
/// that already exist in their meetings.
struct ProfileSettingsView: View {
    let service: LocalUserProfileService
    /// Called after any change, so the home can pick up the new profile.
    var onChanged: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var profile: LocalUserProfile?
    @State private var entries: [ParticipantDirectoryEntry] = []
    @State private var selection: Set<UUID> = []
    @State private var message: String?
    @State private var isError = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("내 프로필"))
                .font(.title2)
                .bold()

            Text(L10n.text("이 Mac에서 앱을 쓰는 사람을 설정합니다. 계정이나 로그인이 아니며, 입력한 내용은 이 기기에만 저장됩니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            nameField

            Divider()

            participantSection

            if let message {
                Text(L10n.text(message))
                    .font(.callout)
                    .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("profile-feedback-message")
            }

            HStack {
                Spacer()
                Button(L10n.text("닫기")) {
                    dismiss()
                }
                .accessibilityIdentifier("close-profile-button")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-settings-screen")
        .task {
            await load()
        }
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("이름"))
                .font(.headline)

            HStack {
                TextField(L10n.text("이름을 입력하세요"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("profile-name-field")

                Button(profile == nil ? L10n.text("저장") : L10n.text("이름 수정")) {
                    Task { await saveName() }
                }
                .accessibilityIdentifier("save-profile-name-button")
                .disabled(LocalUserProfile.validatedName(name) == nil)
            }
        }
    }

    // MARK: - Participants

    @ViewBuilder
    private var participantSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("나와 연결된 참석자"))
                .font(.headline)

            Text(L10n.text("회의마다 참석자가 따로 기록되므로, 같은 사람이 여러 번 나타납니다. 본인에 해당하는 항목을 모두 선택해 연결하세요. 이름이 같다는 이유로 자동 연결되지는 않습니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if profile == nil {
                Text(L10n.text("먼저 이름을 저장하면 참석자를 연결할 수 있습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile-name-required-notice")
            } else if entries.isEmpty {
                Text(L10n.text("아직 저장된 참석자가 없습니다. 회의를 먼저 기록해주세요."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("participant-directory-empty")
            } else {
                participantList

                Button(L10n.text("선택한 참석자를 나로 연결")) {
                    Task { await linkSelected() }
                }
                .accessibilityIdentifier("link-selected-participants-button")
                .disabled(selection.isEmpty)
            }
        }
    }

    private var participantList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        if entry.isLinkedToMe {
                            // Already answered, so it is stated rather than offered again.
                            Text(L10n.text("나"))
                                .font(.caption)
                                .bold()
                                .accessibilityIdentifier("linked-badge-\(entry.participantID.uuidString)")
                        } else {
                            Toggle(isOn: binding(for: entry.participantID)) {
                                EmptyView()
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("select-participant-\(entry.participantID.uuidString)")
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                            // Provenance, because two different people can share a name and the
                            // user has no other way to tell these rows apart.
                            Text("\(entry.projectName) · \(entry.meetingTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        if entry.isLinkedToMe {
                            Button(L10n.text("연결 해제")) {
                                Task { await unlink(entry.participantID) }
                            }
                            .accessibilityIdentifier("unlink-participant-\(entry.participantID.uuidString)")
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("participant-row-\(entry.participantID.uuidString)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 160)
        .accessibilityIdentifier("participant-directory")
    }

    private func binding(for participantID: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(participantID) },
            set: { isSelected in
                if isSelected {
                    selection.insert(participantID)
                } else {
                    selection.remove(participantID)
                }
            }
        )
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        do {
            profile = try await service.profile()
            name = profile?.displayName ?? ""
            entries = try await service.directory()
        } catch {
            show("프로필을 불러오지 못했습니다.", isError: true)
        }
        isLoading = false
    }

    private func saveName() async {
        do {
            _ = try await service.setDisplayName(name)
            await reload()
            show("저장됨", isError: false)
        } catch LocalUserProfileError.nameMissing {
            show("이름을 입력해주세요.", isError: true)
        } catch {
            show("이름을 저장하지 못했습니다.", isError: true)
        }
    }

    private func linkSelected() async {
        do {
            _ = try await service.link(participantIDs: Array(selection))
            selection.removeAll()
            await reload()
            show("연결했습니다.", isError: false)
        } catch LocalUserProfileError.unknownParticipant {
            show("선택한 참석자를 찾을 수 없습니다. 목록을 다시 확인해주세요.", isError: true)
        } catch {
            show("연결하지 못했습니다.", isError: true)
        }
    }

    private func unlink(_ participantID: UUID) async {
        do {
            _ = try await service.unlink(participantID: participantID)
            await reload()
            show("연결을 해제했습니다.", isError: false)
        } catch {
            show("연결을 해제하지 못했습니다.", isError: true)
        }
    }

    private func reload() async {
        profile = try? await service.profile()
        entries = (try? await service.directory()) ?? entries
        await onChanged?()
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }
}
