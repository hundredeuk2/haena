import Foundation

/// Marks how far one extraction run got, without ever making the run wait for the mark.
///
/// This exists for one investigation: a paste-based extraction whose work reached disk but whose
/// screen never left `AI 분석 중…`. Nothing in the app could say which boundary it stopped at,
/// because there was no record of the boundaries. This writes them.
///
/// **It must never become the next place a run can stall.** `BetaMetricsService.record*` appends to
/// a file, so awaiting it inside the extraction path would put a disk write between the provider
/// call and the user's completion screen — a new hang candidate introduced by the very thing meant
/// to diagnose one. Every mark is therefore handed to a detached task and forgotten: the caller
/// does not await it, does not learn whether it succeeded, and is unaffected when it fails.
///
/// The cost of that is real and deliberate: rows can land out of order, or not at all. Order is
/// recovered from `BetaMetricExtractionPhase.sequence`, never from the order rows appear in the
/// file, and a missing mark is read as "unknown", never as "did not get there".
struct ExtractionPhaseRecorder: Sendable {
    /// The same `CaptureRun` identity the duration metric uses, so one user-visible wait is one run
    /// across every layer that observes it. Layers never mint their own.
    let runID: UUID
    let projectID: UUID?
    let meetingID: UUID?
    private let metrics: BetaMetricsService?
    private let elapsedMilliseconds: @Sendable () -> Int

    init(
        runID: UUID,
        projectID: UUID? = nil,
        meetingID: UUID? = nil,
        metrics: BetaMetricsService?,
        elapsedMilliseconds: @escaping @Sendable () -> Int
    ) {
        self.runID = runID
        self.projectID = projectID
        self.meetingID = meetingID
        self.metrics = metrics
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    /// Records one boundary and returns immediately.
    ///
    /// Not `async` on purpose. An `async` signature would invite a caller to `await` it, which is
    /// exactly the coupling this type exists to prevent.
    func mark(_ phase: BetaMetricExtractionPhase) {
        guard let metrics else { return }
        let milliseconds = elapsedMilliseconds()
        let runID = runID
        let projectID = projectID
        let meetingID = meetingID
        Task.detached(priority: .utility) {
            await metrics.recordExtractionPhase(
                runID: runID,
                phase: phase,
                milliseconds: milliseconds,
                projectID: projectID,
                meetingID: meetingID
            )
        }
    }

    /// The same recorder aimed at a meeting that did not exist when the run started.
    func naming(projectID: UUID?, meetingID: UUID?) -> ExtractionPhaseRecorder {
        ExtractionPhaseRecorder(
            runID: runID,
            projectID: projectID,
            meetingID: meetingID,
            metrics: metrics,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }
}
