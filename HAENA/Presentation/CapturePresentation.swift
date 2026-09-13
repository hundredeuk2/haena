import Foundation

/// Display observations only. These are not persisted workflow statuses or approval verdicts.
enum CaptureProgressPhase: String, CaseIterable, Equatable, Sendable {
    case ready, preparing, recording, validating, copyingAudio, transcribing, saving, analysing, retrying

    var localizationKey: String {
        switch self {
        case .ready: "준비됨 · 입력을 확인한 뒤 시작하세요."
        case .preparing: "준비 중…"
        case .recording: "녹음 중"
        case .validating: "입력을 확인하는 중…"
        case .copyingAudio: "오디오 복사본을 준비하는 중…"
        case .transcribing: "음성을 전사하는 중… 회의는 아직 저장되지 않았습니다."
        case .saving: "회의를 저장하는 중…"
        case .analysing: "저장된 회의를 AI가 분석하는 중…"
        case .retrying: "저장된 회의로 AI 분석을 다시 시도하는 중…"
        }
    }

    var accessibilityIdentifier: String { "capture-phase-\(rawValue)" }
}

/// Evidence from a successful save (or the audio service's explicit transcription-failure
/// boundary), never from input source type alone. No raw error/provider content is included.
enum CapturePreservation: Equatable, Sendable, CaseIterable {
    case none, audioOnly, meetingOnly, meetingAndTranscript, meetingAndAudio, meetingAudioAndTranscript

    init(saved meeting: Meeting) {
        switch (meeting.audioAsset != nil, !meeting.transcriptSegments.isEmpty) {
        case (true, true): self = .meetingAudioAndTranscript
        case (true, false): self = .meetingAndAudio
        case (false, true): self = .meetingAndTranscript
        case (false, false): self = .meetingOnly
        }
    }

    var localizationKey: String {
        switch self {
        case .none: "회의는 저장되지 않았습니다. 입력을 확인한 뒤 다시 시도하세요."
        case .audioOnly: "앱의 오디오 복사본은 보존되었습니다. 회의와 전사문은 아직 저장되지 않았습니다. 선택한 파일로 전사를 다시 시도하세요."
        case .meetingOnly: "회의가 보존되었습니다. 저장된 오디오나 전사문은 없습니다."
        case .meetingAndTranscript: "회의와 전사문이 보존되었습니다. 오디오는 저장하지 않았습니다."
        case .meetingAndAudio: "회의와 앱의 오디오 복사본이 보존되었습니다. 전사문은 없습니다."
        case .meetingAudioAndTranscript: "회의, 전사문, 앱의 오디오 복사본이 보존되었습니다."
        }
    }
}

enum CapturePresentationCopy {
    static let candidates = "검토를 기다리는 AI 제안"
    static let approvalNotice = "아래 수치는 미승인 후보입니다. 개별 검토·승인 전에는 확정된 프로젝트 상태가 아닙니다."
    static let retry = "다시 시도"
    static let countsUnavailable = "미검토 제안 수를 확인하지 못했습니다. 저장된 회의 결과에서 확인하세요."
}
