import Foundation

/// The only way the rest of the app records a beta measurement.
///
/// Every `record*` method is `async` and **cannot** throw. That is not an oversight and not a
/// convenience — it is the structural guarantee that measurement can never break the thing being
/// measured. A capture, a review, or a reminder must not fail because a metrics file was read-only,
/// so the caller is not handed an error it could propagate even if it wanted to. Failures are
/// swallowed here, at the one place that knows they are unimportant.
///
/// The signatures carry only identifiers, enum cases and numbers. There is no parameter a title,
/// name, transcript, quote, or key could be passed in — a caller cannot leak content through this
/// API even by mistake, which is a stronger promise than asking callers to be careful.
struct BetaMetricsService: Sendable {
    let repository: any BetaMetricsRepository
    /// Optional because the reminder ledger is a separate, independently resettable store: the beta
    /// report is still meaningful on a machine where reminders were never used.
    let ledgerRepository: (any AgentLedgerRepository)?
    let now: @Sendable () -> Date
    let makeID: @Sendable () -> UUID

    init(
        repository: any BetaMetricsRepository,
        ledgerRepository: (any AgentLedgerRepository)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.ledgerRepository = ledgerRepository
        self.now = now
        self.makeID = makeID
    }

    // MARK: - Recording

    /// Activation and repeat-usage evidence. Keyed on the meeting, so a re-extraction of the same
    /// meeting is the same meeting — otherwise a user who reprocessed one recording four times
    /// would look like a user who held four meetings.
    ///
    /// `resultCount` is how many proposals the run produced; nil when the caller does not know.
    func recordMeetingProcessed(
        projectID: UUID,
        meetingID: UUID,
        source: BetaMetricCaptureSource,
        resultCount: Int?
    ) async {
        await record(
            BetaMetricEvent(
                id: makeID(),
                deduplicationKey: Self.key(.meetingProcessed, meetingID),
                type: .meetingProcessed,
                occurredAt: now(),
                projectID: projectID,
                meetingID: meetingID,
                captureSource: source,
                resultCount: resultCount
            )
        )
    }

    /// How long one processing run made the user wait, keyed on the run rather than the meeting: a
    /// failed run has no meeting, and a retry after a failure is a second wait the user really sat
    /// through. The caller owns the run identifier and must generate a fresh one per attempt.
    func recordProcessingDuration(
        runID: UUID,
        source: BetaMetricCaptureSource,
        outcome: BetaMetricOutcome,
        milliseconds: Int,
        meetingID: UUID?
    ) async {
        await record(
            BetaMetricEvent(
                id: makeID(),
                deduplicationKey: Self.key(.processingDuration, runID),
                type: .processingDuration,
                occurredAt: now(),
                meetingID: meetingID,
                captureSource: source,
                outcome: outcome,
                durationMilliseconds: milliseconds
            )
        )
    }

    /// A person's verdict on one proposal. Keyed on the proposal, so the **first** verdict wins.
    ///
    /// The first verdict is the one the extraction earned: if a user approves an item and later
    /// deletes it for reasons of their own, that is a change of mind about the work, not a correction
    /// of the model. Letting a later verdict overwrite the first would make the approval rate drift
    /// with ordinary project churn long after the extraction was judged.
    func recordProposalReviewed(
        projectID: UUID,
        proposalID: UUID,
        kind: BetaMetricProposalKind,
        verdict: BetaMetricVerdict
    ) async {
        await record(
            BetaMetricEvent(
                id: makeID(),
                deduplicationKey: Self.key(.proposalReviewed, proposalID),
                type: .proposalReviewed,
                occurredAt: now(),
                projectID: projectID,
                proposalID: proposalID,
                proposalKind: kind,
                verdict: verdict
            )
        )
    }

    /// The user corrected a field before accepting. Keyed on the proposal **and** the field, so the
    /// same field nudged five times counts once while a proposal whose assignee *and* due date both
    /// needed fixing keeps both facts.
    ///
    /// Keying on the proposal alone lost the second field silently — whichever correction the caller
    /// happened to emit first was the only one ever stored, which made the field breakdown a record
    /// of emission order rather than of what the model got wrong. The rate is unaffected either way:
    /// `BetaMetricsSummary` counts distinct proposals, so a proposal still contributes at most one
    /// to the numerator however many of its fields were corrected.
    func recordProposalModified(
        projectID: UUID,
        proposalID: UUID,
        kind: BetaMetricProposalKind,
        field: BetaMetricFieldCategory
    ) async {
        await record(
            BetaMetricEvent(
                id: makeID(),
                deduplicationKey: Self.key(.proposalModified, proposalID, field.rawValue),
                type: .proposalModified,
                occurredAt: now(),
                projectID: projectID,
                proposalID: proposalID,
                proposalKind: kind,
                fieldCategory: field
            )
        )
    }

    // MARK: - Reading and erasing

    /// Throws, unlike the recording calls: this one is a button the user pressed, and a person who
    /// asked for their measurement to be erased has to be told when it was not.
    func reset() async throws {
        try await repository.reset(at: now())
    }

    /// Throws for the same reason: the beta screen must show an error rather than an empty report
    /// that reads as "you have done nothing".
    ///
    /// The ledger read is best-effort by contrast: reminder feedback belongs to another feature's
    /// store, and losing it must not take the metrics this service owns down with it. A failed read
    /// is reported as `.unavailable` rather than as an empty tally, so the screen can say the
    /// feedback could not be loaded instead of asserting that nobody had an opinion.
    func summary(calendar: Calendar) async throws -> BetaMetricsSummary {
        let store = try await repository.store()
        return BetaMetricsSummary(
            store: store,
            agentLedger: await ledgerRead(),
            calendar: calendar
        )
    }

    // MARK: - Plumbing

    private func record(_ event: BetaMetricEvent) async {
        _ = try? await repository.append(event)
    }

    /// No ledger configured is a successful read of nothing: this app simply has no reminder store
    /// in that configuration, so "no feedback" is the true answer. A ledger that exists and refuses
    /// to be read is the different case, and is reported as such.
    private func ledgerRead() async -> BetaMetricsLedgerRead {
        guard let ledgerRepository else { return .read([]) }
        do {
            return .read(try await ledgerRepository.events(limit: nil))
        } catch {
            return .unavailable
        }
    }

    /// Every deduplication key is a type prefix, a lowercased UUID, and at most one further finite
    /// enum case — never anything a user typed. Every component is a compile-time constant or an
    /// identifier, so no title, name, or quote can reach a key even by accident. Keeping the
    /// construction in one private function is what makes that claim checkable: see
    /// `BetaMetricsPrivacyTests`, which asserts the shape of every key a store contains.
    private static func key(
        _ type: BetaMetricEventType,
        _ identifier: UUID,
        _ qualifier: String? = nil
    ) -> String {
        let base = "\(type.rawValue):\(identifier.uuidString.lowercased())"
        guard let qualifier else { return base }
        return "\(base):\(qualifier)"
    }
}
