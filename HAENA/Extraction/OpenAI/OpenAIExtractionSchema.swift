import Foundation

/// The JSON Schema sent as a Structured Output contract, plus the instructions that go with it.
///
/// Both encode the same extraction rules from two directions: the schema makes a malformed shape
/// impossible, and the instructions make an *ungrounded* one unlikely. Neither alone is enough —
/// the schema cannot tell whether a quote is real, so `WorkStateProposalMapper` re-checks every
/// quote against the stored transcript regardless of what the model returns.
enum OpenAIExtractionSchema {
    static let name = "work_state_extraction"

    static let instructions = """
    You extract work state from meeting transcripts for a project tracking app.

    Rules:
    - Only extract what the transcript explicitly states or strongly supports. Never infer beyond it.
    - Never guess an assignee, a due date, or whether something was decided. If the transcript does \
    not say, use null.
    - Keep the transcript's own language. Korean stays Korean, English stays English, mixed stays mixed. \
    Do not translate.
    - Categories are distinct: `decisions` are choices that were actually made; `action_items` are tasks \
    someone is expected to do; `open_questions` are questions raised but not answered; \
    `next_agenda_items` are topics to carry into the next meeting.
    - Every item needs exactly one evidence object. `segment_id` must be one of the segment ids given \
    below, and `quote` must be copied character-for-character from that segment's text. Do not \
    paraphrase, translate, shorten with ellipses, fix typos, or change punctuation in a quote.
    - `confidence` is between 0 and 1 and reflects how clearly the transcript supports the item.
    - Do not repeat the same item across categories or within one category.
    - If a category has nothing that meets these rules, return an empty array for it. An empty result \
    is a correct answer.
    """

    /// Built rather than hard-coded so the evidence sub-schema is defined once. Strict mode
    /// requires every property to be listed in `required` and every object to set
    /// `additionalProperties: false`; genuinely optional fields are expressed as `["string", "null"]`.
    static func schema() -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
                .string("decisions"),
                .string("action_items"),
                .string("open_questions"),
                .string("next_agenda_items")
            ]),
            "properties": .object([
                "decisions": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("statement"), .string("rationale"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "statement": describedString("The decision that was made, in the transcript's language."),
                        "rationale": nullableString("Why it was decided, only if stated. Otherwise null."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "action_items": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("title"),
                        .string("details"),
                        .string("assignee_name"),
                        .string("due_date"),
                        .string("confidence"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "title": describedString("The task to be done."),
                        "details": nullableString("Extra detail stated in the transcript, else null."),
                        "assignee_name": nullableString("The person's name exactly as spoken, only if the transcript names an owner. Otherwise null."),
                        "due_date": nullableString("Due date as YYYY-MM-DD, only if the transcript states an unambiguous date. Otherwise null."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "open_questions": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("question"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "question": describedString("A question raised but left unanswered."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "next_agenda_items": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("title"), .string("reason"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "title": describedString("A topic for the next meeting."),
                        "reason": describedString("Why it needs to be on the next agenda."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ]))
            ])
        ])
    }

    // MARK: - Building blocks

    private static let evidence = JSONValue.object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("segment_id"), .string("quote")]),
        "properties": .object([
            "segment_id": describedString("The id of the transcript segment this item came from, copied from the input."),
            "quote": describedString("A verbatim substring of that segment's text. Copy it exactly.")
        ])
    ])

    private static let confidence = JSONValue.object([
        "type": .string("number"),
        "minimum": .number(0),
        "maximum": .number(1),
        "description": .string("How strongly the transcript supports this item, from 0 to 1.")
    ])

    private static func array(of items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }

    private static func describedString(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func nullableString(_ description: String) -> JSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "description": .string(description)
        ])
    }
}
