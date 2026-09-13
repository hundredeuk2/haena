#if DEBUG
import Foundation

/// Fixed, opt-in in-memory assembly. Environment selects a seed, never supplies its content.
struct CaptureNavigationUITestSeed {
    let project: Project
    let initialState: PastedTranscriptInitialState

    static func select(environment: [String: String]) -> Self? {
        guard environment["HAENA_UI_TESTING"] == "1",
              environment["HAENA_UI_TEST_CAPTURE_PREFILL"] == "1" else { return nil }
        let id = UUID(uuidString: "C9000000-0000-4000-8000-000000000001")!
        let date = Date(timeIntervalSince1970: 1_786_358_400)
        return Self(
            project: Project(id: id, name: "Shell Synthetic Project", summary: "",
                             createdAt: date, updatedAt: date, meetings: [], decisions: [],
                             actionItems: [], openQuestions: [], nextAgenda: []),
            initialState: .init(selectedProjectID: id, meetingTitle: "Shell Synthetic Meeting",
                                transcript: "Synthetic navigation-only transcript.")
        )
    }
}
#endif
