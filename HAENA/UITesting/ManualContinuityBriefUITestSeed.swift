import Foundation

/// Deterministic, in-memory-only state for the Manual Continuity Brief UI journey.
///
/// The app assembles this only when both the global UI-test flag and the feature-specific flag are
/// present. It contains no user path, credential, audio, or network provider and is never written to
/// Application Support.
struct ManualContinuityBriefUITestSeed {
    /// 2.7 verdict-flow states. `full` is the original seed; the others narrow it so a test can see
    /// a first Brief, a zero-candidate Brief, and an apply that fails before any Project write.
    enum Scenario: String { case full, firstBrief, zeroCandidates, applyFailure }
    struct ApplyFailure: Error {}

    let project: Project
    let proposals: [WorkStateTransitionProposal]
    let ambiguityGroups: [WorkStateAmbiguousMatchGroup]
    let profile: LocalUserProfile
    var scenario: Scenario = .full
    var failsApply: Bool { scenario == .applyFailure }

    static func select(environment: [String: String]) -> ManualContinuityBriefUITestSeed? {
        guard environment["HAENA_UI_TESTING"] == "1",
              environment["HAENA_UI_TESTING_MANUAL_BRIEF"] == "1" else { return nil }
        let scenario = environment["HAENA_UI_TEST_MANUAL_BRIEF_SCENARIO"].flatMap(Scenario.init(rawValue:)) ?? .full
        return make(scenario: scenario)
    }

    static func make(scenario: Scenario) -> ManualContinuityBriefUITestSeed {
        var seed = make()
        seed.scenario = scenario
        switch scenario {
        case .full, .applyFailure:
            return seed
        case .firstBrief, .zeroCandidates:
            // Only user-approved objects remain; every pending candidate, proposal and group is gone.
            var project = seed.project
            project.decisions.removeAll { PendingAIProposalPolicy.isPending($0) }
            project.actionItems.removeAll { PendingAIProposalPolicy.isPending($0) }
            project.openQuestions.removeAll { PendingAIProposalPolicy.isPending($0) }
            project.nextAgenda.removeAll { PendingAIProposalPolicy.isPending($0) }
            if scenario == .firstBrief {
                project.meetings = Array(project.meetings.prefix(1))
            }
            return ManualContinuityBriefUITestSeed(project: project, proposals: [], ambiguityGroups: [],
                                                   profile: seed.profile, scenario: scenario)
        }
    }

    static func make() -> ManualContinuityBriefUITestSeed {
        let projectID = id(1)
        let priorMeetingID = id(2)
        let currentMeetingID = id(3)
        let meID = id(4)
        let otherID = id(5)
        let priorSegmentID = id(6)
        let currentSegmentID = id(7)
        let base = Date(timeIntervalSince1970: 1_786_358_400)
        let currentTime = base.addingTimeInterval(86_400)

        let priorMeeting = Meeting(
            id: priorMeetingID,
            projectID: projectID,
            title: "Planning",
            occurredAt: base,
            sourceType: .pastedText,
            participants: [
                Participant(id: meID, displayName: "Alex", linkedUserID: nil, speakerLabel: "Speaker 1"),
                Participant(id: otherID, displayName: "Blair", linkedUserID: nil, speakerLabel: "Speaker 2")
            ],
            transcriptSegments: [
                TranscriptSegment(
                    id: priorSegmentID,
                    meetingID: priorMeetingID,
                    speakerID: meID,
                    text: "We will ship the local continuity preview.",
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: base
        )
        let currentText = "The export is complete. The review is blocked. Defer migration. Carry the question forward."
        let currentMeeting = Meeting(
            id: currentMeetingID,
            projectID: projectID,
            title: "Continuity Review",
            occurredAt: currentTime,
            sourceType: .pastedText,
            participants: priorMeeting.participants,
            transcriptSegments: [
                TranscriptSegment(
                    id: currentSegmentID,
                    meetingID: currentMeetingID,
                    speakerID: otherID,
                    text: currentText,
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: currentTime
        )
        let currentEvidence = EvidenceReference(
            meetingID: currentMeetingID,
            transcriptSegmentID: currentSegmentID,
            quote: "The review is blocked."
        )
        let pointer = TransitionEvidencePointer(
            meetingID: currentMeetingID,
            transcriptSegmentID: currentSegmentID
        )

        let confirmedDecision = Decision(
            id: id(100), projectID: projectID, meetingID: priorMeetingID,
            statement: "Use local-first continuity", rationale: "Protect meeting data",
            status: .confirmed, evidence: nil, confidence: .maximum,
            createdAt: base, updatedAt: base
        )
        let ambiguityPriorA = Decision(
            id: id(101), projectID: projectID, meetingID: priorMeetingID,
            statement: "Release after review", rationale: nil, status: .confirmed,
            evidence: nil, confidence: .maximum, createdAt: base, updatedAt: base
        )
        let ambiguityPriorB = Decision(
            id: id(102), projectID: projectID, meetingID: priorMeetingID,
            statement: "Release after accessibility review", rationale: nil, status: .confirmed,
            evidence: nil, confidence: .maximum, createdAt: base, updatedAt: base
        )
        let ambiguityIncoming = Decision(
            id: id(103), projectID: projectID, meetingID: currentMeetingID,
            statement: "Release after final review", rationale: nil, status: .proposed,
            evidence: currentEvidence, confidence: Confidence(0.8),
            createdAt: currentTime, updatedAt: currentTime
        )

        func priorAction(_ index: Int, title: String, assignee: UUID?, dueDate: Date? = nil) -> ActionItem {
            ActionItem(
                id: id(index), projectID: projectID, meetingID: priorMeetingID,
                title: title, details: nil, assigneeID: assignee, dueDate: dueDate,
                status: .confirmed, evidence: nil, confidence: .maximum,
                createdAt: base, updatedAt: base
            )
        }
        func currentAction(_ index: Int, title: String) -> ActionItem {
            ActionItem(
                id: id(index), projectID: projectID, meetingID: currentMeetingID,
                title: title, details: nil, assigneeID: otherID, dueDate: nil,
                status: .proposed, evidence: currentEvidence, confidence: Confidence(0.8),
                createdAt: currentTime, updatedAt: currentTime
            )
        }

        let myActive = priorAction(200, title: "Prepare continuity demo", assignee: meID)
        let completedPrior = priorAction(201, title: "Export transition fixture", assignee: meID)
        let completedCurrent = currentAction(202, title: "Export transition fixture")
        let blockedPrior = priorAction(203, title: "Review privacy boundary", assignee: otherID)
        let blockedCurrent = currentAction(204, title: "Review privacy boundary")
        let deferredPrior = priorAction(205, title: "Migrate legacy records", assignee: otherID)
        let deferredCurrent = currentAction(206, title: "Migrate legacy records")
        let overduePrior = priorAction(
            207,
            title: "Publish verification notes",
            assignee: otherID,
            dueDate: base.addingTimeInterval(3_600)
        )
        let derivedAction = currentAction(208, title: "Add local review checklist")

        let openQuestion = OpenQuestion(
            id: id(300), projectID: projectID, meetingID: priorMeetingID,
            question: "Which workflow should open the next meeting?", status: .open,
            evidence: nil, confidence: .maximum, createdAt: base,
            resolvedAt: nil, reviewedAt: base
        )
        let agendaCandidate = AgendaItem(
            id: id(400), projectID: projectID,
            title: "Choose the next-meeting workflow", reason: "Question carried forward",
            sourceMeetingID: currentMeetingID, relatedActionItemID: nil,
            relatedOpenQuestionID: openQuestion.id, status: .pending,
            createdAt: currentTime, evidence: currentEvidence,
            confidence: Confidence(0.8), reviewedAt: nil
        )
        let approvedAgenda = AgendaItem(
            id: id(401), projectID: projectID,
            title: "Review continuity pilot", reason: "User-approved agenda",
            sourceMeetingID: priorMeetingID, relatedActionItemID: nil,
            relatedOpenQuestionID: nil, status: .pending,
            createdAt: base, evidence: nil, confidence: nil, reviewedAt: base
        )

        let project = Project(
            id: projectID,
            name: "Continuity UI Seed",
            summary: "Deterministic Manual Brief fixture",
            createdAt: base,
            updatedAt: currentTime,
            meetings: [priorMeeting, currentMeeting],
            decisions: [confirmedDecision, ambiguityPriorA, ambiguityPriorB, ambiguityIncoming],
            actionItems: [
                myActive, completedPrior, completedCurrent, blockedPrior, blockedCurrent,
                deferredPrior, deferredCurrent, overduePrior, derivedAction
            ],
            openQuestions: [openQuestion],
            nextAgenda: [agendaCandidate, approvedAgenda]
        )

        func proposal(
            kind: WorkStateKind,
            transition: WorkStateTransitionKind,
            previous: UUID?,
            current: UUID?,
            basis: WorkStateTransitionBasis,
            disposition: WorkStateTransitionProgressDisposition? = nil,
            evidence: TransitionEvidencePointer? = pointer,
            relations: [WorkStateTransitionRelation] = []
        ) -> WorkStateTransitionProposal {
            let key = WorkStateTransitionProposal.dedupKey(
                projectID: projectID,
                workStateKind: kind,
                transitionKind: transition,
                previousStateID: previous,
                currentObjectID: current
            )
            return WorkStateTransitionProposal(
                id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
                projectID: projectID,
                workStateKind: kind,
                transitionKind: transition,
                previousStateID: previous,
                currentObjectID: current,
                sourceMeetingID: currentMeetingID,
                evidence: evidence,
                basis: basis,
                progressDisposition: disposition,
                reasons: transition == .new ? [] : [.stateChangeRequiresApproval],
                requiresConfirmation: transition != .new && transition != .same,
                relations: relations,
                dedupKey: key,
                createdAt: currentTime.addingTimeInterval(60)
            )
        }

        let ambiguityGroup = WorkStateAmbiguousMatchGroup(
            projectID: projectID,
            sourceMeetingID: currentMeetingID,
            workStateKind: .decision,
            incomingObjectID: ambiguityIncoming.id,
            priorCandidateIDs: [ambiguityPriorA.id, ambiguityPriorB.id]
        )
        let proposals = [
            proposal(
                kind: .actionItem, transition: .completed,
                previous: completedPrior.id, current: completedCurrent.id,
                basis: .structuredProgressSignal
            ),
            proposal(
                kind: .actionItem, transition: .delayed,
                previous: blockedPrior.id, current: blockedCurrent.id,
                basis: .structuredProgressSignal, disposition: .blocked
            ),
            proposal(
                kind: .actionItem, transition: .delayed,
                previous: deferredPrior.id, current: deferredCurrent.id,
                basis: .structuredProgressSignal, disposition: .deferred
            ),
            proposal(
                kind: .actionItem, transition: .delayed,
                previous: overduePrior.id, current: nil,
                basis: .overdueApprovedDueDate, evidence: nil
            ),
            proposal(
                kind: .openQuestion, transition: .resolved,
                previous: openQuestion.id, current: agendaCandidate.id,
                basis: .structuredResolutionLink,
                relations: [
                    WorkStateTransitionRelation(
                        kind: .carriedToAgenda,
                        relatedKind: .agendaItem,
                        relatedObjectID: agendaCandidate.id
                    )
                ]
            ),
            proposal(
                kind: .agendaItem, transition: .new,
                previous: nil, current: agendaCandidate.id,
                basis: .noPriorCandidate
            ),
            proposal(
                kind: .actionItem, transition: .new,
                previous: nil, current: derivedAction.id,
                basis: .noPriorCandidate,
                relations: [
                    WorkStateTransitionRelation(
                        kind: .derivedFrom,
                        relatedKind: .decision,
                        relatedObjectID: confirmedDecision.id
                    )
                ]
            ),
            proposal(
                kind: .decision, transition: .changed,
                previous: ambiguityPriorA.id, current: ambiguityIncoming.id,
                basis: .nearTextMatch
            ),
            proposal(
                kind: .decision, transition: .changed,
                previous: ambiguityPriorB.id, current: ambiguityIncoming.id,
                basis: .nearTextMatch
            )
        ]
        let profile = LocalUserProfile(
            id: id(500),
            displayName: "Alex",
            linkedParticipantIDs: [meID],
            createdAt: base,
            updatedAt: base
        )
        return ManualContinuityBriefUITestSeed(
            project: project,
            proposals: proposals,
            ambiguityGroups: [ambiguityGroup],
            profile: profile
        )
    }

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: "C8000000-0000-4000-8000-\(String(format: "%012d", index))")!
    }
}
