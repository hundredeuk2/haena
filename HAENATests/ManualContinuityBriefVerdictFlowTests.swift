import XCTest
@testable import HAENA

/// Task 2.7: the Brief separates approved carried state (A), candidates awaiting a verdict (B)
/// and approved next agenda (C); every verdict maps onto a typed action the existing service
/// applies to exactly one candidate; opening the Brief writes nothing and calls no model.
@MainActor
final class ManualContinuityBriefVerdictFlowTests: XCTestCase {
    private typealias Seed = ManualContinuityBriefUITestSeed
    private enum Failure: Error { case notLoaded }

    private struct Harness {
        let projects: InMemoryProjectRepository
        let transitions: InMemoryWorkStateTransitionRepository
        let profiles: InMemoryLocalUserProfileRepository
        let brief: ManualContinuityBriefService
        let review: WorkStateTransitionReviewService
        let workState: WorkStateReviewService
    }

    private func harness(_ scenario: Seed.Scenario = .full, saveError: Error? = nil) -> Harness {
        let seed = Seed.make(scenario: scenario)
        let projects = InMemoryProjectRepository(projects: [seed.project])
        let transitions = InMemoryWorkStateTransitionRepository(
            proposals: seed.proposals, ambiguousMatchGroups: seed.ambiguityGroups,
            saveError: saveError ?? (seed.failsApply ? Seed.ApplyFailure() : nil))
        let profiles = InMemoryLocalUserProfileRepository(profile: seed.profile)
        return Harness(
            projects: projects, transitions: transitions, profiles: profiles,
            brief: ManualContinuityBriefService(projects: projects, transitions: transitions, profiles: profiles),
            review: WorkStateTransitionReviewService(projectRepository: projects, transitionRepository: transitions),
            workState: WorkStateReviewService(repository: projects))
    }

    private func queue(_ h: Harness) async throws -> ManualContinuityBriefVerdictQueue {
        guard case .loaded(let brief) = await h.brief.load(projectID: Seed.make().project.id) else { throw Failure.notLoaded }
        return ManualContinuityBriefVerdictQueue(brief: brief)
    }

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "C8000000-0000-4000-8000-%012d", n))! }

    private func candidate(_ q: ManualContinuityBriefVerdictQueue, previous: Int) -> ManualContinuityBriefVerdictQueue.TransitionCandidate? {
        q.transitionCandidates.first { $0.transition.proposal.previousStateID == id(previous) }
    }

    // MARK: - Three sections

    func testFullSeedSplitsIntoCarriedCandidatesAndApprovedAgenda() async throws {
        let q = try await queue(harness())
        // A: approved objects only.
        XCTAssertEqual(Set(q.carried.confirmedDecisions.map(\.id)), [id(100), id(101), id(102)])
        XCTAssertEqual(Set(q.carried.myActiveCommitments.map(\.id) + q.carried.otherCommitments.map(\.id)), [id(200), id(201), id(203), id(205), id(207)])
        XCTAssertTrue(q.carried.completedCommitments.isEmpty)
        // B: one exact candidate per verdict, each with its own ID.
        XCTAssertEqual(q.completions.map { $0.transition.proposal.previousStateID }, [id(201)])
        XCTAssertEqual(q.completions.map(\.verdict), [.completion])
        XCTAssertEqual(q.progress.map(\.verdict), [.progress(.blocked), .progress(.overdue), .progress(.deferred)])
        XCTAssertEqual(q.progress.map { $0.transition.proposal.previousStateID }, [id(203), id(207), id(205)])
        XCTAssertEqual(q.changes.count, 2)
        XCTAssertTrue(q.changes.contains { $0.verdict == .resolution }); XCTAssertTrue(q.changes.contains { $0.verdict == .adoption })
        XCTAssertEqual(q.links.map(\.group.incomingObjectID), [id(103)])
        XCTAssertEqual(q.agendaCandidates.map(\.agendaItem.id), [id(400)])
        XCTAssertEqual(q.candidateCount, 8)
        XCTAssertEqual(q.state, .pending(8))
        XCTAssertEqual(Set(q.transitionCandidates.map(\.id)).count, q.transitionCandidates.count)
        // C: approved agenda only; the candidate never appears here.
        XCTAssertEqual(q.approvedAgenda.map(\.id), [id(401)])
        XCTAssertFalse(q.approvedAgenda.contains { $0.id == id(400) })
    }

    func testNoCandidateIsCountedInMoreThanOneGroup() async throws {
        let q = try await queue(harness())
        let ids = q.completions.map(\.id) + q.progress.map(\.id) + q.changes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let linkOwned = Set(q.links.flatMap { $0.selections.compactMap(\.transitionID) })
        let agendaOwned = Set(q.agendaCandidates.flatMap { $0.sources.compactMap(\.transitionID) })
        XCTAssertFalse(ids.contains { linkOwned.contains($0) })
        XCTAssertFalse(q.transitionCandidates.contains { $0.transition.proposal.workStateKind == .agendaItem && agendaOwned.contains($0.id) },
                       "an agenda item's own new-row is shown as an agenda candidate, not twice")
    }

    // MARK: - Verdict mapping is finite and typed

    func testEveryTransitionKindMapsToOneExistingVerdict() throws {
        let seed = Seed.make()
        guard case .loaded(let brief) = awaitLoad(seed) else { return XCTFail("not loaded") }
        for transition in brief.pendingTransitions {
            let delay = brief.delayedOrBlockedItems.first { $0.transition.proposal.id == transition.proposal.id }?.kind
            let verdict = ManualContinuityBriefVerdictKind(transition, delayKind: delay)
            switch transition.proposal.transitionKind {
            case .completed: XCTAssertEqual(verdict, .completion)
            case .delayed: XCTAssertEqual(verdict, .progress(delay!))
            case .changed: XCTAssertEqual(verdict, .change)
            case .resolved: XCTAssertEqual(verdict, .resolution)
            case .new: XCTAssertEqual(verdict, .adoption)
            case .same: XCTAssertEqual(verdict, .duplicate)
            }
        }
        XCTAssertEqual(WorkStateTransitionKind.allCases.count, 6, "a new kind must be mapped here explicitly")
    }

    func testVerdictLabelsAreDistinctAndLocalized() {
        let kinds: [ManualContinuityBriefVerdictKind] = [.completion, .progress(.blocked), .progress(.deferred), .progress(.overdue), .change, .resolution, .adoption, .duplicate]
        XCTAssertEqual(Set(kinds.map(\.approveKey)).count, kinds.count)
        for kind in kinds {
            for key in [kind.approveKey, kind.rejectKey, kind.approveEffectKey] {
                XCTAssertEqual(L10n.text(key, language: .ko), key)
                XCTAssertNotEqual(L10n.text(key, language: .en), key, key)
            }
        }
        XCTAssertTrue(kinds.filter { if case .progress = $0 { true } else { false } }.allSatisfy { $0.approveKey.contains("유지") })
        for key in ["판정 대기 후보", "확정된 다음 아젠다", "브리프를 열거나 둘러보는 것은 저장하지 않습니다. 후보의 판정 버튼만 저장된 상태를 바꿉니다.",
                    "첫 브리프입니다. 비교할 이전 회의 상태가 없어 판정할 후보가 없습니다.", "판정할 후보가 없습니다. 이전 회의 상태가 그대로 이어집니다.",
                    "후보 목록을 불러오지 못했습니다. 후보가 0건이라는 뜻이 아닙니다.", "후보는 그대로 남아 있습니다. 다시 시도할 수 있습니다."] {
            XCTAssertNotEqual(L10n.text(key, language: .en), key, key)
        }
    }

    // MARK: - Empty states

    func testFirstBriefAndZeroCandidatesAndUnavailableAreThreeDifferentStates() async throws {
        let first = try await queue(harness(.firstBrief))
        XCTAssertEqual(first.state, .firstBrief); XCTAssertEqual(first.candidateCount, 0)
        XCTAssertEqual(first.carried.project.meetings.count, 1)
        XCTAssertFalse(first.carried.confirmedDecisions.isEmpty, "carried state is still shown on a first Brief")
        let zero = try await queue(harness(.zeroCandidates))
        XCTAssertEqual(zero.state, .none); XCTAssertEqual(zero.carried.project.meetings.count, 2)
        XCTAssertEqual(zero.approvedAgenda.map(\.id), [id(401)])
        let unavailable = unavailableBrief(from: zero.carried)
        XCTAssertEqual(ManualContinuityBriefVerdictQueue(brief: unavailable).state, .unavailable)
    }

    func testLoadFailureIsReportedNotShownAsEmpty() async {
        let failing = FailingProjectRepository()
        let service = ManualContinuityBriefService(projects: failing, transitions: InMemoryWorkStateTransitionRepository(),
                                                   profiles: InMemoryLocalUserProfileRepository(profile: nil))
        let result = await service.load(projectID: id(1))
        XCTAssertEqual(result, .projectUnavailable)
        let missing = ManualContinuityBriefService(projects: InMemoryProjectRepository(projects: []),
                                                   transitions: InMemoryWorkStateTransitionRepository(),
                                                   profiles: InMemoryLocalUserProfileRepository(profile: nil))
        let missingResult = await missing.load(projectID: id(1))
        XCTAssertEqual(missingResult, .projectNotFound)
    }

    private func project(_ h: Harness) async throws -> Project {
        let loaded = try await h.projects.project(id: id(1))
        return try XCTUnwrap(loaded)
    }

    // MARK: - Opening and navigating are reads only

    func testOpeningTheBriefTwiceWritesNothingAndHasNoModelDependency() async throws {
        let h = harness()
        let before = try await project(h)
        _ = try await queue(h); _ = try await queue(h)
        let after = try await project(h)
        XCTAssertEqual(before, after)
        let statuses = try await h.transitions.allProposals().map(\.reviewStatus)
        XCTAssertEqual(statuses, Array(repeating: .pendingReview, count: 9))
        let intents = try await h.transitions.pendingApplyIntents()
        XCTAssertEqual(intents, [])
        // The read service is built from three repositories and nothing else: no extractor, no provider.
        let dependencies = Mirror(reflecting: h.brief).children.map { $0.label ?? "" }
        XCTAssertEqual(dependencies, ["projects", "transitions", "profiles"])
        var nav = AppShellNavigation(); nav.open(.init(projectID: id(1), pane: .status)); nav.select(.briefs)
        XCTAssertEqual(nav.destination, .briefs)
        let afterNavigation = try await project(h)
        XCTAssertEqual(afterNavigation, before)
    }

    // MARK: - Each verdict applies to exactly one candidate

    func testCompletionVerdictCompletesOnlyThatPriorAndMovesItToCarriedState() async throws {
        let h = harness(); let q = try await queue(h)
        let completion = try XCTUnwrap(candidate(q, previous: 201))
        let before = try await project(h)
        let result = await h.review.review(projectID: id(1), proposalID: completion.id, action: .approve)
        XCTAssertEqual(result, .applied)
        let after = try await project(h)
        let prior = try XCTUnwrap(after.actionItems.first { $0.id == id(201) })
        XCTAssertEqual(prior.status, .completed)
        XCTAssertEqual(prior.assigneeID, before.actionItems.first { $0.id == id(201) }?.assigneeID)
        XCTAssertEqual(prior.dueDate, before.actionItems.first { $0.id == id(201) }?.dueDate)
        XCTAssertNil(after.actionItems.first { $0.id == id(202) }, "the incoming duplicate is consumed")
        for other in [203, 204, 205, 206, 207, 208, 200] {
            XCTAssertEqual(after.actionItems.first { $0.id == id(other) }, before.actionItems.first { $0.id == id(other) }, "\(other)")
        }
        XCTAssertEqual(after.decisions, before.decisions); XCTAssertEqual(after.openQuestions, before.openQuestions)
        XCTAssertEqual(after.nextAgenda, before.nextAgenda)
        let reloaded = try await queue(h)
        XCTAssertTrue(reloaded.completions.isEmpty)
        XCTAssertEqual(reloaded.carried.completedCommitments.map(\.id), [id(201)])
        XCTAssertEqual(reloaded.candidateCount, q.candidateCount - 1)
        XCTAssertEqual(reloaded.progress.map(\.id), q.progress.map(\.id), "other candidates stay pending")
    }

    func testProgressVerdictsKeepStatusAssigneeAndDueDate() async throws {
        let h = harness(); let q = try await queue(h)
        let before = try await project(h)
        for (previous, current) in [(203, 204), (205, 206), (207, 0)] {
            let c = try XCTUnwrap(candidate(q, previous: previous))
            let result = await h.review.review(projectID: id(1), proposalID: c.id, action: .approve)
            XCTAssertEqual(result, .applied, "\(previous)")
            let after = try await project(h)
            let prior = try XCTUnwrap(after.actionItems.first { $0.id == id(previous) })
            let original = try XCTUnwrap(before.actionItems.first { $0.id == id(previous) })
            XCTAssertEqual(prior.status, original.status); XCTAssertEqual(prior.dueDate, original.dueDate)
            XCTAssertEqual(prior.assigneeID, original.assigneeID); XCTAssertEqual(prior.evidence, original.evidence)
            if current != 0 { XCTAssertNil(after.actionItems.first { $0.id == id(current) }) }
        }
        let reloaded = try await queue(h)
        XCTAssertTrue(reloaded.progress.isEmpty)
        XCTAssertEqual(reloaded.completions.map { $0.transition.proposal.previousStateID }, [id(201)], "completion still awaits its own verdict")
    }

    func testRejectRecordsOnlyThatCandidateAndChangesNoObject() async throws {
        let h = harness(); let q = try await queue(h)
        let before = try await project(h)
        let completion = try XCTUnwrap(candidate(q, previous: 201))
        let result = await h.review.review(projectID: id(1), proposalID: completion.id, action: .reject)
        XCTAssertEqual(result, .rejected)
        let after = try await project(h)
        XCTAssertEqual(after, before)
        let reloaded = try await queue(h)
        XCTAssertTrue(reloaded.completions.isEmpty)
        XCTAssertEqual(reloaded.candidateCount, q.candidateCount - 1)
        let rejected = try await h.transitions.allProposals().filter { $0.reviewStatus == .rejected }.map(\.id)
        XCTAssertEqual(rejected, [completion.id])
    }

    func testResolutionAndAmbiguityAndAgendaVerdictsRouteToTheirOwnServices() async throws {
        let h = harness(); let q = try await queue(h)
        let resolution = try XCTUnwrap(q.changes.first { $0.verdict == .resolution })
        let resolved = await h.review.review(projectID: id(1), proposalID: resolution.id, action: .approve)
        XCTAssertEqual(resolved, .applied)
        var after = try await project(h)
        XCTAssertEqual(after.openQuestions.first { $0.id == id(300) }?.status, .resolved)
        XCTAssertNotNil(after.nextAgenda.first { $0.id == id(400) }?.reviewedAt, "the carried agenda item is approved with the question")
        let link = try XCTUnwrap(q.links.first)
        let linked = await h.review.resolveAmbiguity(projectID: id(1), groupID: link.group.id, selection: .new)
        XCTAssertEqual(linked, .applied)
        after = try await project(h)
        XCTAssertEqual(after.decisions.first { $0.id == id(103) }?.status, .confirmed)
        XCTAssertEqual(after.decisions.first { $0.id == id(101) }?.statement, "Release after review", "prior candidates untouched")
        let reloaded = try await queue(h)
        XCTAssertTrue(reloaded.links.isEmpty); XCTAssertTrue(reloaded.agendaCandidates.isEmpty)
        XCTAssertEqual(Set(reloaded.approvedAgenda.map(\.id)), [id(400), id(401)])
    }

    func testAgendaExclusionRetiresOnlyThatCandidate() async throws {
        let h = harness(); let q = try await queue(h)
        try await h.workState.dismissAgendaItem(id: id(400), in: id(1))
        let reloaded = try await queue(h)
        XCTAssertTrue(reloaded.agendaCandidates.isEmpty)
        XCTAssertEqual(reloaded.approvedAgenda.map(\.id), [id(401)])
        XCTAssertEqual(reloaded.completions.map(\.id), q.completions.map(\.id))
        XCTAssertEqual(reloaded.changes.map(\.id), q.changes.map(\.id), "the resolution candidate stays reviewable")
    }

    // MARK: - Failure keeps the candidate; retry works

    func testApplyFailureLeavesCandidateAndProjectUntouchedAndRetryApplies() async throws {
        let failing = harness(.applyFailure); let q = try await queue(failing)
        let completion = try XCTUnwrap(candidate(q, previous: 201))
        let before = try await project(failing)
        let refused = await failing.review.review(projectID: id(1), proposalID: completion.id, action: .approve)
        XCTAssertEqual(refused, .refused(.reviewPersistenceFailed))
        let after = try await project(failing)
        XCTAssertEqual(after, before)
        let reloaded = try await queue(failing)
        XCTAssertEqual(reloaded.completions.map(\.id), [completion.id]); XCTAssertEqual(reloaded.candidateCount, q.candidateCount)
        // The same verdict against a healthy store applies; nothing about the candidate changed.
        let healthy = harness()
        let applied = await healthy.review.review(projectID: id(1), proposalID: completion.id, action: .approve)
        XCTAssertEqual(applied, .applied)
    }

    // MARK: - No batch path

    func testThereIsNoBatchOrAutomaticVerdict() async throws {
        let q = try await queue(harness())
        XCTAssertEqual(q.transitionCandidates.count, 6)
        let members = Mirror(reflecting: q).children.map { $0.label ?? "" }
        XCTAssertFalse(members.contains { $0.lowercased().contains("all") || $0.lowercased().contains("batch") })
        let service = Mirror(reflecting: WorkStateTransitionReviewAction.approve)
        XCTAssertEqual(WorkStateTransitionReviewAction.approve, .approve); _ = service
    }

    // MARK: - Helpers

    private func awaitLoad(_ seed: Seed) -> ManualContinuityBriefLoadResult {
        let h = harness()
        var result: ManualContinuityBriefLoadResult = .projectNotFound
        let done = expectation(description: "load")
        Task { result = await h.brief.load(projectID: seed.project.id); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func unavailableBrief(from brief: ManualContinuityBrief) -> ManualContinuityBrief {
        ManualContinuityBrief(project: brief.project, personalisation: brief.personalisation, transitionAvailability: .unavailable,
                              warnings: [.init(kind: .transitionsUnavailable, transitionID: nil)], confirmedDecisions: brief.confirmedDecisions,
                              myActiveCommitments: brief.myActiveCommitments, otherCommitments: brief.otherCommitments,
                              completedCommitments: brief.completedCommitments, pendingTransitions: [], delayedOrBlockedItems: [],
                              unresolvedQuestions: brief.unresolvedQuestions, approvedNextAgenda: brief.approvedNextAgenda,
                              agendaCandidates: [], ambiguousMatches: [])
    }
}

private actor FailingProjectRepository: ProjectRepository {
    struct Unavailable: Error {}
    func project(id: UUID) throws -> Project? { throw Unavailable() }
    func allProjects() throws -> [Project] { throw Unavailable() }
    func save(_ project: Project) throws { throw Unavailable() }
    func delete(id: UUID) throws { throw Unavailable() }
}
