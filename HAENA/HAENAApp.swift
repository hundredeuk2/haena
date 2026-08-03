import SwiftUI

@main
struct HAENAApp: App {
    private let repository = InMemoryProjectRepository()

    var body: some Scene {
        WindowGroup {
            ContentView(repository: repository)
        }
    }
}
