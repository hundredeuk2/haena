import SwiftUI

/// Lets the user say who each diarized voice belongs to, after the meeting is already saved.
///
/// Nothing here is required. Every voice may be left unconfirmed, the screen can be closed at any
/// point, and closing it loses nothing — the meeting, its transcript, and its extracted work state
/// are already persisted before this screen can even be opened.
struct SpeakerConfirmationView: View {
    let projectID: UUID
    let meetingID: UUID
    let service: SpeakerConfirmationService
    /// Called after every successful change so the caller can reload from the repository.
    let onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var overview: SpeakerConfirmationOverview?
    @State private var newNames: [UUID: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("화자 확인"))
                .font(.title2)
                .bold()

            Text(L10n.text("목소리마다 누구인지 알려주면 이 회의 전체에 반영됩니다. 모르는 화자는 그대로 두어도 됩니다."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(L10n.text(errorMessage))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("speaker-confirmation-error-message")
            }

            if let overview {
                if overview.unconfirmed.isEmpty {
                    Text(L10n.text("확인되지 않은 화자가 없습니다."))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("speaker-confirmation-empty")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(overview.unconfirmed) { speaker in
                                speakerSection(speaker, candidates: overview.candidates)
                                Divider()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView()
                    .accessibilityIdentifier("speaker-confirmation-loading")
            }

            HStack {
                Spacer()
                // "Later" and "close" are the same action on purpose: leaving is always allowed
                // and never destructive.
                Button(L10n.text("나중에")) {
                    dismiss()
                }
                .accessibilityIdentifier("speaker-confirmation-later-button")
                .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .task {
            await reload()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func speakerSection(
        _ speaker: UnconfirmedSpeaker,
        candidates: [SpeakerCandidate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(speaker.displayName)
                    .font(.headline)
                Text(L10n.format("발언 %@개", String(describing: speaker.utteranceCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("speaker-heading-\(speaker.id.uuidString)")

            ForEach(Array(speaker.representativeUtterances.enumerated()), id: \.offset) { _, utterance in
                HStack(alignment: .top, spacing: 8) {
                    if let timestamp = TranscriptTimestampFormatter.string(from: utterance.startTime) {
                        Text(timestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(utterance.text)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            if !candidates.isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.text("기존 참석자"))
                        .font(.caption)
                    ForEach(candidates) { candidate in
                        Button(candidate.displayName) {
                            link(speaker: speaker, to: candidate)
                        }
                        .disabled(isSaving)
                    }
                }
                .accessibilityIdentifier("speaker-candidates-\(speaker.id.uuidString)")
            }

            HStack(spacing: 8) {
                TextField(
                    L10n.text("새 참석자 이름"),
                    text: Binding(
                        get: { newNames[speaker.id] ?? "" },
                        set: { newNames[speaker.id] = $0 }
                    )
                )
                .accessibilityIdentifier("speaker-new-name-field-\(speaker.id.uuidString)")

                Button(L10n.text("연결")) {
                    linkToNewName(speaker: speaker)
                }
                .accessibilityIdentifier("speaker-link-new-button-\(speaker.id.uuidString)")
                .disabled(isSaving)
            }
        }
    }

    // MARK: - Actions

    private func link(speaker: UnconfirmedSpeaker, to candidate: SpeakerCandidate) {
        perform {
            if let participantID = candidate.existingParticipantID {
                _ = try await service.link(
                    speakerID: speaker.id,
                    toExistingParticipant: participantID,
                    meetingID: meetingID,
                    projectID: projectID
                )
            } else {
                // A name known only from another meeting becomes this meeting's own participant,
                // rather than an identity shared across meetings.
                _ = try await service.link(
                    speakerID: speaker.id,
                    toNewParticipantNamed: candidate.displayName,
                    meetingID: meetingID,
                    projectID: projectID
                )
            }
        }
    }

    private func linkToNewName(speaker: UnconfirmedSpeaker) {
        perform {
            _ = try await service.link(
                speakerID: speaker.id,
                toNewParticipantNamed: newNames[speaker.id] ?? "",
                meetingID: meetingID,
                projectID: projectID
            )
            newNames[speaker.id] = ""
        }
    }

    /// Saves, then reloads from the repository before the screen changes. Nothing is shown as
    /// done until it is actually stored.
    private func perform(_ body: @escaping () async throws -> Void) {
        guard !isSaving else {
            return
        }
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await body()
            } catch let error as SpeakerConfirmationError {
                errorMessage = message(for: error)
                return
            } catch {
                errorMessage = "화자를 연결하지 못했습니다."
                return
            }
            await reload()
            await onChanged()
        }
    }

    private func reload() async {
        do {
            overview = try await service.overview(projectID: projectID, meetingID: meetingID)
        } catch let error as SpeakerConfirmationError {
            errorMessage = message(for: error)
        } catch {
            errorMessage = "화자 정보를 불러오지 못했습니다."
        }
    }

    private func message(for error: SpeakerConfirmationError) -> String {
        switch error {
        case .projectNotFound:
            return "프로젝트를 찾을 수 없습니다. 삭제되었을 수 있습니다."
        case .meetingNotFound:
            return "회의를 찾을 수 없습니다. 삭제되었을 수 있습니다."
        case .speakerNotFound:
            return "이 화자를 찾을 수 없습니다. 화면을 다시 열어주세요."
        case .participantNotFound:
            return "선택한 참석자를 찾을 수 없습니다. 삭제되었을 수 있습니다."
        case .nameMissing:
            return "참석자 이름을 입력해주세요."
        case .repositoryFailure:
            return "변경 사항을 저장하지 못했습니다."
        }
    }
}
