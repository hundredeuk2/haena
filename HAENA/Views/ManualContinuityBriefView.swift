import SwiftUI

/// Stable identifiers shared with the project-detail entry point and UI tests.
///
/// Keeping these in the brief's presentation file avoids duplicating string literals when the
/// surrounding project screen presents this view. Dynamic identifiers include only app-owned
/// UUIDs; no title, transcript text, or participant name enters the accessibility contract.
enum ManualContinuityBriefAccessibility {
    static let screen = "manual-continuity-brief-screen"
    static let entryCTA = "open-manual-continuity-brief-button"
    static let loading = "manual-continuity-brief-loading"
    static let scroll = "manual-continuity-brief-scroll"
    static let error = "manual-continuity-brief-error"
    static let retry = "manual-continuity-brief-retry"
    static let close = "close-manual-continuity-brief-button"
    static let transitionUnavailable = "manual-continuity-brief-transition-unavailable"
    static let confirmedSection = "manual-continuity-brief-confirmed-section"
    static let reviewSection = "manual-continuity-brief-review-section"
    static let delaySection = "manual-continuity-brief-delay-section"
    static let ambiguitySection = "manual-continuity-brief-ambiguity-section"
    static let agendaSection = "manual-continuity-brief-agenda-section"
    static let evidenceSheet = "manual-continuity-brief-evidence-sheet"
    static let closeEvidence = "close-manual-continuity-brief-evidence"
    static let feedback = "manual-continuity-brief-feedback"
    static let headerSummary = "manual-continuity-brief-header-summary"
    /// 2.7: the three ownership sections and the typed candidate state.
    static let boundary = "manual-continuity-brief-boundary"
    static let candidatesSection = "manual-continuity-brief-candidates-section"
    static let candidateState = "manual-continuity-brief-candidate-state"
    static let completionSection = "manual-continuity-brief-completion-section"
    static let agendaCandidateSection = "manual-continuity-brief-agenda-candidate-section"

    static func transitionCard(_ id: UUID) -> String { "manual-brief-transition-\(id.uuidString)" }
    static func evidence(_ id: UUID) -> String { "manual-brief-evidence-\(id.uuidString)" }
    static func approve(_ id: UUID) -> String { "manual-brief-approve-\(id.uuidString)" }
    static func reject(_ id: UUID) -> String { "manual-brief-reject-\(id.uuidString)" }
    static func ambiguity(_ id: UUID) -> String { "manual-brief-ambiguity-\(id.uuidString)" }
    static func ambiguityCandidate(groupID: UUID, candidateID: UUID) -> String {
        "manual-brief-ambiguity-\(groupID.uuidString)-candidate-\(candidateID.uuidString)"
    }
    static func ambiguityNew(_ id: UUID) -> String { "manual-brief-ambiguity-\(id.uuidString)-new" }
    static func agenda(_ id: UUID) -> String { "manual-brief-agenda-\(id.uuidString)" }
    static func delayBadge(_ kind: ManualContinuityBriefDelayKind) -> String {
        "manual-brief-delay-\(kind.rawValue)"
    }
    static func verdictEffect(_ id: UUID) -> String { "manual-brief-effect-\(id.uuidString)" }
    static func currentStatus(_ id: UUID) -> String { "manual-brief-current-status-\(id.uuidString)" }
}

/// A read-and-review surface for continuity state between meetings.
///
/// The view owns presentation state only. It never reads a repository, applies a transition, or
/// decides whether a mutation is safe. `ManualContinuityBriefService` supplies a fully resolved,
/// finite read model and `WorkStateTransitionReviewService` owns every user verdict.
struct ManualContinuityBriefView: View {
    let projectID: UUID
    let briefService: ManualContinuityBriefService
    let reviewService: WorkStateTransitionReviewService
    /// The same service the AI 제안 inbox uses. Agenda verdicts go through it so both screens read
    /// one authority — the Agenda Item's own `status`/`reviewedAt` in the Project.
    let workStateReviewService: WorkStateReviewService
    let onChanged: () async -> Void
    let onClose: () -> Void

    @State private var loadState: LoadState = .idle
    @State private var feedback: Feedback?
    @State private var evidenceSheet: EvidenceSheet?
    @State private var busyProposalIDs: Set<UUID> = []
    @State private var busyAmbiguityIDs: Set<UUID> = []
    @State private var busyAgendaIDs: Set<UUID> = []

    init(
        projectID: UUID,
        briefService: ManualContinuityBriefService,
        reviewService: WorkStateTransitionReviewService,
        workStateReviewService: WorkStateReviewService,
        onChanged: @escaping () async -> Void,
        onClose: @escaping () -> Void
    ) {
        self.projectID = projectID
        self.briefService = briefService
        self.reviewService = reviewService
        self.workStateReviewService = workStateReviewService
        self.onChanged = onChanged
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            switch loadState {
            case .idle, .loading:
                ProgressView(L10n.text("브리프를 불러오는 중…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(ManualContinuityBriefAccessibility.loading)

            case .projectNotFound:
                errorState(
                    title: L10n.text("프로젝트를 찾을 수 없습니다."),
                    guidance: L10n.text("프로젝트 목록으로 돌아가 다시 선택해주세요."),
                    canRetry: false
                )

            case .projectUnavailable:
                errorState(
                    title: L10n.text("연속성 브리프를 불러오지 못했습니다."),
                    guidance: L10n.text("저장 상태를 확인한 뒤 다시 시도해주세요."),
                    canRetry: true
                )

            case .loaded(let brief):
                loadedContent(brief)
            }
        }
        .frame(minWidth: 360, minHeight: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.screen)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("닫기"), action: onClose)
                    .accessibilityIdentifier(ManualContinuityBriefAccessibility.close)
            }
        }
        .task(id: projectID) {
            await load()
        }
        .overlay {
            if let evidenceSheet {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    evidenceView(evidenceSheet)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(radius: 18)
                        .padding(24)
                }
            }
        }
    }

    // MARK: - Load states

    private func errorState(title: String, guidance: String, canRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canRetry {
                Button(L10n.text("다시 시도")) {
                    Task { await load() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.error)
    }

    /// A: already approved · B: awaiting a verdict · C: approved next agenda. The split is computed
    /// once by `ManualContinuityBriefVerdictQueue` so the header count and the sections agree.
    private func loadedContent(_ brief: ManualContinuityBrief) -> some View {
        let queue = ManualContinuityBriefVerdictQueue(brief: brief)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(brief, queue: queue)
                warnings(brief)
                confirmedState(brief)
                candidates(queue)
                approvedAgenda(queue)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ManualContinuityBriefAccessibility.scroll)
        }
    }

    private func header(_ brief: ManualContinuityBrief, queue: ManualContinuityBriefVerdictQueue) -> some View {
        let latestMeeting = brief.project.meetings.max { left, right in
            if left.occurredAt != right.occurredAt { return left.occurredAt < right.occurredAt }
            return left.id.uuidString.lowercased() < right.id.uuidString.lowercased()
        }
        let reviewCount = queue.candidateCount
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("회의 연속성 브리프"))
                .font(.title2.bold())
            Text(brief.project.name)
                .font(.headline)
            Text(L10n.text("확정된 상태와 검토할 변화를 분리해 보여드립니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let latestMeeting {
                Text(L10n.format("최근 회의 · %@", String(describing: latestMeeting.title)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.format("판정 대기 %@건 · 확정 아젠다 %@건", String(describing: reviewCount), String(describing: brief.approvedNextAgenda.count)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.headerSummary)
            // The boundary, stated where the user reads it: looking saves nothing.
            Text(L10n.text("브리프를 열거나 둘러보는 것은 저장하지 않습니다. 후보의 판정 버튼만 저장된 상태를 바꿉니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.boundary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func warnings(_ brief: ManualContinuityBrief) -> some View {
        if brief.transitionAvailability == .unavailable {
            warningCard(
                L10n.text("확정된 상태는 볼 수 있지만, 회의 간 변화는 지금 불러올 수 없습니다. 변경 후보가 0건이라는 뜻이 아닙니다."),
                identifier: ManualContinuityBriefAccessibility.transitionUnavailable
            )
        }
        if brief.personalisation == .notConfigured {
            warningCard(L10n.text("내 프로필이 없어 모든 업무를 팀 업무로 표시합니다."))
        } else if brief.personalisation == .unavailable {
            warningCard(L10n.text("내 프로필을 불러오지 못해 모든 업무를 팀 업무로 표시합니다."))
        }
        if let feedback {
            Text(feedback.isComposed ? feedback.message : L10n.text(feedback.message))
                .font(.callout)
                .foregroundStyle(feedback.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.feedback)
        }
    }

    private func warningCard(_ message: String, identifier: String? = nil) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier ?? "manual-continuity-brief-warning")
    }

    // MARK: - Confirmed state

    private func confirmedState(_ brief: ManualContinuityBrief) -> some View {
        briefSection(
            L10n.text("확정된 상태"),
            subtitle: L10n.text("사용자가 이미 승인한 상태입니다. 이 화면에서는 읽기만 합니다."),
            identifier: ManualContinuityBriefAccessibility.confirmedSection
        ) {
            confirmedGroup(L10n.text("결정"), values: brief.confirmedDecisions.map(\.statement), key: "decisions")

            if brief.personalisation == .personalised {
                confirmedGroup(L10n.text("내가 맡은 일"), values: brief.myActiveCommitments.map(\.title), key: "mine")
            }
            confirmedGroup(L10n.text("팀의 진행 업무"), values: brief.otherCommitments.map(\.title), key: "team")
            confirmedGroup(L10n.text("완료된 업무"), values: brief.completedCommitments.map(\.title), key: "completed")
            confirmedGroup(L10n.text("미해결 질문"), values: brief.unresolvedQuestions.map(\.question), key: "questions")
        }
    }

    /// `key` names the group for tests and assistive queries: which carried group an item sits in
    /// is the fact a verdict changes, so it has to be addressable without matching titles.
    private func confirmedGroup(_ title: String, values: [String], key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                BriefBadge(text: L10n.text("확정"), tone: .confirmed)
            }
            if values.isEmpty {
                Text(L10n.text("없음"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manual-brief-confirmed-\(key)")
    }

    // MARK: - B: candidates awaiting a verdict

    /// One section for everything this meeting asks the user to decide, grouped by the verdict the
    /// service can apply. Empty states name their cause; a load failure is never shown as zero.
    private func candidates(_ queue: ManualContinuityBriefVerdictQueue) -> some View {
        briefSection(
            L10n.text("판정 대기 후보"),
            subtitle: L10n.text("이번 회의에서 제안된 변화입니다. 아래 버튼을 누르기 전까지 저장된 상태는 바뀌지 않습니다."),
            identifier: ManualContinuityBriefAccessibility.candidatesSection
        ) {
            candidateState(queue.state)
            candidateGroup(L10n.text("완료 후보"), identifier: ManualContinuityBriefAccessibility.completionSection,
                           items: queue.completions)
            candidateGroup(L10n.text("막히거나 늦어진 일"), identifier: ManualContinuityBriefAccessibility.delaySection,
                           subtitle: L10n.text("지연, 차단, 기한 초과는 서로 다른 근거로 표시합니다."), items: queue.progress)
            candidateGroup(L10n.text("검토할 변화"), identifier: ManualContinuityBriefAccessibility.reviewSection,
                           subtitle: L10n.text("한 항목씩 근거를 확인한 뒤 승인하거나 거절하세요."), items: queue.changes,
                           emptyText: queue.state == .none || queue.state == .firstBrief ? nil : L10n.text("검토할 변화가 없습니다."))
            ambiguityCandidates(queue.carried)
            agendaCandidates(queue)
        }
    }

    @ViewBuilder
    private func candidateState(_ state: ManualContinuityBriefCandidateState) -> some View {
        switch state {
        case .pending:
            EmptyView()
        case .unavailable:
            Text(L10n.text("후보 목록을 불러오지 못했습니다. 후보가 0건이라는 뜻이 아닙니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.candidateState)
        case .firstBrief:
            Text(L10n.text("첫 브리프입니다. 비교할 이전 회의 상태가 없어 판정할 후보가 없습니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.candidateState)
        case .none:
            Text(L10n.text("판정할 후보가 없습니다. 이전 회의 상태가 그대로 이어집니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.candidateState)
        }
    }

    @ViewBuilder
    private func candidateGroup(
        _ title: String,
        identifier: String,
        subtitle: String? = nil,
        items: [ManualContinuityBriefVerdictQueue.TransitionCandidate],
        emptyText: String? = nil
    ) -> some View {
        if !items.isEmpty || emptyText != nil {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if items.isEmpty, let emptyText {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        transitionCard(
                            item.transition,
                            verdict: item.verdict,
                            delayKind: item.delay?.kind,
                            assigneeDisplayName: item.delay?.assigneeDisplayName
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }

    private func transitionCard(
        _ transition: ManualContinuityBriefTransition,
        verdict: ManualContinuityBriefVerdictKind,
        delayKind: ManualContinuityBriefDelayKind? = nil,
        assigneeDisplayName: String? = nil
    ) -> some View {
        let proposal = transition.proposal
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                BriefBadge(text: transitionLabel(proposal.transitionKind), tone: .review)
                if let delayKind {
                    BriefBadge(text: delayLabel(delayKind), tone: delayTone(delayKind))
                        .accessibilityIdentifier(ManualContinuityBriefAccessibility.delayBadge(delayKind))
                }
                Spacer(minLength: 0)
                Text(workStateLabel(proposal.workStateKind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(transition.currentState?.displayText ?? transition.previousState?.displayText ?? L10n.text("대상을 찾을 수 없음"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let sourceMeetingTitle = transition.sourceMeetingTitle {
                Text(L10n.format("출처 회의 · %@", String(describing: sourceMeetingTitle)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The exact object a verdict would touch, and where it stands now — read from the
            // Project value the read model resolved, never inferred from the proposal's text.
            if let affected = transition.previousState ?? transition.currentState {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("영향 대상 · %@", String(describing: workStateLabel(affected.kind) + " “" + affected.displayText + "”")))
                    Text(L10n.format("현재 상태 · %@", String(describing: currentStatusLabel(affected))))
                        .accessibilityIdentifier(ManualContinuityBriefAccessibility.currentStatus(proposal.id))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if delayKind != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("담당 · %@", assigneeDisplayName ?? L10n.text("미지정")))
                    if let dueDate = transition.relevantDueDate {
                        Text(L10n.format("기한 · %@", MeetingDateFormatter(locale: AppLanguageSettings.shared.locale).dateOnlyString(from: dueDate)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let previous = transition.previousState,
               let current = transition.currentState,
               previous.displayText != current.displayText {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.format("이전 · %@", String(describing: previous.displayText)))
                    Text(L10n.format("이번 회의 · %@", String(describing: current.displayText)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if proposal.relations.contains(where: {
                $0.kind == .derivedFrom && $0.relatedKind == .decision
            }) {
                Label(L10n.text("이 Decision에서 파생"), systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("manual-brief-derived-from-decision")
            }

            if !proposal.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(proposal.reasons, id: \.rawValue) { reason in
                        Text(L10n.format("확인 이유 · %@", String(describing: reasonLabel(reason))))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            evidenceControl(
                transition.evidence,
                ownerID: proposal.id,
                fallbackTitle: transition.currentState?.displayText ?? transition.previousState?.displayText
            )

            if case .disabled(let reason) = transition.destructiveApplyState {
                Text(applyBlockLabel(reason))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(L10n.format("승인 시 · %@", L10n.text(verdict.approveEffectKey)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.verdictEffect(proposal.id))

            reviewActions(for: transition, verdict: verdict)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.transitionCard(proposal.id))
    }

    /// Approve is the only prominent control: it is the one that changes the Project. Reject records
    /// a verdict for this candidate alone and changes nothing that was already approved.
    private func reviewActions(
        for transition: ManualContinuityBriefTransition,
        verdict: ManualContinuityBriefVerdictKind
    ) -> some View {
        let id = transition.proposal.id
        let approveDisabled: Bool
        if case .disabled = transition.destructiveApplyState {
            approveDisabled = true
        } else {
            approveDisabled = false
        }

        return VStack(spacing: 8) {
            BriefVerdictButton(
                title: L10n.text(verdict.approveKey),
                hint: L10n.text("이 후보 하나에만 적용되며 저장된 상태를 바꿉니다."),
                identifier: ManualContinuityBriefAccessibility.approve(id),
                isPrimary: true,
                isDisabled: approveDisabled || busyProposalIDs.contains(id)
            ) {
                Task { await review(transition, action: .approve) }
            }

            BriefVerdictButton(
                title: L10n.text(verdict.rejectKey),
                hint: L10n.text("이 후보 하나만 거절로 기록하며 기존 상태는 바꾸지 않습니다."),
                identifier: ManualContinuityBriefAccessibility.reject(id),
                isPrimary: false,
                isDisabled: busyProposalIDs.contains(id)
            ) {
                Task { await review(transition, action: .reject) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Ambiguity

    @ViewBuilder
    private func ambiguityCandidates(_ brief: ManualContinuityBrief) -> some View {
        if !brief.ambiguousMatches.isEmpty {
            briefSection(
                L10n.text("연결 확인"),
                subtitle: L10n.text("비슷한 항목 중 하나를 직접 고르거나 새 항목으로 유지하세요."),
                identifier: ManualContinuityBriefAccessibility.ambiguitySection
            ) {
                ForEach(brief.ambiguousMatches, id: \.group.id) { match in
                    ambiguityCard(match)
                }
            }
        }
    }

    private func ambiguityCard(_ match: ManualContinuityBriefAmbiguousMatch) -> some View {
        let groupID = match.group.id
        return VStack(alignment: .leading, spacing: 12) {
            BriefBadge(text: L10n.text("연결 확인 필요"), tone: .review)
            Text(match.incomingState?.displayText ?? L10n.text("이번 회의 항목을 찾을 수 없음"))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if match.selections.isEmpty {
                Text(L10n.text("연결할 수 있는 기존 항목이 없습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(match.selections.enumerated()), id: \.offset) { _, selection in
                    ambiguitySelection(selection, in: match)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.ambiguity(groupID))
    }

    @ViewBuilder
    private func ambiguitySelection(
        _ value: ManualContinuityBriefAmbiguitySelection,
        in match: ManualContinuityBriefAmbiguousMatch
    ) -> some View {
        let groupID = match.group.id
        let applyDisabled: Bool = if case .disabled = value.destructiveApplyState {
            true
        } else {
            false
        }

        VStack(alignment: .leading, spacing: 8) {
            switch value.selection {
            case .priorCandidate(let candidateID):
                if let candidate = value.priorState {
                    Text(candidate.displayText)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    evidenceControl(
                        value.evidence,
                        ownerID: value.transitionID ?? candidateID,
                        fallbackTitle: candidate.displayText
                    )
                }
                Button {
                    Task { await resolveAmbiguity(match, selection: value.selection) }
                } label: {
                    Text(L10n.text("이 기존 항목과 연결"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(applyDisabled || busyAmbiguityIDs.contains(groupID))
                .accessibilityIdentifier(
                    ManualContinuityBriefAccessibility.ambiguityCandidate(
                        groupID: groupID,
                        candidateID: candidateID
                    )
                )

            case .new:
                evidenceControl(
                    value.evidence,
                    ownerID: groupID,
                    fallbackTitle: match.incomingState?.displayText
                )
                Button {
                    Task { await resolveAmbiguity(match, selection: value.selection) }
                } label: {
                    Text(L10n.text("기존 항목과 연결하지 않고 새 항목으로 유지"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(applyDisabled || busyAmbiguityIDs.contains(groupID))
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.ambiguityNew(groupID))
            }

            if case .disabled(let reason) = value.destructiveApplyState {
                Text(applyBlockLabel(reason))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Agenda

    /// Agenda candidates belong to B: they are pending until the user says otherwise.
    @ViewBuilder
    private func agendaCandidates(_ queue: ManualContinuityBriefVerdictQueue) -> some View {
        if !queue.agendaCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("아젠다 후보")).font(.headline)
                ForEach(queue.agendaCandidates, id: \.agendaItem.id) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        agendaRow(candidate.agendaItem, badge: L10n.text("아젠다 후보"), tone: .review)
                        if let source = candidate.sources.first {
                            Text(agendaSourceLabel(source.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            evidenceControl(
                                source.evidence,
                                ownerID: candidate.agendaItem.id,
                                fallbackTitle: candidate.agendaItem.title
                            )
                        }
                        agendaActions(for: candidate.agendaItem)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ManualContinuityBriefAccessibility.agendaCandidateSection)
        }
    }

    /// C: only what the user already approved. No verdict control lives here.
    private func approvedAgenda(_ queue: ManualContinuityBriefVerdictQueue) -> some View {
        briefSection(
            L10n.text("확정된 다음 아젠다"),
            subtitle: L10n.text("이미 승인한 다음 회의 안건입니다. 후보는 위의 판정 대기 목록에 있습니다."),
            identifier: ManualContinuityBriefAccessibility.agendaSection
        ) {
            if queue.approvedAgenda.isEmpty {
                Text(L10n.text("아직 확인된 다음 아젠다가 없습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(queue.approvedAgenda) { item in
                agendaRow(item, badge: L10n.text("확정"), tone: .confirmed)
            }
        }
    }

    /// A 다음 아젠다 verdict is recorded against the Agenda Item, never against a transition row.
    ///
    /// Routing it through a transition was wrong twice over. It landed on whatever carried the item
    /// in — for a carried question, the Open Question's resolution, which then vanished from
    /// 검토할 변화 with no way back — and even when it found the item's own row, rejecting that row
    /// writes only the continuity sidecar, so the AI 제안 inbox went on offering an item this
    /// screen had just excluded. Both screens now read and write the same Agenda Item.
    @ViewBuilder
    private func agendaActions(for item: AgendaItem) -> some View {
        let isBusy = busyAgendaIDs.contains(item.id)
        VStack(spacing: 6) {
            BriefVerdictButton(
                title: L10n.text("다음 아젠다 승인"),
                hint: L10n.text("이 후보 하나에만 적용되며 저장된 상태를 바꿉니다."),
                identifier: ManualContinuityBriefAccessibility.approve(item.id),
                isPrimary: true,
                isDisabled: isBusy
            ) {
                Task { await reviewAgenda(item, approve: true) }
            }

            BriefVerdictButton(
                title: L10n.text("다음 아젠다 제외"),
                hint: L10n.text("이 후보 하나만 거절로 기록하며 기존 상태는 바꾸지 않습니다."),
                identifier: ManualContinuityBriefAccessibility.reject(item.id),
                isPrimary: false,
                isDisabled: isBusy
            ) {
                Task { await reviewAgenda(item, approve: false) }
            }
        }
    }

    private func agendaRow(_ item: AgendaItem, badge: String, tone: BriefBadge.Tone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BriefBadge(text: badge, tone: tone)
                Text(item.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.reason.isEmpty {
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.agenda(item.id))
    }

    // MARK: - Evidence

    @ViewBuilder
    private func evidenceControl(
        _ state: ManualContinuityBriefEvidenceState,
        ownerID: UUID,
        fallbackTitle: String?
    ) -> some View {
        switch state {
        case .resolved(let segment):
            Button(L10n.text("회의 근거 보기")) {
                evidenceSheet = EvidenceSheet(id: ownerID, title: fallbackTitle, segment: segment)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier(ManualContinuityBriefAccessibility.evidence(ownerID))
        case .dangling:
            Label(L10n.text("회의 근거를 찾을 수 없음"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.evidence(ownerID))
        case .notRequired:
            Text(L10n.text("별도 회의 근거가 필요하지 않은 상태입니다."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func evidenceView(_ evidence: EvidenceSheet) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("회의 근거"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.text("닫기")) {
                    evidenceSheet = nil
                }
                .accessibilityIdentifier(ManualContinuityBriefAccessibility.closeEvidence)
            }
            if let title = evidence.title {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(evidence.segment.meetingTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Text(evidence.segment.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 240)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualContinuityBriefAccessibility.evidenceSheet)
    }

    // MARK: - Service calls

    private func load() async {
        loadState = .loading
        switch await briefService.load(projectID: projectID) {
        case .loaded(let brief): loadState = .loaded(brief)
        case .projectNotFound: loadState = .projectNotFound
        case .projectUnavailable: loadState = .projectUnavailable
        }
    }

    private func review(
        _ transition: ManualContinuityBriefTransition,
        action: WorkStateTransitionReviewAction
    ) async {
        let id = transition.proposal.id
        guard busyProposalIDs.insert(id).inserted else { return }
        defer { busyProposalIDs.remove(id) }

        let result = await reviewService.review(
            projectID: projectID,
            proposalID: id,
            action: action
        )
        feedback = feedback(for: result)
        switch result {
        case .applied, .alreadyApplied, .rejected, .alreadyRejected,
             .projectSavedReviewPersistenceFailed:
            await onChanged()
            await load()
        case .refused:
            break
        }
    }

    /// The Project write is the whole verdict, so the screen only reports success after it lands.
    /// A failed save leaves the Agenda Item — and therefore both screens — exactly as they were.
    private func reviewAgenda(_ item: AgendaItem, approve: Bool) async {
        guard busyAgendaIDs.insert(item.id).inserted else { return }
        defer { busyAgendaIDs.remove(item.id) }

        do {
            if approve {
                try await workStateReviewService.approveAgendaItem(id: item.id, in: projectID)
            } else {
                try await workStateReviewService.dismissAgendaItem(id: item.id, in: projectID)
            }
        } catch {
            feedback = Feedback(
                message: L10n.text("다음 아젠다 판정을 저장하지 못했습니다. 다시 시도해주세요.") + " "
                    + L10n.text("후보는 그대로 남아 있습니다. 다시 시도할 수 있습니다."),
                isError: true,
                isComposed: true
            )
            return
        }
        feedback = Feedback(
            message: approve ? L10n.text("다음 아젠다로 승인했습니다.") : L10n.text("다음 아젠다에서 제외했습니다."),
            isError: false
        )
        await onChanged()
        await load()
    }

    private func resolveAmbiguity(
        _ match: ManualContinuityBriefAmbiguousMatch,
        selection: WorkStateAmbiguousMatchSelection
    ) async {
        let id = match.group.id
        guard busyAmbiguityIDs.insert(id).inserted else { return }
        defer { busyAmbiguityIDs.remove(id) }

        let result = await reviewService.resolveAmbiguity(
            projectID: projectID,
            groupID: id,
            selection: selection
        )
        feedback = feedback(for: result)
        switch result {
        case .applied, .alreadyApplied, .projectSavedReviewPersistenceFailed:
            await onChanged()
            await load()
        case .refused:
            break
        }
    }

    // MARK: - Finite display mapping

    private func feedback(for result: WorkStateTransitionReviewResult) -> Feedback {
        switch result {
        case .applied: return Feedback(message: "변화를 승인하고 반영했습니다.", isError: false)
        case .alreadyApplied: return Feedback(message: "이미 승인된 변화입니다.", isError: false)
        case .rejected: return Feedback(message: "변화를 거절했습니다.", isError: false)
        case .alreadyRejected: return Feedback(message: "이미 거절된 변화입니다.", isError: false)
        case .refused:
            return Feedback(
                message: L10n.text("현재 저장 상태에서는 이 요청을 처리할 수 없습니다.") + " "
                    + L10n.text("후보는 그대로 남아 있습니다. 다시 시도할 수 있습니다."),
                isError: true,
                isComposed: true
            )
        case .projectSavedReviewPersistenceFailed:
            return Feedback(
                message: "프로젝트에는 반영했지만 검토 기록을 저장하지 못했습니다. 다시 시도해주세요.",
                isError: true
            )
        }
    }

    private func feedback(for result: WorkStateTransitionAmbiguityReviewResult) -> Feedback {
        switch result {
        case .applied: return Feedback(message: "연결 선택을 반영했습니다.", isError: false)
        case .alreadyApplied: return Feedback(message: "이미 반영된 연결 선택입니다.", isError: false)
        case .refused:
            return Feedback(
                message: L10n.text("현재 저장 상태에서는 연결을 반영할 수 없습니다.") + " "
                    + L10n.text("후보는 그대로 남아 있습니다. 다시 시도할 수 있습니다."),
                isError: true,
                isComposed: true
            )
        case .projectSavedReviewPersistenceFailed:
            return Feedback(
                message: "프로젝트에는 반영했지만 연결 기록을 저장하지 못했습니다. 다시 시도해주세요.",
                isError: true
            )
        }
    }

    private func transitionLabel(_ kind: WorkStateTransitionKind) -> String {
        switch kind {
        case .new: return L10n.text("새 항목 후보")
        case .same: return L10n.text("같은 항목 후보")
        case .changed: return L10n.text("변경 후보")
        case .completed: return L10n.text("완료 후보")
        case .delayed: return L10n.text("진행 확인 후보")
        case .resolved: return L10n.text("해결 후보")
        }
    }

    private func workStateLabel(_ kind: WorkStateKind) -> String {
        switch kind {
        case .decision: return L10n.text("결정")
        case .actionItem: return L10n.text("실행 항목")
        case .openQuestion: return L10n.text("미해결 질문")
        case .agendaItem: return L10n.text("다음 아젠다")
        }
    }

    /// The affected object's present, already-approved standing — from its own stored status.
    private func currentStatusLabel(_ state: ManualContinuityBriefWorkState) -> String {
        switch state {
        case .decision(let value): return value.status == .confirmed ? L10n.text("확정") : L10n.text("미승인 후보")
        case .actionItem(let value): return UIWorkStateDisplay.label(for: value.status)
        case .openQuestion(let value): return value.status == .open ? L10n.text("미해결") : L10n.text("해결됨")
        case .agendaItem(let value): return value.reviewedAt == nil ? L10n.text("아젠다 후보") : L10n.text("확정")
        }
    }

    private func delayLabel(_ kind: ManualContinuityBriefDelayKind) -> String {
        switch kind {
        case .deferred: return L10n.text("지연 후보")
        case .blocked: return L10n.text("차단 후보")
        case .overdue: return L10n.text("기한 초과")
        }
    }

    private func delayTone(_ kind: ManualContinuityBriefDelayKind) -> BriefBadge.Tone {
        switch kind {
        case .deferred: return .warning
        case .blocked, .overdue: return .danger
        }
    }

    private func applyBlockLabel(_ reason: ManualContinuityBriefApplyBlockReason) -> String {
        switch reason {
        case .danglingEvidence: return L10n.text("회의 근거가 사라져 승인할 수 없습니다.")
        case .missingRequiredEvidence: return L10n.text("승인에 필요한 회의 근거가 없습니다.")
        }
    }

    private func agendaSourceLabel(_ kind: ManualContinuityBriefAgendaCandidateSource.Kind) -> String {
        switch kind {
        case .pendingAgendaItem: return L10n.text("이번 회의에서 제안된 아젠다")
        case .carriedToAgenda: return L10n.text("다음 회의로 이월")
        }
    }

    private func reasonLabel(_ reason: WorkStateTransitionReason) -> String {
        switch reason {
        case .ambiguousPriorCandidates: return L10n.text("연결 가능한 기존 항목이 여러 개입니다.")
        case .similarityOnly: return L10n.text("텍스트 유사성만으로는 같은 항목인지 확정할 수 없습니다.")
        case .missingEvidence: return L10n.text("승인에 필요한 회의 근거가 없습니다.")
        case .evidenceNotInSourceMeeting: return L10n.text("근거가 이 변화를 만든 회의에 속하지 않습니다.")
        case .crossProjectCandidate: return L10n.text("다른 프로젝트의 항목과 연결할 수 없습니다.")
        case .unresolvedAssigneeAttribution: return L10n.text("담당자 연결을 먼저 확인해야 합니다.")
        case .unsupportedTransitionForKind: return L10n.text("이 업무 상태에는 적용할 수 없는 변화입니다.")
        case .priorItemNotApproved: return L10n.text("기존 항목이 승인된 상태가 아닙니다.")
        case .stateChangeRequiresApproval: return L10n.text("확정된 상태를 바꾸려면 승인이 필요합니다.")
        case .unknownReferencedObject: return L10n.text("연결된 항목을 찾을 수 없습니다.")
        }
    }

    // MARK: - Shared presentation shells

    private func briefSection<Content: View>(
        _ title: String,
        subtitle: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private extension ManualContinuityBriefView {
    enum LoadState {
        case idle
        case loading
        case loaded(ManualContinuityBrief)
        case projectNotFound
        case projectUnavailable
    }

    struct Feedback: Equatable {
        let message: String
        let isError: Bool
        /// True when `message` was already localized and joined from two sentences.
        var isComposed = false
    }

    struct EvidenceSheet: Identifiable {
        let id: UUID
        let title: String?
        let segment: ManualContinuityBriefEvidenceSegment
    }
}

private struct BriefBadge: View {
    enum Tone {
        case confirmed
        case review
        case warning
        case danger
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .confirmed: return .green
        case .review: return .accentColor
        case .warning: return .orange
        case .danger: return .red
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
    }
}

/// One verdict control. Focusable and activated by Space or Return like the Review card's
/// verdicts, with a hint that says whether pressing it changes stored state.
private struct BriefVerdictButton: View {
    let title: String
    let hint: String
    let identifier: String
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isPrimary {
                Button(action: action) { Text(title).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Text(title).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .onKeyPress(.space) { activate() }
        .onKeyPress(.return) { activate() }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    private func activate() -> KeyPress.Result {
        guard isFocused, !isDisabled else { return .ignored }
        action()
        return .handled
    }
}
