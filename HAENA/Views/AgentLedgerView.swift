import SwiftUI

struct AgentLedgerView: View {
    let projectRepository: any ProjectRepository
    let service: AgentLedgerService
    let onClose: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var feedbackTargetInFlight: UUID?
    @State private var feedbackFailure: AgentLedgerFeedbackFailure?
    @State private var showsDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    private enum LoadState: Equatable {
        case loading
        case loaded([AgentLedgerRow])
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
        .frame(minWidth: 340, idealWidth: 540, minHeight: 440, idealHeight: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-ledger-screen")
        .task { await load() }
        .sheet(isPresented: $showsDeleteConfirmation) {
            deleteConfirmation
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Agent 기록"))
                .font(.title2)
                .bold()
            Text(L10n.text("이 Mac에서 앱이 확인한 예약·변경·완료 기록입니다. 표시 콜백은 시스템이 앱을 호출했다는 사실이며, 사람이 알림을 봤다는 보장은 아닙니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agent-ledger-truthfulness-guidance")
            Text(L10n.text("Agent 기록과 피드백은 외부 분석 서비스로 전송하지 않습니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("agent-ledger-privacy-guidance")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView(L10n.text("기록 불러오는 중…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("agent-ledger-loading")

        case .failed:
            VStack(spacing: 12) {
                Text(L10n.text("Agent 기록을 불러오지 못했습니다. 저장된 프로젝트와 알림은 변경되지 않았습니다."))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("agent-ledger-load-error")
                Button(L10n.text("다시 시도")) { Task { await load() } }
                    .accessibilityIdentifier("retry-agent-ledger-button")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let rows) where rows.isEmpty:
            VStack(spacing: 8) {
                Text(L10n.text("아직 Agent 기록이 없습니다."))
                    .font(.headline)
                Text(L10n.text("알림을 예약하거나 업무를 완료하면 이곳에 로컬 기록이 쌓입니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-ledger-empty-state")

        case .loaded(let rows):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        ledgerRow(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-ledger-event-list")
        }
    }

    private func ledgerRow(_ row: AgentLedgerRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.actionItemTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.projectName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.factLabel)
                .font(.callout)
                .accessibilityIdentifier("agent-ledger-event-fact-label")
            Text(AgentLedgerDateFormatter().string(from: row.event.occurredAt))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if row.acceptsFeedback {
                feedbackControls(for: row)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-ledger-event-\(row.id.uuidString)")
    }

    private func feedbackControls(for row: AgentLedgerRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("이 알림은 어땠나요?"))
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(AgentLedgerFeedback.allCases, id: \.self) { choice in
                    Button(choice.label) {
                        Task { await toggleFeedback(choice, for: row) }
                    }
                    .buttonStyle(.bordered)
                    .tint(row.feedback == choice ? Color.accentColor : Color.secondary)
                    .disabled(feedbackTargetInFlight != nil || isDeleting)
                    .accessibilityIdentifier("agent-ledger-feedback-\(choice.rawValue)")
                    .accessibilityValue(row.feedback == choice ? L10n.text("선택됨") : L10n.text("선택 안 됨"))
                    .frame(maxWidth: .infinity)
                }
            }

            if let message = feedbackFailure?.message(for: row), feedbackTargetInFlight == nil {
                Text(L10n.text(message))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agent-ledger-feedback-error")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let deleteError {
                Text(L10n.text(deleteError))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agent-ledger-delete-error")
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    deleteButton
                    Spacer(minLength: 16)
                    closeButton
                }
                VStack(spacing: 8) {
                    deleteButton.frame(maxWidth: .infinity)
                    closeButton.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var deleteButton: some View {
        Button(L10n.text("전체 기록 삭제"), role: .destructive) {
            deleteError = nil
            showsDeleteConfirmation = true
        }
        .disabled(!hasRows || isDeleting)
        .accessibilityIdentifier("delete-all-agent-ledger-button")
    }

    private var closeButton: some View {
        Button(L10n.text("닫기")) { onClose() }
            .keyboardShortcut(.defaultAction)
            .disabled(isDeleting)
            .accessibilityIdentifier("close-agent-ledger-button")
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("전체 기록을 삭제할까요?"))
                .font(.headline)
            Text(L10n.text("Agent 기록과 알림 피드백만 삭제합니다. 프로젝트, 업무, 현재 알림 예약은 그대로 유지됩니다. 삭제한 기록은 복구할 수 없습니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(L10n.text("취소")) { showsDeleteConfirmation = false }
                    .disabled(isDeleting)
                Button(L10n.text("전체 기록 삭제"), role: .destructive) {
                    Task { await deleteAll() }
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("confirm-delete-all-agent-ledger-button")
            }
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("delete-agent-ledger-confirmation")
    }

    private var hasRows: Bool {
        if case .loaded(let rows) = loadState { return !rows.isEmpty }
        return false
    }

    @MainActor
    private func load() async {
        loadState = .loading
        feedbackFailure = nil
        deleteError = nil
        do {
            async let events = service.events()
            async let projects = projectRepository.allProjects()
            loadState = .loaded(
                AgentLedgerPresentation.rows(
                    events: try await events,
                    projects: try await projects
                )
            )
        } catch {
            loadState = .failed
        }
    }

    @MainActor
    private func toggleFeedback(_ choice: AgentLedgerFeedback, for row: AgentLedgerRow) async {
        guard row.acceptsFeedback else { return }
        let nextValue: AgentLedgerFeedback? = row.feedback == choice ? nil : choice
        feedbackTargetInFlight = row.event.reminderID
        feedbackFailure = nil
        defer { feedbackTargetInFlight = nil }

        do {
            if let nextValue {
                _ = try await service.setFeedback(nextValue, for: row.event)
            } else {
                try await service.clearFeedback(for: row.event.reminderID)
            }
            guard case .loaded(var rows) = loadState,
                  let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
            rows[index].feedback = nextValue
            loadState = .loaded(rows)
        } catch {
            feedbackFailure = AgentLedgerFeedbackFailure(reminderID: row.event.reminderID)
        }
    }

    @MainActor
    private func deleteAll() async {
        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }
        do {
            try await service.clearAll()
            showsDeleteConfirmation = false
            loadState = .loaded([])
        } catch {
            showsDeleteConfirmation = false
            deleteError = "Agent 기록을 삭제하지 못했습니다. 기존 기록은 유지됩니다."
        }
    }
}
