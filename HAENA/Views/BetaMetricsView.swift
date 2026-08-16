import SwiftUI

/// 베타 측정: what this Mac has actually recorded since 0.2.2, and nothing else.
///
/// The screen takes a summary of counts and never a repository. That is the point rather than an
/// omission: metrics events outlive the projects and proposals they were recorded for, so any
/// attempt to name the meeting behind a number would either resolve a deleted entity or leave a
/// dangling identifier on screen. Counts cannot go stale that way.
///
/// Nothing here is estimated. Where the measurement has no denominator or no sample it says so —
/// `BetaMetricsDisplay` owns that decision, so the wording cannot drift per row.
struct BetaMetricsView: View {
    let service: BetaMetricsService
    let calendar: Calendar
    let onClose: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var showsCriteria = false
    @State private var showsResetConfirmation = false
    @State private var isResetting = false
    @State private var resetError: String?

    init(
        service: BetaMetricsService,
        calendar: Calendar = .current,
        onClose: @escaping () -> Void
    ) {
        self.service = service
        self.calendar = calendar
        self.onClose = onClose
    }

    private enum LoadState: Equatable {
        case loading
        case loaded(BetaMetricsSummary)
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(20)
        // The same narrow floor as the Agent record sheet. Everything below it scrolls or wraps, so
        // a user who keeps a narrow window still reaches every value and the reset button.
        .frame(minWidth: 340, idealWidth: 560, minHeight: 440, idealHeight: 660)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beta-metrics-screen")
        .task { await load() }
        .sheet(isPresented: $showsResetConfirmation) {
            resetConfirmation
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BetaMetricsDisplay.screenTitle)
                .font(.title2)
                .bold()
            Text(BetaMetricsDisplay.summaryNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("beta-metrics-truthfulness-guidance")
            Text(BetaMetricsDisplay.privacyNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("beta-metrics-privacy-guidance")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("측정 결과 불러오는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("beta-metrics-loading")

        case .failed:
            VStack(spacing: 12) {
                Text(BetaMetricsDisplay.loadFailure)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beta-metrics-load-error")
                Button("다시 시도") { Task { await load() } }
                    .accessibilityIdentifier("retry-beta-metrics-button")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let summary):
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if BetaMetricsDisplay.isFreshInstall(summary) {
                        freshInstallNotice
                    }
                    ForEach(BetaMetricsDisplay.sections(for: summary)) { section in
                        metricSection(section)
                    }
                    criteria
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("beta-metrics-list")
        }
    }

    /// Told apart from a measured zero on purpose: every row below still renders, so the user can
    /// see what will be counted, while this states that nothing has been counted yet.
    private var freshInstallNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(BetaMetricsDisplay.freshInstallTitle)
                .font(.headline)
            Text(BetaMetricsDisplay.freshInstallMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beta-metrics-empty-state")
    }

    private func metricSection(_ section: BetaMetricsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.headline)

            ForEach(section.rows) { row in
                metricRow(row)
            }

            if let note = section.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beta-metrics-note-\(section.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beta-metrics-section-\(section.id)")
    }

    private func metricRow(_ row: BetaMetricsRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The value drops under its title rather than off the edge when the window is narrow,
            // which is what keeps this screen readable without a horizontal scroll.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    rowTitle(row)
                    Spacer(minLength: 12)
                    rowValue(row)
                }
                VStack(alignment: .leading, spacing: 2) {
                    rowTitle(row)
                    rowValue(row)
                }
            }

            if let detail = row.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beta-metrics-detail-\(row.id)")
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beta-metrics-row-\(row.id)")
    }

    private func rowTitle(_ row: BetaMetricsRow) -> some View {
        Text(row.title)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowValue(_ row: BetaMetricsRow) -> some View {
        Text(row.value)
            .font(.headline)
            .foregroundStyle(row.isEmptyState ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("beta-metrics-value-\(row.id)")
    }

    /// Reachable from the screen itself rather than the docs: a number whose counting rule lives in
    /// a file the user has to go find is a number they will read wrong.
    private var criteria: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(
                showsCriteria
                    ? BetaMetricsDisplay.hideCriteriaLabel
                    : BetaMetricsDisplay.showCriteriaLabel
            ) {
                showsCriteria.toggle()
            }
            .accessibilityIdentifier("beta-metrics-criteria-toggle")

            if showsCriteria {
                VStack(alignment: .leading, spacing: 8) {
                    Text(BetaMetricsDisplay.criteriaTitle)
                        .font(.headline)
                    ForEach(Array(BetaMetricsDisplay.criteriaParagraphs.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("beta-metrics-criteria-\(item.offset)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("beta-metrics-criteria")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let resetError {
                Text(resetError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("beta-metrics-reset-error")
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    resetButton
                    Spacer(minLength: 16)
                    closeButton
                }
                VStack(spacing: 8) {
                    resetButton.frame(maxWidth: .infinity)
                    closeButton.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var resetButton: some View {
        Button(BetaMetricsDisplay.resetButtonLabel, role: .destructive) {
            resetError = nil
            showsResetConfirmation = true
        }
        .disabled(isResetting || !isLoaded)
        .accessibilityIdentifier("reset-beta-metrics-button")
    }

    private var closeButton: some View {
        Button("닫기") { onClose() }
            .keyboardShortcut(.defaultAction)
            .disabled(isResetting)
            .accessibilityIdentifier("close-beta-metrics-button")
    }

    /// The shared destructive sheet, so this screen cannot quietly grow a confirmation that behaves
    /// differently from the ones the user has already learned.
    private var resetConfirmation: some View {
        DeletionConfirmationView(
            title: BetaMetricsDisplay.resetConfirmationTitle,
            message: BetaMetricsDisplay.resetConfirmationMessage,
            confirmButtonIdentifier: "confirm-reset-beta-metrics-button",
            cancelButtonIdentifier: "cancel-reset-beta-metrics-button",
            onConfirm: { await reset() },
            onCancel: { showsResetConfirmation = false }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("beta-metrics-reset-confirmation")
    }

    private var isLoaded: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    @MainActor
    private func load() async {
        loadState = .loading
        resetError = nil
        do {
            loadState = .loaded(try await service.summary(calendar: calendar))
        } catch {
            loadState = .failed
        }
    }

    @MainActor
    private func reset() async {
        guard !isResetting else { return }
        isResetting = true
        resetError = nil
        defer { isResetting = false }

        do {
            try await service.reset()
            showsResetConfirmation = false
            // Re-read rather than assuming an empty summary: the measurement start point is set by
            // the service, and inventing one here would put a date on screen that nothing recorded.
            await load()
        } catch {
            showsResetConfirmation = false
            resetError = BetaMetricsDisplay.resetFailure
        }
    }
}
