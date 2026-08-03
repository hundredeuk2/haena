import Foundation
import SwiftUI

@main
struct HAENAApp: App {
    private let repository: any ProjectRepository

    init() {
        // UI tests must never read or write the real Application Support data, so the app's
        // single assembly point swaps in an isolated in-memory store when launched under test.
        // No other code branches on this — everything downstream just sees `any ProjectRepository`.
        if ProcessInfo.processInfo.environment["HAENA_UI_TESTING"] == "1" {
            repository = InMemoryProjectRepository()
        } else {
            repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(repository: repository)
        }
    }
}
