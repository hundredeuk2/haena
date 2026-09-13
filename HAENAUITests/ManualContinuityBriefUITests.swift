import XCTest

@MainActor
final class ManualContinuityBriefUITests: XCTestCase {
    private enum ID {
        static let screen = "manual-continuity-brief-screen"
        static let scroll = "manual-continuity-brief-scroll"
        static let entryCTA = "open-manual-continuity-brief-button"
        static let confirmedSection = "manual-continuity-brief-confirmed-section"
        static let reviewSection = "manual-continuity-brief-review-section"
        static let ambiguitySection = "manual-continuity-brief-ambiguity-section"
        static let agendaSection = "manual-continuity-brief-agenda-section"
        static let evidenceSheet = "manual-continuity-brief-evidence-sheet"
        static let closeEvidence = "close-manual-continuity-brief-evidence"
        static let feedback = "manual-continuity-brief-feedback"
        static let resolutionProposal = "FACEE35C-B205-5EA5-B725-3C9EAEE82589"
        static let candidateAgendaItem = "C8000000-0000-4000-8000-000000000400"
        static let agendaReject = "manual-brief-reject-C8000000-0000-4000-8000-000000000400"
        static let inboxCandidateCard = "proposal-card-C8000000-0000-4000-8000-000000000400"
        static let closeBrief = "close-manual-continuity-brief-button"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEntrySeparatesConfirmedStateFromReviewCandidatesAndDelayKinds() {
        let app = launchSeededApp()
        openBrief(in: app)

        XCTAssertTrue(element(ID.screen, in: app).exists)
        XCTAssertTrue(element(ID.confirmedSection, in: app).exists)
        XCTAssertTrue(staticText("완료된 업무", in: app).exists)

        let deferred = element("manual-brief-delay-deferred", in: app)
        let blocked = element("manual-brief-delay-blocked", in: app)
        let overdue = element("manual-brief-delay-overdue", in: app)
        XCTAssertTrue(deferred.exists)
        XCTAssertTrue(blocked.exists)
        XCTAssertTrue(overdue.exists)
        XCTAssertEqual(displayedText(of: deferred), "지연 후보")
        XCTAssertEqual(displayedText(of: blocked), "차단 후보")
        XCTAssertEqual(displayedText(of: overdue), "기한 초과")

        XCTAssertTrue(element(ID.reviewSection, in: app).exists)
        let completedCandidate = staticText("완료 후보", in: app)
        XCTAssertTrue(completedCandidate.exists)
        let derivedRelation = element("manual-brief-derived-from-decision", in: app)
        XCTAssertTrue(derivedRelation.exists)
    }

    func testEvidenceCanBeOpenedFromAReviewCard() {
        let app = launchSeededApp()
        openBrief(in: app)

        let evidence = firstElement(withIdentifierPrefix: "manual-brief-evidence-", in: app)
        XCTAssertTrue(scrollTo(evidence, in: app), "No evidence control became visible")
        evidence.click()

        XCTAssertTrue(
            element(ID.evidenceSheet, in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons[ID.closeEvidence]
                .waitForExistence(timeout: 5)
        )
    }

    func testIndividualApproveAndRejectActionsHaveNoApproveAllPath() {
        let app = launchSeededApp()
        openBrief(in: app)

        XCTAssertFalse(app.buttons["manual-brief-approve-all"].exists)

        let reviewSection = element(ID.reviewSection, in: app)
        let approveIdentifier = "manual-brief-approve-\(ID.resolutionProposal)"
        let approve = app.buttons.matching(
            NSPredicate(format: "identifier == %@", approveIdentifier)
        ).firstMatch
        XCTAssertTrue(scrollTo(approve, in: app), "No approve action became visible")
        approve.click()
        XCTAssertTrue(waitUntilGone(reviewSection.buttons[approveIdentifier]))

        app.terminate()
        let rejectApp = launchSeededApp()
        openBrief(in: rejectApp)
        let rejectSection = element(ID.reviewSection, in: rejectApp)
        let rejectIdentifier = "manual-brief-reject-\(ID.resolutionProposal)"
        let reject = rejectApp.buttons.matching(
            NSPredicate(format: "identifier == %@", rejectIdentifier)
        ).firstMatch
        XCTAssertTrue(scrollTo(reject, in: rejectApp), "No reject action became visible")
        reject.click()
        XCTAssertTrue(waitUntilGone(rejectSection.buttons[rejectIdentifier]))
    }

    func testAmbiguityOffersExplicitCandidateAndNewChoices() {
        let app = launchSeededApp()
        openBrief(in: app)

        XCTAssertTrue(scrollTo(ID.ambiguitySection, in: app).exists)

        let candidate = firstButton(withIdentifierContaining: "-candidate-", in: app)
        XCTAssertTrue(scrollTo(candidate, in: app), "No prior candidate choice became visible")

        let newChoice = firstButton(
            withIdentifierPrefix: "manual-brief-ambiguity-",
            suffix: "-new",
            in: app
        )
        XCTAssertTrue(scrollTo(newChoice, in: app), "The explicit new-item choice is missing")
        let newChoiceIdentifier = newChoice.identifier
        newChoice.click()
        XCTAssertTrue(waitUntilGone(app.buttons[newChoiceIdentifier]))
    }

    func testNarrowProjectPaneKeepsEntryCTAAndAgendaReachable() {
        let app = launchSeededApp()

        XCTAssertTrue(app.buttons["browse-projects-button"].waitForExistence(timeout: 5))
        app.buttons["browse-projects-button"].click()
        selectSeedProject(in: app)

        let entry = app.buttons[ID.entryCTA]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.isHittable, "The full-width CTA must remain usable in the narrow project pane")
        entry.click()

        XCTAssertTrue(scrollTo(ID.agendaSection, in: app).exists)
        XCTAssertTrue(scrollTo(staticText("다음 회의로 이월", in: app), in: app))
        XCTAssertGreaterThan(
            elements(withIdentifierPrefix: "manual-brief-agenda-", in: app).count,
            0
        )

        // Excluding an agenda candidate has to retire that candidate and nothing else, and the AI
        // 제안 inbox has to agree. Three things regressed here in turn: the verdict landed on
        // whatever carried the item in — the Open Question's resolution, which then vanished with
        // no way to review it again; the excluded item came back on every reopen; and once it
        // stopped coming back here, the inbox went on offering it, because a transition rejection
        // writes only the sidecar. The verdict now lands on the Agenda Item both screens read.
        let agendaReject = app.buttons[ID.agendaReject]
        XCTAssertTrue(scrollTo(agendaReject, in: app), "No agenda exclusion became visible")
        agendaReject.click()
        XCTAssertTrue(waitUntilGone(app.buttons[ID.agendaReject]))
        XCTAssertTrue(
            scrollTo(app.buttons["manual-brief-approve-\(ID.resolutionProposal)"], in: app),
            "Excluding an agenda candidate must leave the unrelated resolution candidate reviewable"
        )

        app.buttons[ID.closeBrief].click()
        XCTAssertTrue(waitUntilGone(element(ID.screen, in: app)))
        XCTAssertTrue(
            waitUntilGone(app.descendants(matching: .any)[ID.inboxCandidateCard]),
            "the inbox must not re-offer the agenda item the Brief excluded"
        )
    }

    // MARK: - Seed journey

    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HAENA_UI_TESTING"] = "1"
        app.launchEnvironment["HAENA_UI_TESTING_MANUAL_BRIEF"] = "1"
        app.launchEnvironment["HAENA_UI_TEST_LANGUAGE"] = "ko"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    private func openBrief(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["browse-projects-button"].waitForExistence(timeout: 5))
        app.buttons["browse-projects-button"].click()
        selectSeedProject(in: app)

        let entry = app.buttons[ID.entryCTA]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.click()

        XCTAssertTrue(
            element(ID.screen, in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element(ID.scroll, in: app)
                .waitForExistence(timeout: 5)
        )
    }

    private func selectSeedProject(in app: XCUIApplication) {
        let projectList = app.descendants(matching: .any)["project-list"]
        XCTAssertTrue(projectList.waitForExistence(timeout: 5))
        let projectName = projectList.staticTexts.matching(
            NSPredicate(format: "value == %@", "Continuity UI Seed")
        ).firstMatch
        XCTAssertTrue(projectName.waitForExistence(timeout: 5))
        projectName.click()
    }

    // MARK: - Accessibility queries

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func staticText(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    private func displayedText(of element: XCUIElement) -> String {
        element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }

    private func elements(
        withIdentifierPrefix prefix: String,
        in app: XCUIApplication
    ) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        )
    }

    private func firstElement(
        withIdentifierPrefix prefix: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        elements(withIdentifierPrefix: prefix, in: app).firstMatch
    }

    private func firstButton(
        withIdentifierPrefix prefix: String,
        suffix: String? = nil,
        in app: XCUIApplication
    ) -> XCUIElement {
        let predicate: NSPredicate
        if let suffix {
            predicate = NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                prefix,
                suffix
            )
        } else {
            predicate = NSPredicate(
                format: "identifier BEGINSWITH %@ AND enabled == true",
                prefix
            )
        }
        return app.buttons.matching(predicate).firstMatch
    }

    private func firstButton(
        withIdentifierContaining fragment: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS %@", fragment)
        ).firstMatch
    }

    @discardableResult
    private func scrollTo(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let target = element(identifier, in: app)
        _ = scrollTo(target, in: app)
        return target
    }

    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        if target.waitForExistence(timeout: 1), target.isHittable {
            return true
        }
        let scrollView = app.scrollViews[ID.screen]
        guard scrollView.waitForExistence(timeout: 2) else {
            return target.exists
        }
        for _ in 0..<24 {
            // A high-velocity swipe can jump over a short review row. Scroll toward the
            // actual target in bounded increments, including back up after an overshoot.
            let delta = target.exists && target.frame.midY < scrollView.frame.midY ? 200.0 : -200.0
            scrollView.scroll(byDeltaX: 0, deltaY: delta)
            if target.waitForExistence(timeout: 0.5), target.isHittable {
                return true
            }
        }
        return target.exists && target.isHittable
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
