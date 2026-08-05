import Foundation
import SwiftUI

@main
struct HAENAApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let repository: any ProjectRepository
    private let extractor: any WorkStateExtractor

    init() {
        // UI tests must never read or write the real Application Support data, nor reach the
        // network, so the app's single assembly point swaps in isolated implementations when
        // launched under test. No other code branches on this — everything downstream just sees
        // `any ProjectRepository` and `any WorkStateExtractor`.
        //
        // Note this is the *only* place either implementation is chosen: the deterministic
        // extractor is never substituted for OpenAI when a request fails, because showing a user
        // invented decisions and tasks in place of an error would be worse than showing nothing.
        if ProcessInfo.processInfo.environment["HAENA_UI_TESTING"] == "1" {
            repository = InMemoryProjectRepository()
            extractor = DeterministicWorkStateExtractor()
        } else {
            repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
            extractor = OpenAIWorkStateExtractor()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(repository: repository, extractor: extractor)
        }
    }
}
