import XCTest
@testable import HAENA

/// The 베타 측정 screen's job is to be believable, so these tests are mostly about what it refuses
/// to say: a rate with no denominator, a duration with no sample, a zero that looks measured, or a
/// sentence that turns a recorded local fact into a claim about what a notification achieved.
final class BetaMetricsPresentationTests: XCTestCase {
    private let startedAt = Date(timeIntervalSince1970: 1_786_358_400)
    private let utcFormatter = BetaMetricsDateFormatter(timeZone: TimeZone(identifier: "UTC")!)

    // MARK: - Rates

    func testApprovalRateShowsItsNumeratorAndDenominator() {
        let summary = makeSummary(
            reviewedProposals: 8,
            approvedCount: 5,
            excludedCount: 3,
            approvalRate: 5.0 / 8.0
        )

        let row = row("approval-rate", in: summary)

        XCTAssertEqual(row?.value, "62.5%")
        XCTAssertEqual(row?.detail, "승인 5건 / 검토 완료 8건")
        XCTAssertEqual(row?.isEmptyState, false)
    }

    func testModificationRateShowsItsNumeratorAndDenominator() {
        let summary = makeSummary(
            reviewedProposals: 8,
            approvedCount: 8,
            approvalRate: 1,
            modifiedProposals: 2,
            modificationRate: 0.25
        )

        let row = row("modification-rate", in: summary)

        XCTAssertEqual(row?.value, "25%")
        XCTAssertEqual(row?.detail, "수정 2건 / 검토 완료 8건")
    }

    func testEveryPercentageIsAccompaniedByItsCounts() {
        let summary = makeSummary(
            meetingsProcessed: 3,
            reviewedProposals: 8,
            approvedCount: 5,
            excludedCount: 3,
            approvalRate: 5.0 / 8.0,
            modifiedProposals: 2,
            modificationRate: 0.25
        )

        let percentageRows = allRows(of: summary).filter { $0.value.contains("%") }

        XCTAssertFalse(percentageRows.isEmpty)
        for row in percentageRows {
            XCTAssertTrue(
                row.detail?.contains("/") == true,
                "\(row.id)의 비율이 분자·분모 없이 표시되었습니다."
            )
        }
    }

    func testNilApprovalRateRendersAnEmptyStateRatherThanZeroPercent() {
        let summary = makeSummary(reviewedProposals: 0, approvalRate: nil)

        let row = row("approval-rate", in: summary)

        XCTAssertEqual(row?.value, "표본 없음")
        XCTAssertEqual(row?.isEmptyState, true)
        XCTAssertFalse(row?.value.contains("0%") == true)
        XCTAssertEqual(row?.detail, "검토 완료 0건 · 분모가 0이라 계산하지 않았습니다.")
    }

    func testNilModificationRateRendersAnEmptyStateRatherThanZeroPercent() {
        let summary = makeSummary(reviewedProposals: 0, modificationRate: nil)

        let row = row("modification-rate", in: summary)

        XCTAssertEqual(row?.value, "표본 없음")
        XCTAssertFalse(row?.value.contains("%") == true)
    }

    func testMeasuredZeroPercentIsStillReportedWithItsDenominator() {
        let summary = makeSummary(
            reviewedProposals: 4,
            approvedCount: 0,
            excludedCount: 4,
            approvalRate: 0
        )

        let row = row("approval-rate", in: summary)

        XCTAssertEqual(row?.value, "0%")
        XCTAssertEqual(row?.detail, "승인 0건 / 검토 완료 4건")
        XCTAssertEqual(row?.isEmptyState, false)
    }

    func testNonFiniteRateIsTreatedAsUnknown() {
        XCTAssertEqual(BetaMetricsDisplay.rateText(Double.nan), "표본 없음")
        XCTAssertEqual(BetaMetricsDisplay.rateText(Double.infinity), "표본 없음")
    }

    // MARK: - Duration

    func testNilMedianRendersDataUnavailableRatherThanZeroMilliseconds() {
        let summary = makeSummary(durationSampleCount: 0, medianDurationMilliseconds: nil)

        let row = row("duration-median", in: summary)

        XCTAssertEqual(row?.value, "데이터 없음")
        XCTAssertFalse(row?.value.contains("0ms") == true)
        XCTAssertEqual(row?.isEmptyState, true)
        XCTAssertEqual(row?.detail, "표본 0건 · 대표값을 계산하지 않았습니다.")
    }

    func testZeroMedianIsNotPresentedAsAFastResult() {
        XCTAssertEqual(BetaMetricsDisplay.durationText(0), "데이터 없음")
        XCTAssertEqual(BetaMetricsDisplay.durationText(-1), "데이터 없음")
    }

    func testMedianAlwaysCarriesItsSampleCount() {
        let summary = makeSummary(durationSampleCount: 12, medianDurationMilliseconds: 65_400)

        let row = row("duration-median", in: summary)

        XCTAssertEqual(row?.value, "1분 5초")
        XCTAssertEqual(row?.detail, "표본 12건")
    }

    func testDurationFormatsStayReadableAcrossScales() {
        XCTAssertEqual(BetaMetricsDisplay.durationText(420), "420ms")
        XCTAssertEqual(BetaMetricsDisplay.durationText(2_500), "2.5초")
        XCTAssertEqual(BetaMetricsDisplay.durationText(600_000), "10분 0초")
    }

    // MARK: - Empty states

    func testZeroSampleRowsAreMarkedAsEmptyRatherThanMeasured() {
        let summary = makeSummary()

        let ids = allRows(of: summary).filter(\.isEmptyState).map(\.id)

        XCTAssertTrue(ids.contains("meetings-processed"))
        XCTAssertTrue(ids.contains("distinct-usage-days"))
        XCTAssertTrue(ids.contains("reviewed-proposals"))
        XCTAssertTrue(ids.contains("duration-samples"))
        XCTAssertTrue(ids.contains("duration-median"))
    }

    /// An unreadable ledger must never be laundered into "nobody had an opinion". The section says
    /// it could not be loaded, and says so instead of a count rather than beside one.
    func testAnUnavailableLedgerIsReportedAsSuchRatherThanAsZeroes() {
        let summary = makeSummary(agentFeedback: .unavailable)

        let section = BetaMetricsDisplay.sections(for: summary, dateFormatter: utcFormatter)
            .first { $0.id == "feedback" }

        XCTAssertEqual(section?.rows.count, 1, "No per-category rows are invented")
        XCTAssertEqual(section?.rows.first?.value, BetaMetricsDisplay.feedbackUnavailableValue)
        XCTAssertEqual(section?.note, BetaMetricsDisplay.feedbackUnavailableNote)
        for row in section?.rows ?? [] {
            XCTAssertFalse(row.value.contains("건"), "No count is shown for evidence never gathered")
        }
        XCTAssertTrue(
            (section?.note ?? "").contains("아무도 피드백을 남기지 않았다는 뜻이 아닙니다"),
            "The misreading this state exists to prevent is denied explicitly"
        )
    }

    /// The rest of the report stands on its own store, so a ledger failure must not blank it out.
    func testTheMetricsBodyStillRendersWhenTheLedgerIsUnavailable() {
        let summary = makeSummary(
            meetingsProcessed: 3,
            distinctUsageDays: 2,
            isRepeatUsageObserved: true,
            reviewedProposals: 4,
            approvedCount: 3,
            excludedCount: 1,
            approvalRate: 0.75,
            durationSampleCount: 2,
            medianDurationMilliseconds: 5_000,
            agentFeedback: .unavailable
        )

        XCTAssertEqual(row("meetings-processed", in: summary)?.value, "3건")
        XCTAssertEqual(row("approval-rate", in: summary)?.value, "75%")
        XCTAssertEqual(row("approval-rate", in: summary)?.detail, "승인 3건 / 검토 완료 4건")
        XCTAssertEqual(row("duration-median", in: summary)?.value, "5.0초")
        XCTAssertEqual(row("distinct-usage-days", in: summary)?.value, "2일")
    }

    /// A store that has recorded nothing *and* a ledger that could not be read is not a clean
    /// machine — it is a machine one of whose stores never answered. Calling it a fresh install
    /// would assert emptiness on evidence that was never collected.
    func testAnUnavailableLedgerIsNotTreatedAsAFreshInstall() {
        XCTAssertTrue(BetaMetricsDisplay.isFreshInstall(makeSummary()))
        XCTAssertFalse(
            BetaMetricsDisplay.isFreshInstall(makeSummary(agentFeedback: .unavailable)),
            "An unread store cannot support a claim that nothing has been recorded anywhere"
        )
    }

    func testFreshInstallIsDistinguishedFromAMeasuredZero() {
        XCTAssertTrue(BetaMetricsDisplay.isFreshInstall(makeSummary()))
        XCTAssertFalse(
            BetaMetricsDisplay.isFreshInstall(makeSummary(meetingsProcessed: 1, distinctUsageDays: 1))
        )
        XCTAssertFalse(
            BetaMetricsDisplay.isFreshInstall(
                makeSummary(agentFeedback: .available([.helpful: 1]))
            )
        )
    }

    func testFreshInstallStillShowsTheMeasurementStartDate() {
        let summary = makeSummary()

        let row = row("measurement-start", in: summary)

        XCTAssertEqual(row?.value, "2026년 8월 10일")
        XCTAssertEqual(row?.isEmptyState, false)
    }

    func testUsageDaysNeverImplyRepeatUsageWhenNothingWasRecorded() {
        XCTAssertEqual(
            row("distinct-usage-days", in: makeSummary())?.detail,
            "아직 기록된 사용 날짜가 없습니다."
        )
        XCTAssertEqual(
            row("distinct-usage-days", in: makeSummary(distinctUsageDays: 1))?.detail,
            "서로 다른 날짜의 사용 기록이 아직 1일입니다."
        )
        XCTAssertEqual(
            row(
                "distinct-usage-days",
                in: makeSummary(distinctUsageDays: 2, isRepeatUsageObserved: true)
            )?.detail,
            "서로 다른 날짜에 2일 이상 사용한 기록이 있습니다."
        )
    }

    // MARK: - Feedback distribution

    func testFeedbackDistributionRendersEveryCategoryIncludingZeros() {
        let summary = makeSummary(agentFeedback: .available([.helpful: 3, .tooLate: 1]))

        let section = BetaMetricsDisplay.sections(for: summary, dateFormatter: utcFormatter)
            .first { $0.id == "feedback" }

        XCTAssertEqual(
            section?.rows.map(\.id),
            ["feedback-helpful", "feedback-tooEarly", "feedback-tooLate", "feedback-unnecessary"]
        )
        XCTAssertEqual(section?.rows.map(\.value), ["3건", "0건", "1건", "0건"])
        XCTAssertEqual(section?.rows.map(\.title), AgentLedgerFeedback.allCases.map(\.label))
    }

    // MARK: - Copy

    func testCriteriaExplainEachCountAndTheMeasurementWindow() {
        let criteria = BetaMetricsDisplay.criteriaParagraphs.joined(separator: "\n")

        XCTAssertEqual(BetaMetricsDisplay.criteriaTitle, "측정 기준")
        XCTAssertTrue(criteria.contains("0.2.2"))
        XCTAssertTrue(criteria.contains("승인율의 분자는 승인 수, 분모는 검토 완료 수"))
        XCTAssertTrue(criteria.contains("수정률 — 분자는 승인 전에"))
        XCTAssertTrue(criteria.contains("분모는 검토 완료 proposal 수"))
        XCTAssertTrue(criteria.contains("중앙값"))
    }

    func testCopyNeverOverclaimsRepeatUsageOrNotificationCausation() {
        let forbidden = ["재방문", "유지율", "리텐션", "retention", "덕분", "때문에", "읽었", "효과"]

        for text in allCopy() {
            for phrase in forbidden {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(phrase),
                    "'\(phrase)'이(가) 다음 문구에 있습니다: \(text)"
                )
            }
        }
    }

    func testNotificationFactsAreStatedAsLocalRecordsOnly() {
        let criteria = BetaMetricsDisplay.criteriaParagraphs.joined(separator: "\n")

        XCTAssertTrue(criteria.contains("사람이 알림을 봤다는 보장은 아닙니다"))
        XCTAssertTrue(criteria.contains("인과는 측정하지 않습니다"))
    }

    func testPrivacyLineStatesLocalOnlyStorageWithoutNames() {
        let note = BetaMetricsDisplay.privacyNote

        XCTAssertTrue(note.contains("이 Mac 안에서만"))
        XCTAssertTrue(note.contains("전사 원문"))
        XCTAssertTrue(note.contains("참석자 이름"))
        XCTAssertTrue(note.contains("전송하지 않습니다"))
    }

    func testResetConfirmationNamesExactlyWhatSurvives() {
        let message = BetaMetricsDisplay.resetConfirmationMessage

        XCTAssertTrue(message.contains("측정 이벤트와 측정 시작 시점만 삭제합니다"))
        XCTAssertTrue(message.contains("프로젝트"))
        XCTAssertTrue(message.contains("회의"))
        XCTAssertTrue(message.contains("Agent 기록"))
        XCTAssertTrue(message.contains("예약된 알림"))
        XCTAssertTrue(message.contains("유지됩니다"))
    }

    // MARK: - Helpers

    private func allCopy() -> [String] {
        let summary = makeSummary(
            meetingsProcessed: 3,
            isActivated: true,
            distinctUsageDays: 2,
            isRepeatUsageObserved: true,
            reviewedProposals: 8,
            approvedCount: 5,
            excludedCount: 3,
            approvalRate: 5.0 / 8.0,
            modifiedProposals: 2,
            modificationRate: 0.25,
            durationSampleCount: 4,
            medianDurationMilliseconds: 12_000,
            agentFeedback: .available([.helpful: 2])
        )
        let sectionCopy = BetaMetricsDisplay.sections(for: summary, dateFormatter: utcFormatter)
            .flatMap { section -> [String] in
                [section.title, section.note].compactMap { $0 }
                    + section.rows.flatMap { [$0.title, $0.value, $0.detail].compactMap { $0 } }
            }
        return sectionCopy
            + BetaMetricsDisplay.criteriaParagraphs
            + [
                BetaMetricsDisplay.screenTitle,
                BetaMetricsDisplay.privacyNote,
                BetaMetricsDisplay.summaryNote,
                BetaMetricsDisplay.freshInstallTitle,
                BetaMetricsDisplay.freshInstallMessage,
                BetaMetricsDisplay.criteriaTitle,
                BetaMetricsDisplay.showCriteriaLabel,
                BetaMetricsDisplay.hideCriteriaLabel,
                BetaMetricsDisplay.resetButtonLabel,
                BetaMetricsDisplay.resetConfirmationTitle,
                BetaMetricsDisplay.resetConfirmationMessage,
                BetaMetricsDisplay.resetFailure,
                BetaMetricsDisplay.loadFailure,
                BetaMetricsDisplay.emptyRateValue,
                BetaMetricsDisplay.emptyDurationValue
            ]
    }

    private func allRows(of summary: BetaMetricsSummary) -> [BetaMetricsRow] {
        BetaMetricsDisplay.sections(for: summary, dateFormatter: utcFormatter).flatMap(\.rows)
    }

    private func row(_ id: String, in summary: BetaMetricsSummary) -> BetaMetricsRow? {
        allRows(of: summary).first { $0.id == id }
    }

    private func makeSummary(
        meetingsProcessed: Int = 0,
        isActivated: Bool = false,
        distinctUsageDays: Int = 0,
        isRepeatUsageObserved: Bool = false,
        reviewedProposals: Int = 0,
        approvedCount: Int = 0,
        excludedCount: Int = 0,
        approvalRate: Double? = nil,
        modifiedProposals: Int = 0,
        modificationRate: Double? = nil,
        durationSampleCount: Int = 0,
        medianDurationMilliseconds: Int? = nil,
        agentFeedback: BetaMetricsFeedback = .available([:])
    ) -> BetaMetricsSummary {
        BetaMetricsSummary(
            measurementStartedAt: startedAt,
            meetingsProcessed: meetingsProcessed,
            isActivated: isActivated,
            distinctUsageDays: distinctUsageDays,
            isRepeatUsageObserved: isRepeatUsageObserved,
            reviewedProposals: reviewedProposals,
            approvedCount: approvedCount,
            excludedCount: excludedCount,
            approvalRate: approvalRate,
            modifiedProposals: modifiedProposals,
            modificationRate: modificationRate,
            durationSampleCount: durationSampleCount,
            medianDurationMilliseconds: medianDurationMilliseconds,
            agentFeedback: agentFeedback
        )
    }
}
