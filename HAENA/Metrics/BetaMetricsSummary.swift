import Foundation

/// What the reminder ledger had to say, or that it could not be asked.
///
/// Modelled rather than flattened to a count, because "nobody left feedback" and "the feedback store
/// could not be read" are opposite facts that a bare `[:]` renders identically. The first is a
/// finding about the product; the second is a defect in this report, and showing it as zeroes would
/// invite a decision based on evidence that was never actually gathered.
enum BetaMetricsFeedback: Equatable, Sendable {
    /// Read successfully. An empty dictionary here genuinely means nobody chose anything.
    case available([AgentLedgerFeedback: Int])
    /// The ledger could not be read. Nothing is claimed about what it contains.
    case unavailable
}

/// The result of reading the reminder ledger, handed to the summary so the aggregation stays a pure
/// function and the "could not read" case is testable without provoking real I/O failures.
enum BetaMetricsLedgerRead: Equatable, Sendable {
    case read([AgentLedgerEvent])
    case unavailable
}

/// Everything the private beta report states, derived from stored facts and nothing else.
///
/// Two shapes recur and both are deliberate. Rates are optional: a rate with no denominator is not
/// zero, it is unknown, and reporting `0.0` would read as "nobody approved anything" when the truth
/// is "nobody has reviewed anything yet". Counts sit beside every rate for the same reason — a 100%
/// approval rate over two proposals is a different claim from the same rate over two hundred, and
/// the beta will spend most of its life in the first case.
struct BetaMetricsSummary: Equatable, Sendable {
    /// The instant the current measurement period began. Every number below describes this period
    /// only; a reset moves this forward and the numbers start again from nothing.
    let measurementStartedAt: Date

    /// Meetings that reached a result, counted once each however many times processing was retried.
    let meetingsProcessed: Int
    /// Activation: the user got at least one meeting all the way through the app. Launching it and
    /// creating a project are not activation — those are things a person does before finding out
    /// whether the app works at all.
    let isActivated: Bool
    /// Distinct *local* calendar days on which a meeting was processed.
    let distinctUsageDays: Int
    /// Returning to the app on a second day is the smallest honest evidence of habit; anything less
    /// is one session that could have been curiosity.
    let isRepeatUsageObserved: Bool

    /// Proposals a person gave a verdict on. Pending proposals are absent, not zero — they have no
    /// event at all until judged, so they can never sit in a denominator.
    let reviewedProposals: Int
    let approvedCount: Int
    let excludedCount: Int
    /// `approvedCount / (approvedCount + excludedCount)`, or nil when nothing has been reviewed.
    let approvalRate: Double?

    /// Proposals that were both edited and reviewed. See `modificationRate` for why the two
    /// conditions are joined.
    let modifiedProposals: Int
    /// `modifiedProposals / reviewedProposals`, or nil when nothing has been reviewed.
    ///
    /// The exact claim, which the UI has to be able to state: *of the proposals a person judged,
    /// this share needed a correction to an assignee or a due date first.* Counting a proposal
    /// edited but never judged would put a number in the numerator that is missing from the
    /// denominator, and a rate above 100% would eventually appear on screen.
    let modificationRate: Double?

    let durationSampleCount: Int
    /// The median observed run time in milliseconds, or nil when nothing has been timed.
    ///
    /// The standard definition: the middle sample for an odd count, and the arithmetic mean of the
    /// two central samples for an even one. `durationSampleCount` is always reported beside it, so
    /// the reader can see how little the median is standing on.
    let medianDurationMilliseconds: Int?

    /// Reminder feedback tallied from `AgentLedgerRepository`, read-only — or the fact that the
    /// ledger could not be read at all.
    let agentFeedback: BetaMetricsFeedback

    var isAgentFeedbackAvailable: Bool {
        if case .available = agentFeedback { return true }
        return false
    }

    /// Zero for a value nobody chose, so a UI can lay out all four rows without deciding what an
    /// absent key means — and **nil when the ledger could not be read**, so a caller cannot print a
    /// zero it has no evidence for.
    func agentFeedbackCount(_ feedback: AgentLedgerFeedback) -> Int? {
        guard case .available(let counts) = agentFeedback else { return nil }
        return counts[feedback] ?? 0
    }
}

extension BetaMetricsSummary {
    /// The whole aggregation, as a pure function of stored facts, an injected calendar and nothing
    /// else — no clock, no locale lookup, no I/O. That is what lets the timezone rules below be
    /// tested at all.
    ///
    /// `calendar` decides what a day is. It must be the user's own calendar: a meeting processed at
    /// 08:00 KST is Tuesday's work to the person who did it, whatever UTC calls it, and a "used it
    /// on two days" claim computed in the wrong zone is simply false.
    ///
    /// `agentLedger` comes from the reminder ledger and is only ever read. This type never writes
    /// to, reorders, or reinterprets that store — and when the read failed it says so rather than
    /// tallying an absence it never observed.
    init(
        store: BetaMetricsStoreFile,
        agentLedger: BetaMetricsLedgerRead = .read([]),
        calendar: Calendar
    ) {
        let start = store.measurementStartedAt
        // A fact from before the measurement began describes a period the report does not claim to
        // cover. `reset(at:)` drops such events outright; this filter is what makes a store that
        // still holds one — hand-edited, or written by a clock that moved backwards — harmless.
        let events = store.events.filter { $0.occurredAt >= start }

        let meetings = events.filter { $0.type == .meetingProcessed }
        let usageDays = Set(meetings.map { calendar.startOfDay(for: $0.occurredAt) })

        // A verdict-less review event cannot be classified, so it is excluded from the count as
        // well as from the rate. Letting it into `reviewedProposals` alone would silently deflate
        // the approval rate's numerator against a larger denominator.
        let reviewed = events.filter { $0.type == .proposalReviewed && $0.verdict != nil }
        let approved = reviewed.filter { $0.verdict == .approved }.count
        let excluded = reviewed.filter { $0.verdict == .excluded }.count
        let judged = approved + excluded

        let reviewedProposalIDs = Set(reviewed.compactMap(\.proposalID))
        let editedProposalIDs = Set(events.filter { $0.type == .proposalModified }.compactMap(\.proposalID))
        let editedAndReviewed = editedProposalIDs.intersection(reviewedProposalIDs).count

        // Failed runs are included: the duration measures how long the user waited, and waiting
        // thirty seconds to be told it did not work is still thirty seconds of their life. The
        // outcome is stored per event, so a later report can split the two without a new measurement.
        let durations = events
            .filter { $0.type == .processingDuration }
            .compactMap(\.durationMilliseconds)
            .sorted()

        // Windowed on the same boundary as everything else. Feedback given before a reset belongs
        // to the previous measurement period; leaving it in would produce a report claiming zero
        // reminders and a dozen opinions about them.
        let feedback: BetaMetricsFeedback
        switch agentLedger {
        case .unavailable:
            feedback = .unavailable
        case .read(let ledgerEvents):
            var counts: [AgentLedgerFeedback: Int] = [:]
            for event in ledgerEvents where event.type == .feedback && event.occurredAt >= start {
                guard let value = event.feedback else { continue }
                counts[value, default: 0] += 1
            }
            feedback = .available(counts)
        }

        self.init(
            measurementStartedAt: start,
            meetingsProcessed: meetings.count,
            isActivated: !meetings.isEmpty,
            distinctUsageDays: usageDays.count,
            isRepeatUsageObserved: usageDays.count >= 2,
            reviewedProposals: reviewed.count,
            approvedCount: approved,
            excludedCount: excluded,
            approvalRate: judged == 0 ? nil : Double(approved) / Double(judged),
            modifiedProposals: editedAndReviewed,
            modificationRate: reviewed.isEmpty ? nil : Double(editedAndReviewed) / Double(reviewed.count),
            durationSampleCount: durations.count,
            medianDurationMilliseconds: Self.median(ofSorted: durations),
            agentFeedback: feedback
        )
    }

    /// The ordinary median of an ascending sample: the middle value when there is one, and the
    /// arithmetic mean of the two central values when the count is even.
    ///
    /// Written as `lower + (upper - lower) / 2` rather than `(lower + upper) / 2` so that two large
    /// durations cannot overflow on the way to their own midpoint. On a half-millisecond boundary
    /// the integer division floors, which is the only rounding this reports — the screen states the
    /// value in milliseconds and always beside its sample count.
    static func median(ofSorted samples: [Int]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let middle = samples.count / 2
        guard samples.count.isMultiple(of: 2) else {
            return samples[middle]
        }
        let lower = samples[middle - 1]
        let upper = samples[middle]
        return lower + (upper - lower) / 2
    }
}
