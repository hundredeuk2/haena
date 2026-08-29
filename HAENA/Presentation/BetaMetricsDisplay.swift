import Foundation

/// One rendered metric: what it is, what the measurement says, and what that number is out of.
///
/// `detail` exists because a rate on its own is unreadable evidence — 50% of two reviews and 50%
/// of two hundred are the same string and not the same fact. Every rate row therefore carries its
/// numerator and denominator, and every duration row carries its sample size.
struct BetaMetricsRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let value: String
    let detail: String?
    /// The measurement has nothing to say yet. Rendered as an explicit empty value, never as a
    /// zero that reads like a result.
    let isEmptyState: Bool
}

struct BetaMetricsSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let rows: [BetaMetricsRow]
    let note: String?
}

/// Every user-facing string and number format for the 베타 측정 screen.
///
/// Kept out of the view because the rules that matter on this screen are wording rules, not layout:
/// an absent denominator, a `0%` standing in for "not measured", or a sentence implying a
/// notification caused a completion are all defects that a rendered `View` cannot be asserted
/// against. Here they are plain values a unit test can read.
enum BetaMetricsDisplay {
    static let screenTitle = "베타 측정"

    /// Stated on the screen itself, not only in the docs: a user looking at usage numbers is
    /// entitled to know, at that moment, that nothing about them left this Mac.
    static let privacyNote =
        "측정은 이 Mac 안에서만 이루어집니다. 회의 제목·전사 원문·참석자 이름은 저장하지 않고, 어디로도 전송하지 않습니다."

    static let summaryNote =
        "0.2.2부터 이 Mac에 기록된 사실만 집계한 값입니다. 추정하거나 채워 넣은 숫자는 없습니다."

    /// The one string allowed where a rate cannot be computed. Never "0%": a rate with an empty
    /// denominator is unknown, and 0% is a measured result someone would act on.
    static let emptyRateValue = "표본 없음"
    /// Likewise never "0ms".
    static let emptyDurationValue = "데이터 없음"

    /// Said in place of a tally, never beside one: the ledger could not be read, so no count of any
    /// kind is honest here.
    static let feedbackUnavailableValue = "피드백 기록을 불러오지 못했습니다"
    static let feedbackUnavailableNote =
        "피드백 기록을 읽지 못해 분포를 표시할 수 없습니다. 아무도 피드백을 남기지 않았다는 뜻이 아닙니다. 나머지 측정값은 정상입니다."

    static let freshInstallTitle = "아직 측정된 이벤트가 없습니다."
    static let freshInstallMessage =
        "회의를 처리하고 AI 제안을 검토하면 이곳에 로컬 집계가 쌓입니다. 0.2.2부터 기록됩니다."

    static let criteriaTitle = "측정 기준"
    static let showCriteriaLabel = "측정 기준 보기"
    static let hideCriteriaLabel = "측정 기준 숨기기"

    static let criteriaParagraphs: [String] = [
        "성공한 회의 처리 수 — 회의가 저장에 도달한 횟수만 셉니다. 실패하거나 도중에 취소한 시도는 세지 않습니다. AI 추출이 실패해도 회의 자체가 저장됐다면 처리된 것으로 셉니다.",
        "서로 다른 사용 날짜 수 — 이벤트가 기록된 날짜의 개수입니다. 같은 날 여러 번 사용해도 1일로 셉니다. 앞으로 계속 쓸지에 대한 예측이 아닙니다.",
        "검토 완료 proposal 수 — 승인 또는 제외로 처리한 제안 수입니다. 승인율의 분자는 승인 수, 분모는 검토 완료 수이며, 분모가 0이면 계산하지 않고 표본 없음으로 둡니다.",
        "수정률 — 분자는 승인 전에 담당자 또는 마감일을 고친 proposal 수, 분모는 검토 완료 proposal 수입니다. 현재 앱이 수정을 지원하는 항목은 이 둘뿐이며, 그 밖의 수정은 측정하지 않습니다.",
        "처리 시간 — 회의를 넘긴 뒤 결과가 나올 때까지 기다린 시간입니다. 녹음하고 있던 시간은 포함하지 않습니다. 표본이 있을 때만 중앙값을 표시합니다. 중앙값은 표본이 홀수면 가운데 값, 짝수면 가운데 두 값의 평균이며, 전체 평균과는 다릅니다. 표본이 없으면 0ms 대신 데이터 없음으로 표시합니다.",
        "Agent 알림 피드백 — 사용자가 직접 남긴 선택의 개수입니다. 이 기록은 별도 저장소에서 읽어오며, 읽지 못하면 0건이 아니라 '불러오지 못했습니다'로 표시합니다. '예약 시각 경과'와 '알림 열기'는 이 Mac에 남은 로컬 기록이며, 사람이 알림을 봤다는 보장은 아닙니다. 알림과 업무 완료 사이의 인과는 측정하지 않습니다.",
        "활성화 — 성공한 회의 처리 수가 기준에 도달했는지만 표시합니다. 품질이나 만족도를 뜻하지 않습니다.",
        "측정 범위 — 0.2.2부터 발생한 이벤트만 집계합니다. 그 이전의 사용 기록은 소급해서 채우지 않습니다."
    ]

    static let resetButtonLabel = "측정 초기화"
    static let resetConfirmationTitle = "측정 기록을 초기화할까요?"
    static let resetConfirmationMessage =
        "측정 이벤트와 측정 시작 시점만 삭제합니다. 프로젝트, 회의, Agent 기록, 예약된 알림은 그대로 유지됩니다. 삭제한 측정 기록은 복구할 수 없습니다."
    static let resetFailure = "측정 기록을 초기화하지 못했습니다. 기존 측정 기록은 유지됩니다."
    static let loadFailure = "측정 결과를 불러오지 못했습니다. 저장된 프로젝트와 알림은 변경되지 않았습니다."

    static func sections(
        for summary: BetaMetricsSummary,
        dateFormatter: BetaMetricsDateFormatter = BetaMetricsDateFormatter()
    ) -> [BetaMetricsSection] {
        [
            usageSection(summary, dateFormatter: dateFormatter),
            reviewSection(summary),
            durationSection(summary),
            feedbackSection(summary)
        ]
    }

    /// Nothing has been recorded at all — distinct from "recorded, and the answer is zero".
    /// The screen says which one it is instead of letting a wall of zeros imply a measured result.
    ///
    /// An unreadable ledger is never counted as emptiness. "Nothing has been recorded anywhere" is a
    /// claim about every store this report reads, and a store that refused to answer cannot support
    /// it — so a failed feedback read keeps the screen out of the fresh-install state rather than
    /// being quietly treated as four zeroes.
    static func isFreshInstall(_ summary: BetaMetricsSummary) -> Bool {
        guard case .available(let counts) = summary.agentFeedback else {
            return false
        }
        return summary.meetingsProcessed == 0
            && summary.distinctUsageDays == 0
            && summary.reviewedProposals == 0
            && summary.durationSampleCount == 0
            && counts.values.allSatisfy { $0 == 0 }
    }

    // MARK: - Sections

    private static func usageSection(
        _ summary: BetaMetricsSummary,
        dateFormatter: BetaMetricsDateFormatter
    ) -> BetaMetricsSection {
        BetaMetricsSection(
            id: "usage",
            title: "사용",
            rows: [
                BetaMetricsRow(
                    id: "measurement-start",
                    title: "측정 시작일",
                    value: dateFormatter.string(from: summary.measurementStartedAt),
                    detail: "이 시점 이후에 기록된 이벤트만 집계합니다.",
                    isEmptyState: false
                ),
                BetaMetricsRow(
                    id: "meetings-processed",
                    title: "성공한 회의 처리 수",
                    value: "\(summary.meetingsProcessed)건",
                    detail: summary.isActivated
                        ? "활성화 기준 충족"
                        : "아직 활성화 기준에 도달하지 않았습니다.",
                    isEmptyState: summary.meetingsProcessed == 0
                ),
                BetaMetricsRow(
                    id: "distinct-usage-days",
                    title: "서로 다른 사용 날짜 수",
                    value: "\(summary.distinctUsageDays)일",
                    detail: repeatUsageDetail(summary),
                    isEmptyState: summary.distinctUsageDays == 0
                )
            ],
            note: nil
        )
    }

    /// Repeat usage is reported as the bare fact of two separate dates. It is deliberately not
    /// named as a rate of any kind: this measurement cannot see whether the user came back to the
    /// app on purpose, only that a date boundary was crossed.
    private static func repeatUsageDetail(_ summary: BetaMetricsSummary) -> String {
        if summary.distinctUsageDays == 0 {
            return "아직 기록된 사용 날짜가 없습니다."
        }
        return summary.isRepeatUsageObserved
            ? "서로 다른 날짜에 2일 이상 사용한 기록이 있습니다."
            : "서로 다른 날짜의 사용 기록이 아직 1일입니다."
    }

    private static func reviewSection(_ summary: BetaMetricsSummary) -> BetaMetricsSection {
        BetaMetricsSection(
            id: "review",
            title: "검토",
            rows: [
                BetaMetricsRow(
                    id: "reviewed-proposals",
                    title: "검토 완료 proposal 수",
                    value: "\(summary.reviewedProposals)건",
                    detail: "승인 \(summary.approvedCount)건 · 제외 \(summary.excludedCount)건",
                    isEmptyState: summary.reviewedProposals == 0
                ),
                rateRow(
                    id: "approval-rate",
                    title: "승인율",
                    rate: summary.approvalRate,
                    numeratorLabel: "승인 \(summary.approvedCount)건",
                    denominatorLabel: "검토 완료 \(summary.reviewedProposals)건"
                ),
                BetaMetricsRow(
                    id: "modified-proposals",
                    title: "수정된 proposal 수",
                    value: "\(summary.modifiedProposals)건",
                    detail: "승인 전에 내용을 고친 제안의 수입니다.",
                    isEmptyState: summary.modifiedProposals == 0
                ),
                rateRow(
                    id: "modification-rate",
                    title: "수정률",
                    rate: summary.modificationRate,
                    numeratorLabel: "수정 \(summary.modifiedProposals)건",
                    denominatorLabel: "검토 완료 \(summary.reviewedProposals)건"
                )
            ],
            note: nil
        )
    }

    private static func durationSection(_ summary: BetaMetricsSummary) -> BetaMetricsSection {
        let median = durationText(summary.medianDurationMilliseconds)
        return BetaMetricsSection(
            id: "duration",
            title: "처리 시간",
            rows: [
                BetaMetricsRow(
                    id: "duration-samples",
                    title: "처리 시간 표본 수",
                    value: "\(summary.durationSampleCount)건",
                    detail: "표본이 있을 때만 대표값을 계산합니다.",
                    isEmptyState: summary.durationSampleCount == 0
                ),
                BetaMetricsRow(
                    id: "duration-median",
                    title: "처리 시간 대표값(중앙값)",
                    value: median,
                    detail: median == emptyDurationValue
                        ? "표본 \(summary.durationSampleCount)건 · 대표값을 계산하지 않았습니다."
                        : "표본 \(summary.durationSampleCount)건",
                    isEmptyState: median == emptyDurationValue
                )
            ],
            note: "평균이 아니라 중앙값입니다."
        )
    }

    /// The one section that can fail on its own. The feedback lives in the reminder ledger, a store
    /// this report only borrows, so it is the one number that can be missing while everything above
    /// it is sound — and it says so rather than showing zeroes it did not measure.
    private static func feedbackSection(_ summary: BetaMetricsSummary) -> BetaMetricsSection {
        guard case .available = summary.agentFeedback else {
            return BetaMetricsSection(
                id: "feedback",
                title: "Agent 알림 피드백",
                rows: [
                    BetaMetricsRow(
                        id: "feedback-unavailable",
                        title: "피드백 기록",
                        value: feedbackUnavailableValue,
                        detail: "0건이라는 뜻이 아닙니다. 위의 측정값은 그대로 유효합니다.",
                        isEmptyState: true
                    )
                ],
                note: feedbackUnavailableNote
            )
        }

        return BetaMetricsSection(
            id: "feedback",
            title: "Agent 알림 피드백",
            rows: AgentLedgerFeedback.allCases.map { choice in
                // Every category is rendered even at zero. A distribution that hides its empty
                // categories reads as if nobody could have chosen them.
                let count = summary.agentFeedbackCount(choice) ?? 0
                return BetaMetricsRow(
                    id: "feedback-\(choice.rawValue)",
                    title: choice.label,
                    value: "\(count)건",
                    detail: nil,
                    isEmptyState: count == 0
                )
            },
            note: "사용자가 직접 남긴 선택만 셉니다. 알림과 업무 완료 사이의 인과는 측정하지 않습니다."
        )
    }

    // MARK: - Formatting

    private static func rateRow(
        id: String,
        title: String,
        rate: Double?,
        numeratorLabel: String,
        denominatorLabel: String
    ) -> BetaMetricsRow {
        let text = rateText(rate)
        return BetaMetricsRow(
            id: id,
            title: title,
            value: text,
            detail: text == emptyRateValue
                ? "\(denominatorLabel) · 분모가 0이라 계산하지 않았습니다."
                : "\(numeratorLabel) / \(denominatorLabel)",
            isEmptyState: text == emptyRateValue
        )
    }

    /// A `nil` rate — or a non-finite one — is unknown, and unknown is never rendered as a number.
    static func rateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return emptyRateValue }
        let percent = (rate * 1_000).rounded() / 10
        if percent == percent.rounded() {
            return "\(Int(percent))%"
        }
        return String(format: "%.1f%%", percent)
    }

    /// Guards zero as well as `nil`: a median of zero cannot be a real measurement of work the user
    /// waited through, so rendering "0ms" would present a broken sample as a fast one.
    static func durationText(_ milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds > 0 else { return emptyDurationValue }
        if milliseconds < 1_000 {
            return "\(milliseconds)ms"
        }
        let totalSeconds = Double(milliseconds) / 1_000
        if totalSeconds < 60 {
            return String(format: "%.1f초", totalSeconds)
        }
        let rounded = Int(totalSeconds.rounded())
        return "\(rounded / 60)분 \(rounded % 60)초"
    }
}

struct BetaMetricsDateFormatter: Sendable {
    let locale: Locale
    let timeZone: TimeZone

    init(
        locale: Locale = Locale(identifier: "ko_KR"),
        timeZone: TimeZone = .current
    ) {
        self.locale = locale
        self.timeZone = timeZone
    }

    func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy년 M월 d일"
        return formatter.string(from: date)
    }
}
