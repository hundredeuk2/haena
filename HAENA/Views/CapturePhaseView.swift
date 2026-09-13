import SwiftUI

struct CapturePhaseView: View {
    let phase: CaptureProgressPhase

    var body: some View {
        Group {
            if phase == .ready || phase == .recording {
                Text(L10n.text(phase.localizationKey))
            } else {
                ProgressView(L10n.text(phase.localizationKey))
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(phase.accessibilityIdentifier)
    }
}
