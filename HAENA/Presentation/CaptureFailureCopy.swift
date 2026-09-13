import Foundation

/// Korean copy for the steps that can fail *after* a capture has already stored its meeting.
///
/// Shared by the pasted-text and audio capture screens so both describe the same failure the same
/// way. Nothing from a provider's response is interpolated, so no key material and no transcript
/// text can reach the screen through an error.
///
/// None of these say the meeting was saved, even though it was: they are shown on the completion
/// screen, which has already said so. Repeating it would make the screen argue with itself.
enum CaptureFailureCopy {
    /// Extraction ran after the meeting was stored and did not finish. The meeting, its transcript
    /// and any audio are still there. This reports a failed step, never an unchecked result count.
    static func extraction(_ error: any Error) -> String {
        "AI 분석을 완료하지 못했습니다. " + reason(error)
    }

    private static func reason(_ error: any Error) -> String {
        guard let error = error as? WorkStateExtractionError else {
            return "업무 상태 추출에 실패했습니다."
        }

        switch error {
        case .missingCredential:
            return "업무 상태를 추출하려면 AI 설정에서 OpenAI API 키를 등록해주세요."
        case .credentialInteractionRequired:
            // Says what to do, not what went wrong: the key is there, the app just may not read it
            // without the user. Opening the settings screen is the instruction because that screen
            // reads the stored key on appear, which is what raises the system prompt — "연결 확인"
            // would be wrong advice, as it only checks a key typed into the field beside it.
            //
            // The last step names the button by the words printed on it. It used to say only
            // "다시 시도해주세요", which described an action that did not exist anywhere in the app:
            // the only thing a user could actually do was paste the same transcript again and end
            // up with a duplicate meeting. Re-running is still the user's to start — naming the
            // control is not a promise that anything retries by itself.
            return "저장된 API 키를 읽으려면 확인이 필요합니다. AI 설정을 열어 시스템 확인 창에 응답한 뒤 "
                + MeetingReanalysisCopy.button + "를 눌러주세요."
        case .credentialUnavailable:
            return "저장된 API 키를 읽지 못했습니다. AI 설정에서 키 상태를 확인해주세요."
        case .unauthorized:
            return "AI 인증에 실패했습니다. AI 설정에서 키를 확인해주세요."
        case .rateLimited:
            return "AI 요청이 일시적으로 제한되었습니다. 잠시 후 다시 시도해주세요."
        case .timedOut, .networkUnavailable:
            return "AI 서버에 연결하지 못했습니다."
        case .refused:
            return "AI가 이 회의록 분석을 거절했습니다."
        case .serverError, .requestRejected, .emptyResponse, .malformedResponse, .invalidConfiguration:
            return "업무 상태 추출에 실패했습니다."
        }
    }
}
