import SwiftUI

struct ContentView: View {
    let repository: any ProjectRepository

    @State private var showingPasteTranscript = false

    var body: some View {
        VStack(spacing: 24) {
            Text(AppInfo.name)
                .font(.largeTitle)
                .bold()
                .accessibilityIdentifier("product-name")

            VStack(spacing: 12) {
                Button("녹음 시작") {}
                    .accessibilityIdentifier("record-button")

                Button("파일 불러오기") {}
                    .accessibilityIdentifier("import-button")

                Button("텍스트 회의록 붙여넣기") {
                    showingPasteTranscript = true
                }
                .accessibilityIdentifier("paste-transcript-button")
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 280)
        .sheet(isPresented: $showingPasteTranscript) {
            PasteTranscriptView(service: TextMeetingCaptureService(repository: repository))
        }
    }
}

#Preview {
    ContentView(repository: InMemoryProjectRepository())
}
