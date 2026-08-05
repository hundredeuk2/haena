import Foundation

/// The single definition of "this record is an AI proposal still waiting on a person's verdict."
///
/// Two very different consumers need to agree on exactly this question: the review inbox (what to
/// show) and meeting re-extraction (what to replace). Before this type existed each computed its
/// own predicate, and they drifted — `WorkStateExtractionService` required `evidence != nil` for
/// Decision/ActionItem, but `WorkStateInbox` did not — so an evidence-less `.proposed` Decision
/// could appear in the review list yet never be cleaned up by a later extraction. This type is now
/// the only place either question is answered; both callers filter through it rather than
/// reimplementing it.
///
/// `evidence != nil` is the load-bearing condition for every case, not an incidental one: it is
/// what separates something a model actually proposed from something a person typed in — the
/// review flow and the re-extraction flow must both treat a hand-entered record as belonging to
/// its author, not to the last model run.
enum PendingAIProposalPolicy {
    static func isPending(_ decision: Decision) -> Bool {
        decision.status == .proposed && decision.evidence != nil
    }

    static func isPending(_ actionItem: ActionItem) -> Bool {
        actionItem.status == .proposed && actionItem.evidence != nil
    }

    /// `OpenQuestionStatus` has no `.proposed` case — `.open` is shared by a fresh proposal and an
    /// approved-but-still-open question, so `reviewedAt` is what tells them apart.
    static func isPending(_ question: OpenQuestion) -> Bool {
        question.status == .open && question.reviewedAt == nil && question.evidence != nil
    }

    /// Same reasoning as `OpenQuestion`: `.pending` alone cannot distinguish a fresh suggestion
    /// from one a user already approved for the next agenda.
    static func isPending(_ agendaItem: AgendaItem) -> Bool {
        agendaItem.status == .pending && agendaItem.reviewedAt == nil && agendaItem.evidence != nil
    }
}
