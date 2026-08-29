import Foundation

/// Whether a saved meeting can be analysed again right now, and if not, why.
///
/// Every case is derived from stored data at the moment it is asked. Nothing here is written down:
/// there is no "extraction failed" flag on a meeting, and there deliberately is not one. A run that
/// failed left no trace precisely because `WorkStateExtractionService` writes nothing on the way
/// out, so the honest evidence that a meeting still needs analysing is that it has no results —
/// which survives a relaunch for free, and cannot go stale the way a stored flag could.
enum MeetingReanalysisEligibility: Equatable, Sendable {
    case eligible
    /// The meeting is gone — deleted while a screen offering re-analysis was still open.
    case meetingNotFound
    /// Nothing to send. A meeting with no transcript has no input to analyse.
    case transcriptMissing
    /// This meeting already produced something a person can review. Re-analysing work that has
    /// already been proposed, approved, or closed out is a different feature; this one only
    /// recovers a run that produced nothing at all.
    case alreadyAnalysed
    /// A run for this meeting is already in flight.
    case alreadyRunning
    /// Stored data could not be read, so eligibility is unknown. Reported rather than guessed:
    /// treating an unreadable store as "eligible" would send a request nothing has checked.
    case storeUnavailable
}

/// Thrown instead of running, when the meeting is not eligible. Carries the reason so the screen
/// can say which of them applied without re-asking.
struct MeetingReanalysisRefused: Error, Equatable, Sendable {
    let reason: MeetingReanalysisEligibility
}

/// Runs extraction again over a meeting that is **already stored**, reusing its existing identity
/// and transcript.
///
/// This exists because extraction can fail after the meeting is safely saved — an unanswered
/// Keychain prompt, a 429, a 5xx, a dropped connection — and until now the only way for a user to
/// recover was to paste the same transcript again, which creates a *second* meeting. Nothing about
/// re-running needs new input, so nothing about it creates new records: `extractAndApply` already
/// takes only two identifiers and re-reads the meeting from the repository, and its own re-run
/// policy replaces a meeting's superseded proposals rather than appending to them.
///
/// An actor rather than a struct for one reason: `running` has to be a real mutual exclusion. A
/// disabled button is the right thing for the screen to show, but it is a courtesy, not a
/// guarantee — the guarantee that two overlapping presses cannot become two provider requests has
/// to live somewhere a test can drive directly. The claim and the check happen before this type's
/// first suspension point, which is what makes the second caller lose rather than race.
///
/// Nothing here retries on its own. There is no timer, no watchdog, no backoff and no queue: every
/// run is one a person started, and a run that fails simply leaves the meeting eligible again.
actor MeetingReanalysisService {
    private let repository: any ProjectRepository
    private let extraction: WorkStateExtractionService
    /// Optional because the continuity sidecar is optional everywhere else too. When it is absent
    /// eligibility is decided by stored work state alone.
    private let transitions: (any WorkStateTransitionRepository)?
    private var running: Set<UUID> = []

    init(
        repository: any ProjectRepository,
        extraction: WorkStateExtractionService,
        transitions: (any WorkStateTransitionRepository)? = nil
    ) {
        self.repository = repository
        self.extraction = extraction
        self.transitions = transitions
    }

    /// What a screen should offer. Same answer `reanalyse` enforces, from the same code, so the
    /// button cannot appear for a meeting the service would then refuse.
    func eligibility(meetingID: UUID, projectID: UUID) async -> MeetingReanalysisEligibility {
        guard !running.contains(meetingID) else {
            return .alreadyRunning
        }
        return await storedEligibility(meetingID: meetingID, projectID: projectID)
    }

    /// Analyses the stored meeting again, or throws `MeetingReanalysisRefused` without calling the
    /// provider. Extraction failures propagate untouched, so the caller maps them with the same
    /// copy every other extraction failure uses.
    @discardableResult
    func reanalyse(
        meetingID: UUID,
        projectID: UUID
    ) async throws -> WorkStateExtractionReport {
        // Claimed synchronously, before the first `await` below: an actor does not interleave
        // between entry and its first suspension point, so a second caller arriving while this one
        // is waiting on the provider finds the meeting already claimed instead of finding the same
        // "not running" answer this one saw.
        guard !running.contains(meetingID) else {
            throw MeetingReanalysisRefused(reason: .alreadyRunning)
        }
        running.insert(meetingID)
        defer { running.remove(meetingID) }

        let reason = await storedEligibility(meetingID: meetingID, projectID: projectID)
        guard reason == .eligible else {
            throw MeetingReanalysisRefused(reason: reason)
        }

        return try await extraction.extractAndApply(meetingID: meetingID, projectID: projectID)
    }

    // MARK: - Stored evidence

    private func storedEligibility(
        meetingID: UUID,
        projectID: UUID
    ) async -> MeetingReanalysisEligibility {
        let loaded: Project?
        do {
            loaded = try await repository.project(id: projectID)
        } catch {
            return .storeUnavailable
        }
        guard let project = loaded,
              let meeting = project.meetings.first(where: { $0.id == meetingID })
        else {
            return .meetingNotFound
        }
        guard !meeting.transcriptSegments.isEmpty else {
            return .transcriptMissing
        }

        // `CaptureResultCounts` counts everything attributed to the meeting whatever state it is
        // in — pending, reviewed and processed alike — which is exactly the line this feature must
        // not cross. Borrowed rather than re-derived so this cannot disagree with the numbers the
        // completion screen already showed for the same meeting.
        let counts = CaptureResultCounts(
            summary: MeetingWorkStateSummary(project: project, meetingID: meetingID)
        )
        guard counts.total == 0 else {
            return .alreadyAnalysed
        }

        // A run can produce continuity proposals without producing any work state of its own — a
        // meeting whose only outcome was moving prior work forward. Those are reviewable results
        // too, so a meeting that has them has already been analysed.
        if let transitions {
            let proposals: [WorkStateTransitionProposal]
            do {
                proposals = try await transitions.proposals(forProject: projectID)
            } catch {
                // Deliberately not fatal to eligibility. Stored work state — the check above, and
                // the one that matters — was readable and empty. Refusing here because a sidecar
                // could not be read would rebuild the dead end this whole path exists to remove.
                return .eligible
            }
            guard !proposals.contains(where: { $0.sourceMeetingID == meetingID }) else {
                return .alreadyAnalysed
            }
        }

        return .eligible
    }
}

/// Korean copy for a re-analysis that did not run. Kept beside `CaptureFailureCopy` in spirit: no
/// provider text, no transcript text and no identifiers are ever interpolated.
enum MeetingReanalysisCopy {
    static let button = "AI 분석 다시 시도"

    /// Why the button is offered at all. Says what is missing, not what went wrong — the run that
    /// failed may have been days ago, and its error is long gone.
    static let availability = "이 회의에서 나온 결과가 없습니다. 저장된 회의록으로 다시 분석할 수 있습니다."

    static func refusal(_ reason: MeetingReanalysisEligibility) -> String {
        switch reason {
        case .eligible:
            // Not reachable through a refusal, and not worth a crash if it ever is.
            return "다시 분석하지 못했습니다."
        case .meetingNotFound:
            return "이 회의를 찾을 수 없습니다. 삭제되었을 수 있습니다."
        case .transcriptMissing:
            return "저장된 회의록 원문이 없어 다시 분석할 수 없습니다."
        case .alreadyAnalysed:
            return "이 회의에는 이미 결과가 있습니다. 회의 결과에서 확인해주세요."
        case .alreadyRunning:
            return "이미 분석이 진행 중입니다."
        case .storeUnavailable:
            return "저장된 회의를 읽지 못했습니다."
        }
    }
}
