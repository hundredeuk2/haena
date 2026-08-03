import SwiftUI

struct ContentView: View {
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
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 280)
    }
}

#Preview {
    ContentView()
}
