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
    /// and any audio are all still there — only the work-state results are missing.
    static func extraction(_ error: any Error) -> String {
        "결과 0건 · " + reason(error)
    }

    private static func reason(_ error: any Error) -> String {
        guard let error = error as? WorkStateExtractionError else {
            return "업무 상태 추출에 실패했습니다."
        }

        switch error {
        case .missingCredential:
            return "업무 상태를 추출하려면 AI 설정에서 OpenAI API 키를 등록해주세요."
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
