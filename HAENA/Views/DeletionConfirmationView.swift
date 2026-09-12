import SwiftUI

/// Shared destructive-confirmation sheet for project/meeting deletion. A custom view rather
/// than a system `.alert`/`.confirmationDialog` — this app's screens already attach
/// `accessibilityIdentifier` reliably to plain SwiftUI views, and system alert buttons have
/// historically been less predictable to address from XCUITest across macOS versions.
struct DeletionConfirmationView: View {
    let title: String
    let message: String
    let confirmButtonIdentifier: String
    let cancelButtonIdentifier: String
    let onConfirm: () async -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            Text(L10n.text(message))
                .foregroundStyle(.secondary)

            HStack {
                Button(L10n.text("취소")) {
                    onCancel()
                }
                .accessibilityIdentifier(cancelButtonIdentifier)

                Spacer()

                Button(L10n.text("삭제"), role: .destructive) {
                    Task { await onConfirm() }
                }
                .accessibilityIdentifier(confirmButtonIdentifier)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}
