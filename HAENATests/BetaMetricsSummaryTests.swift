import XCTest
@testable import HAENA

/// Covers the reading half: what the beta report actually claims, and the ways a plausible-looking
/// aggregation would quietly claim something else.
///
/// Every case pins the measurement start and the calendar, so what falls inside the period and what
/// counts as a day never depend on when or where the suite runs.
final class BetaMetricsSummaryTests: XCTestCase {
    private static let measurementStart = BetaMetricsSummaryTests.utc(month: 11, day: 1, hour: 0)

    private static let projectID = UUID(uuidString: "32000000-0000-0000-0000-000000000001")!
    private static let reminderID = UUID(uuidString: "32000000-0000-0000-0000-000000000002")!
    private static let actionItemID = UUID(uuidString: "32000000-0000-0000-0000-000000000003")!

    /// UTC+9, no daylight saving — a fixed offset, so a day boundary case cannot be explained away
    /// by a clock change.
    private static var seoulCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }

    private static func utc(month: Int, day: Int, hour: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: 2023, month: month, day: day, hour: hour))!
    }

    // MARK: - The measurement period

    /// A stored fact from before the period began describes something the report does not claim to
    /// cover — a measurement restarted last week cannot be justified by numbers from last month.
    /// The boundary itself is inclusive: the instant the period starts is inside it.
    func testFactsFromBeforeTheMeasurementStartedAreNotAggregated() {
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                meetingProcessed(1, at: Self.measurementStart.addingTimeInterval(-1)),
                meetingProcessed(2, at: Self.measurementStart),
                meetingProcessed(3, at: Self.measurementStart.addingTimeInterval(3_600)),
                reviewed(4, verdict: .approved, at: Self.measurementStart.addingTimeInterval(-86_400))
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)

        XCTAssertEqual(summary.meetingsProcessed, 2, "The one a second early is outside the period")
        XCTAssertEqual(summary.reviewedProposals, 0)
        XCTAssertNil(summary.approvalRate, "A verdict from the previous period is not evidence about this one")
        XCTAssertEqual(summary.measurementStartedAt, Self.measurementStart)
    }

    // MARK: - What counts as a day

    /// Two instants inside the same UTC day that fall on different days where the user lives. The
    /// user worked on Tuesday evening and again on Wednesday morning; a report computed in UTC would
    /// tell them they only ever used the app once, and the repeat-usage claim would be wrong.
    func testTwoInstantsInOneUTCDayAreTwoDaysInTheUsersOwnCalendar() {
        let tuesdayEvening = Self.utc(month: 11, day: 14, hour: 10)   // 19:00 KST, 14 Nov
        let wednesdayMorning = Self.utc(month: 11, day: 14, hour: 20) // 05:00 KST, 15 Nov
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [meetingProcessed(1, at: tuesdayEvening), meetingProcessed(2, at: wednesdayMorning)]
        )

        let local = BetaMetricsSummary(store: store, calendar: Self.seoulCalendar)
        XCTAssertEqual(local.distinctUsageDays, 2)
        XCTAssertTrue(local.isRepeatUsageObserved)

        let utc = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(utc.distinctUsageDays, 1, "Same instants, and the injected calendar is what decides")
        XCTAssertFalse(utc.isRepeatUsageObserved)
    }

    /// The mirror image: two instants on different UTC days that are one single day to the user. A
    /// UTC report would claim a returning user out of one long evening's work.
    func testTwoInstantsAcrossTwoUTCDaysAreOneDayInTheUsersOwnCalendar() {
        let wednesdayEarly = Self.utc(month: 11, day: 14, hour: 20) // 05:00 KST, 15 Nov
        let wednesdayLate = Self.utc(month: 11, day: 15, hour: 2)   // 11:00 KST, 15 Nov
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [meetingProcessed(1, at: wednesdayEarly), meetingProcessed(2, at: wednesdayLate)]
        )

        let local = BetaMetricsSummary(store: store, calendar: Self.seoulCalendar)
        XCTAssertEqual(local.distinctUsageDays, 1)
        XCTAssertFalse(local.isRepeatUsageObserved, "One evening is not a habit")

        let utc = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(utc.distinctUsageDays, 2)
    }

    /// Only the act of processing a meeting marks a usage day. Reviewing yesterday's proposals this
    /// morning is tidying up, not a second day of getting work into the app.
    func testOnlyProcessingAMeetingMarksAUsageDay() {
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                meetingProcessed(1, at: Self.utc(month: 11, day: 14, hour: 1)),
                reviewed(2, verdict: .approved, at: Self.utc(month: 11, day: 20, hour: 1)),
                modified(3, at: Self.utc(month: 11, day: 21, hour: 1)),
                duration(4, milliseconds: 100, at: Self.utc(month: 11, day: 22, hour: 1))
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.seoulCalendar)
        XCTAssertEqual(summary.distinctUsageDays, 1)
        XCTAssertFalse(summary.isRepeatUsageObserved)
    }

    // MARK: - Activation

    /// Activation is the user getting one meeting all the way through. Everything that happens
    /// before that — launching, making a project, poking at the UI — leaves no `meetingProcessed`
    /// fact, and so can never add up to activation.
    func testActivationRequiresAProcessedMeetingAndNothingElseSubstitutesForIt() {
        let withoutAMeeting = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                duration(1, milliseconds: 500, outcome: .failed, at: Self.measurementStart),
                reviewed(2, verdict: .approved, at: Self.measurementStart),
                modified(3, at: Self.measurementStart)
            ]
        )
        XCTAssertFalse(BetaMetricsSummary(store: withoutAMeeting, calendar: Self.utcCalendar).isActivated)

        let withOne = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [meetingProcessed(4, at: Self.measurementStart)]
        )
        let activated = BetaMetricsSummary(store: withOne, calendar: Self.utcCalendar)
        XCTAssertTrue(activated.isActivated)
        XCTAssertEqual(activated.meetingsProcessed, 1)
    }

    // MARK: - Approval

    /// The denominator is what a person judged, never what the app produced. A proposal still
    /// waiting has no event at all, so there is nothing to exclude it from — that is the whole point
    /// of recording verdicts rather than counting proposals.
    func testProposalsStillAwaitingAVerdictAreAbsentFromTheApprovalDenominator() {
        // Five proposals exist in the user's inbox. Two were judged; one of the other three had its
        // due date corrected but was never submitted, and two were not touched at all.
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                reviewed(1, verdict: .approved, at: Self.measurementStart),
                reviewed(2, verdict: .excluded, at: Self.measurementStart),
                modified(3, at: Self.measurementStart)
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.reviewedProposals, 2, "Not five")
        XCTAssertEqual(summary.approvalRate, 0.5)
        XCTAssertEqual(
            summary.modifiedProposals,
            0,
            "Edited but never judged: it would otherwise be a numerator with no matching denominator"
        )
        XCTAssertEqual(summary.modificationRate, 0.0)
    }

    /// A verdict means the same thing whichever of the four proposal types carries it, so one pooled
    /// rate is honest. Were `excluded` recorded only for some kinds — a deleted Decision but not a
    /// dismissed agenda item — the approval rate would measure which kinds happen to be reviewed.
    func testVerdictsAreTalliedIdenticallyAcrossAllFourProposalKinds() {
        var events: [BetaMetricEvent] = []
        var index = 0
        for kind in BetaMetricProposalKind.allCases {
            for verdict in BetaMetricVerdict.allCases {
                index += 1
                events.append(reviewed(index, verdict: verdict, kind: kind, at: Self.measurementStart))
            }
        }
        let store = BetaMetricsStoreFile(measurementStartedAt: Self.measurementStart, events: events)

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(BetaMetricProposalKind.allCases.count, 4, "All four kinds are represented above")
        XCTAssertEqual(summary.reviewedProposals, 8)
        XCTAssertEqual(summary.approvedCount, 4)
        XCTAssertEqual(summary.excludedCount, 4)
        XCTAssertEqual(summary.approvalRate, 0.5)

        // And each kind really did contribute one of each verdict.
        for kind in BetaMetricProposalKind.allCases {
            let ofKind = store.events.filter { $0.proposalKind == kind }
            XCTAssertEqual(ofKind.filter { $0.verdict == .approved }.count, 1, "\(kind)")
            XCTAssertEqual(ofKind.filter { $0.verdict == .excluded }.count, 1, "\(kind)")
        }
    }

    /// The exact claim the UI has to be able to state: of the proposals a person judged, this share
    /// needed a correction first. An excluded proposal that was corrected still counts — the user
    /// spent the effort either way.
    func testTheModificationRateIsCorrectedProposalsOverJudgedProposals() {
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                reviewed(1, verdict: .approved, at: Self.measurementStart),
                modified(1, at: Self.measurementStart),
                reviewed(2, verdict: .excluded, at: Self.measurementStart),
                modified(2, at: Self.measurementStart),
                reviewed(3, verdict: .approved, at: Self.measurementStart),
                reviewed(4, verdict: .approved, at: Self.measurementStart)
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.reviewedProposals, 4)
        XCTAssertEqual(summary.modifiedProposals, 2)
        XCTAssertEqual(summary.modificationRate, 0.5)
        XCTAssertLessThanOrEqual(summary.modificationRate ?? 0, 1.0, "A rate above 100% must be unreachable")
    }

    // MARK: - Duration

    /// The ordinary median, and never reported without the sample count beside it: "3.0 seconds"
    /// over four runs is a different claim from the same number over four hundred.
    func testTheMedianUsesTheStandardDefinitionAndIsReportedWithItsSampleCount() {
        let odd = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                duration(1, milliseconds: 5_000, at: Self.measurementStart),
                duration(2, milliseconds: 1_000, at: Self.measurementStart),
                duration(3, milliseconds: 3_000, at: Self.measurementStart)
            ]
        )
        let oddSummary = BetaMetricsSummary(store: odd, calendar: Self.utcCalendar)
        XCTAssertEqual(oddSummary.durationSampleCount, 3)
        XCTAssertEqual(oddSummary.medianDurationMilliseconds, 3_000, "Order of arrival must not matter")

        let even = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                duration(1, milliseconds: 4_000, at: Self.measurementStart),
                duration(2, milliseconds: 1_000, at: Self.measurementStart),
                duration(3, milliseconds: 9_000, at: Self.measurementStart),
                duration(4, milliseconds: 3_000, at: Self.measurementStart)
            ]
        )
        let evenSummary = BetaMetricsSummary(store: even, calendar: Self.utcCalendar)
        XCTAssertEqual(evenSummary.durationSampleCount, 4)
        XCTAssertEqual(
            evenSummary.medianDurationMilliseconds,
            3_500,
            "Arithmetic mean of the two central samples, 3,000 and 4,000"
        )
    }

    /// The definition the screen and the Notion record both state, checked directly against the
    /// sample sets rather than only through a built store.
    func testMedianDefinitionOddAndEvenAndOverflowSafety() {
        XCTAssertNil(BetaMetricsSummary.median(ofSorted: []))
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [7]), 7)
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [1, 2, 3]), 2)
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [1, 2]), 1, "Mean of 1 and 2 floors to 1")
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [2, 4]), 3)
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [1, 2, 3, 4]), 2, "Mean of 2 and 3")

        // Two durations near the top of the range. `(lower + upper) / 2` would trap on overflow
        // here; the midpoint form this uses cannot.
        let big = Int.max - 1
        XCTAssertEqual(BetaMetricsSummary.median(ofSorted: [big, big]), big)
        XCTAssertEqual(
            BetaMetricsSummary.median(ofSorted: [Int.max - 4, Int.max - 2]),
            Int.max - 3,
            "The midpoint is computed without ever forming the sum"
        )
    }

    /// A failed run is still time the user waited, so it is a sample. The outcome is kept on the
    /// event, so the two can be split later without re-running the beta.
    func testFailedRunsAreStillDurationSamples() {
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                duration(1, milliseconds: 2_000, outcome: .succeeded, at: Self.measurementStart),
                duration(2, milliseconds: 30_000, outcome: .failed, at: Self.measurementStart),
                duration(3, milliseconds: 40_000, outcome: .failed, at: Self.measurementStart)
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.durationSampleCount, 3)
        XCTAssertEqual(summary.medianDurationMilliseconds, 30_000)
        XCTAssertEqual(store.events.filter { $0.outcome == .failed }.count, 2, "Splittable after the fact")
    }

    // MARK: - Nothing measured yet

    /// The state the beta spends its first days in. Rates are nil, not zero: nobody has approved
    /// nothing — nobody has been asked yet, and "0%" on a beta report would read as a failure of the
    /// extraction rather than an absence of evidence.
    func testAnEmptyMeasurementReportsUnknownRatesRatherThanZero() {
        let summary = BetaMetricsSummary(
            store: BetaMetricsStoreFile(measurementStartedAt: Self.measurementStart, events: []),
            calendar: Self.utcCalendar
        )

        XCTAssertNil(summary.approvalRate)
        XCTAssertNil(summary.modificationRate)
        XCTAssertNil(summary.medianDurationMilliseconds)
        XCTAssertNotEqual(summary.approvalRate, 0.0, "Unknown must not be encoded as zero")
        XCTAssertNotEqual(summary.modificationRate, 0.0)
        XCTAssertNotEqual(summary.medianDurationMilliseconds, 0)

        XCTAssertEqual(summary.measurementStartedAt, Self.measurementStart)
        XCTAssertEqual(summary.meetingsProcessed, 0)
        XCTAssertFalse(summary.isActivated)
        XCTAssertEqual(summary.distinctUsageDays, 0)
        XCTAssertFalse(summary.isRepeatUsageObserved)
        XCTAssertEqual(summary.reviewedProposals, 0)
        XCTAssertEqual(summary.approvedCount, 0)
        XCTAssertEqual(summary.excludedCount, 0)
        XCTAssertEqual(summary.modifiedProposals, 0)
        XCTAssertEqual(summary.durationSampleCount, 0)
        XCTAssertEqual(summary.agentFeedback, .available([:]), "Read successfully, and genuinely empty")
        for feedback in AgentLedgerFeedback.allCases {
            XCTAssertEqual(summary.agentFeedbackCount(feedback), 0, "A UI asking for a zero gets one")
        }
    }

    /// A rate of zero is a real finding and must still be distinguishable from an unknown one: every
    /// proposal excluded is the extraction failing, and the report has to be able to say so.
    func testAGenuineZeroRateIsNotConfusedWithAnUnknownOne() {
        let store = BetaMetricsStoreFile(
            measurementStartedAt: Self.measurementStart,
            events: [
                reviewed(1, verdict: .excluded, at: Self.measurementStart),
                reviewed(2, verdict: .excluded, at: Self.measurementStart)
            ]
        )

        let summary = BetaMetricsSummary(store: store, calendar: Self.utcCalendar)
        XCTAssertEqual(summary.approvalRate, 0.0)
        XCTAssertNotNil(summary.approvalRate)
        XCTAssertEqual(summary.excludedCount, 2)
    }

    // MARK: - Reminder feedback

    /// Tallied from the reminder ledger, and only ever read from it. The window applies here too: a
    /// user who reset their measurement yesterday must not be shown last month's opinions beside
    /// this month's zero reminders.
    func testReminderFeedbackIsTalliedFromTheLedgerWithoutWritingToIt() async throws {
        let seeded = [
            ledgerFeedback(1, .helpful, at: Self.measurementStart.addingTimeInterval(60)),
            ledgerFeedback(2, .helpful, at: Self.measurementStart.addingTimeInterval(120)),
            ledgerFeedback(3, .tooEarly, at: Self.measurementStart.addingTimeInterval(180)),
            ledgerFeedback(4, .unnecessary, at: Self.measurementStart.addingTimeInterval(-60)),
            ledgerScheduled(5, at: Self.measurementStart.addingTimeInterval(240))
        ]
        let ledger = InMemoryAgentLedgerRepository(events: seeded)
        let metrics = InMemoryBetaMetricsRepository(
            measurementStartedAt: Self.measurementStart,
            events: [meetingProcessed(1, at: Self.measurementStart)]
        )
        let service = BetaMetricsService(
            repository: metrics,
            ledgerRepository: ledger,
            now: { Self.measurementStart }
        )

        let summary = try await service.summary(calendar: Self.seoulCalendar)

        XCTAssertEqual(summary.agentFeedback, .available([.helpful: 2, .tooEarly: 1]))
        XCTAssertEqual(summary.agentFeedbackCount(.helpful), 2)
        XCTAssertEqual(summary.agentFeedbackCount(.tooEarly), 1)
        XCTAssertEqual(summary.agentFeedbackCount(.tooLate), 0, "Read, and nobody chose it")
        XCTAssertEqual(
            summary.agentFeedbackCount(.unnecessary),
            0,
            "Given before the measurement began, so it belongs to the previous period"
        )

        let afterwards = await ledger.events(limit: nil)
        XCTAssertEqual(
            afterwards.sorted { $0.id.uuidString < $1.id.uuidString },
            seeded.sorted { $0.id.uuidString < $1.id.uuidString },
            "The ledger is another feature's store; reading a report must not disturb it"
        )
    }

    /// With no ledger wired up at all the report still stands on its own numbers.
    func testTheReportWorksWithoutAReminderLedger() async throws {
        let service = BetaMetricsService(
            repository: InMemoryBetaMetricsRepository(
                measurementStartedAt: Self.measurementStart,
                events: [meetingProcessed(1, at: Self.measurementStart)]
            ),
            now: { Self.measurementStart }
        )

        let summary = try await service.summary(calendar: Self.seoulCalendar)
        XCTAssertEqual(summary.meetingsProcessed, 1)
        XCTAssertEqual(
            summary.agentFeedback,
            .available([:]),
            "No ledger wired up is a true 'no feedback', not a failed read"
        )
    }

    // MARK: - Fixtures

    private func meetingProcessed(_ index: Int, at date: Date) -> BetaMetricEvent {
        BetaMetricEvent(
            id: Self.id("32000001", index),
            deduplicationKey: "meetingProcessed:\(Self.id("32000002", index).uuidString.lowercased())",
            type: .meetingProcessed,
            occurredAt: date,
            projectID: Self.projectID,
            meetingID: Self.id("32000002", index),
            captureSource: .recordedAudio,
            resultCount: 4
        )
    }

    private func reviewed(
        _ index: Int,
        verdict: BetaMetricVerdict,
        kind: BetaMetricProposalKind = .actionItem,
        at date: Date
    ) -> BetaMetricEvent {
        BetaMetricEvent(
            id: Self.id("32000003", index),
            deduplicationKey: "proposalReviewed:\(Self.id("32000004", index).uuidString.lowercased())",
            type: .proposalReviewed,
            occurredAt: date,
            projectID: Self.projectID,
            proposalID: Self.id("32000004", index),
            proposalKind: kind,
            verdict: verdict
        )
    }

    /// Shares `index` with `reviewed(_:verdict:kind:at:)` so the same index means the same proposal —
    /// which is what the modification rate's join is about.
    private func modified(_ index: Int, at date: Date) -> BetaMetricEvent {
        BetaMetricEvent(
            id: Self.id("32000005", index),
            deduplicationKey: "proposalModified:\(Self.id("32000004", index).uuidString.lowercased())",
            type: .proposalModified,
            occurredAt: date,
            projectID: Self.projectID,
            proposalID: Self.id("32000004", index),
            proposalKind: .actionItem,
            fieldCategory: .dueDate
        )
    }

    private func duration(
        _ index: Int,
        milliseconds: Int,
        outcome: BetaMetricOutcome = .succeeded,
        at date: Date
    ) -> BetaMetricEvent {
        BetaMetricEvent(
            id: Self.id("32000006", index),
            deduplicationKey: "processingDuration:\(Self.id("32000007", index).uuidString.lowercased())",
            type: .processingDuration,
            occurredAt: date,
            meetingID: outcome == .succeeded ? Self.id("32000002", index) : nil,
            captureSource: .importedAudio,
            outcome: outcome,
            durationMilliseconds: milliseconds
        )
    }

    private func ledgerFeedback(_ index: Int, _ value: AgentLedgerFeedback, at date: Date) -> AgentLedgerEvent {
        AgentLedgerEvent(
            id: Self.id("32000008", index),
            deduplicationKey: "feedback:\(Self.id("32000009", index).uuidString.lowercased())",
            reminderID: Self.id("32000009", index),
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            type: .feedback,
            occurredAt: date,
            feedback: value
        )
    }

    private func ledgerScheduled(_ index: Int, at date: Date) -> AgentLedgerEvent {
        AgentLedgerEvent(
            id: Self.id("32000008", index),
            deduplicationKey: "scheduled:\(Self.id("32000009", index).uuidString.lowercased())",
            reminderID: Self.reminderID,
            projectID: Self.projectID,
            actionItemID: Self.actionItemID,
            type: .scheduled,
            occurredAt: date,
            scheduledFor: date.addingTimeInterval(3_600)
        )
    }

    private static func id(_ prefix: String, _ index: Int) -> UUID {
        UUID(uuidString: "\(prefix)-0000-0000-0000-\(String(format: "%012d", index))")!
    }
}
