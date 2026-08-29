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
    not support an individual or team owner, use `assignee_basis: "unspecified"` with both assignee \
    fields null.
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
    - Give every extracted decision, action item, open question, and next agenda item a unique \
    `provider_key`. Use the exact kind prefix and a positive ordinal: `decision_1`, `action_1`, \
    `question_1`, or `agenda_1`. A key may contain only lowercase ASCII letters, digits, and \
    underscores and must be at most 32 characters. Never put transcript text, a person's name, or \
    a UUID in a key. Relationship signals may refer to new work state only by these keys.

    Continuity signal rules:
    - Return a signal only when the current transcript explicitly provides its evidence. Do not infer \
    that work is probably complete, deferred, or blocked, and do not infer progress from emotion, tone, \
    or conversational mood. Do not use keyword matching as a substitute for the stated meaning.
    - A `progress_signals` entry names exactly one target. Set `target_type` to \
    `incoming_action_item` and `target_reference` to that item's `provider_key` when the task is also \
    extracted in this payload; set `target_type` to `prior_action_item` and `target_reference` to a \
    supplied `prior_action_*` reference when the meeting only reports on work that already exists. \
    Reporting that existing work is done, postponed, or stuck is NOT a new action item: use the \
    prior reference and do not invent an action item to carry the signal. Create the entry only when \
    the cited words explicitly ground `completed`, `deferred`, or `blocked`.
    - A `decision_change_links` entry says an incoming decision revises an approved earlier one. Set \
    `prior_decision_reference` to a supplied `prior_decision_*` reference and `decision_key` to the \
    `provider_key` of a decision you returned in this payload. Create it only when the transcript \
    explicitly revises that earlier decision; never link by topic similarity.
    - An `open_question_resolution_links` entry refers to an approved earlier question only by the \
    supplied `prior_question_*` opaque reference. Create it only when there is an actual answer or an \
    explicit follow-up disposition. A target of `agenda_item` means the question is carried forward, \
    not resolved.
    - A `decision_derived_action_item_links` entry requires an explicit decision-to-action relationship. \
    Set exactly one of `incoming_decision_key` and `prior_decision_ref`; set the other to null. A prior \
    decision may be referenced only by a supplied `prior_decision_*` opaque reference.
    - Never manipulate or fabricate a base proposal in order to create a signal. If evidence is \
    insufficient, omit that signal. If there are no qualifying signals, return all three signal arrays \
    as empty arrays.

    Assignee attribution rules for every action item:
    - Use exactly one `assignee_basis`: `explicit_name`, `self_reference`, `speaker_commitment`, \
    `team_or_role`, or `unspecified`.
    - `explicit_name`: another person is explicitly named. Copy that expression into \
    `assignee_reference`; `assignee_speaker` must be null. Example request: A says \
    "민수님, 보고서 작성해 주세요." -> reference "민수님", speaker null.
    - `self_reference`: the actual assignee uses a singular self-reference. Both fields are required; \
    copy the self-reference and the opaque speaker label from the input. Example promise: B says \
    "제가 보고서를 작성하겠습니다." -> reference "제가", speaker "B".
    - `speaker_commitment`: the actual assignee promises to act with an omitted subject. \
    `assignee_speaker` is required and `assignee_reference` may be null. Example promise: B says \
    "보고서를 작성하겠습니다." -> reference null, speaker "B".
    - `team_or_role`: a team, department, or role owns the task, not an individual. Copy that \
    expression into `assignee_reference`; `assignee_speaker` must be null. Example: A says \
    "우리 팀에서 검토하겠습니다." -> reference "우리 팀", speaker null.
    - `unspecified`: no supported owner. Both fields must be null. An unnamed request such as \
    "검토해 주세요." does not identify the addressee and stays unspecified.
    - For `self_reference` and `speaker_commitment`, cite the assignee's own acceptance or promise, \
    not an earlier request from someone else. Never return a participant UUID or invent a speaker \
    label; copy only an input `[speaker: ...]` value.
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
                .string("next_agenda_items"),
                .string("progress_signals"),
                .string("open_question_resolution_links"),
                .string("decision_derived_action_item_links"),
                .string("decision_change_links")
            ]),
            "properties": .object([
                "decisions": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("provider_key"), .string("statement"), .string("rationale"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "provider_key": providerLocalKey(prefix: "decision", "A payload-local opaque key for this decision."),
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
                        .string("provider_key"),
                        .string("assignee_basis"),
                        .string("assignee_reference"),
                        .string("assignee_speaker"),
                        .string("due_date"),
                        .string("confidence"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "provider_key": providerLocalKey(prefix: "action", "A payload-local opaque key for this action item."),
                        "title": describedString("The task to be done."),
                        "details": nullableString("Extra detail stated in the transcript, else null."),
                        "assignee_basis": .object([
                            "type": .string("string"),
                            "enum": .array(
                                AssigneeAttributionBasis.allCases.map { .string($0.rawValue) }
                            ),
                            "description": .string("The exact attribution rule supporting the assignee fields.")
                        ]),
                        "assignee_reference": nullableString("The exact assignee expression from the transcript when required by the basis; otherwise null."),
                        "assignee_speaker": nullableString("The opaque input speaker label only for self_reference or speaker_commitment; otherwise null. Never a participant UUID."),
                        "due_date": nullableString("Due date as YYYY-MM-DD, only if the transcript states an unambiguous date. Otherwise null."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "open_questions": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("provider_key"), .string("question"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "provider_key": providerLocalKey(prefix: "question", "A payload-local opaque key for this open question."),
                        "question": describedString("A question raised but left unanswered."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "next_agenda_items": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("provider_key"), .string("title"), .string("reason"), .string("confidence"), .string("evidence")]),
                    "properties": .object([
                        "provider_key": providerLocalKey(prefix: "agenda", "A payload-local opaque key for this next agenda item."),
                        "title": describedString("A topic for the next meeting."),
                        "reason": describedString("Why it needs to be on the next agenda."),
                        "confidence": confidence,
                        "evidence": evidence
                    ])
                ])),
                "progress_signals": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("kind"),
                        .string("target_type"),
                        .string("target_reference"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "kind": stringEnum(["completed", "deferred", "blocked"], "The explicitly grounded action-item progress state."),
                        "target_type": stringEnum(
                            ["incoming_action_item", "prior_action_item"],
                            "Whether the target is an action item in this payload or a supplied prior action item."
                        ),
                        "target_reference": progressTargetReference(
                            "The incoming action item provider_key when target_type is incoming_action_item, or the supplied opaque prior_action reference when it is prior_action_item."
                        ),
                        "evidence": evidence
                    ])
                ])),
                "decision_change_links": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("prior_decision_reference"),
                        .string("decision_key"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "prior_decision_reference": priorReference(prefix: "decision", "The supplied opaque prior_decision reference this decision revises."),
                        "decision_key": providerLocalKey(prefix: "decision", "The provider_key of the incoming decision that replaces it."),
                        "evidence": evidence
                    ])
                ])),
                "open_question_resolution_links": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("prior_open_question_ref"),
                        .string("target_kind"),
                        .string("target_key"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "prior_open_question_ref": priorReference(prefix: "question", "The supplied opaque prior_question reference."),
                        "target_kind": stringEnum(["decision", "action_item", "agenda_item"], "The kind of incoming target."),
                        "target_key": providerLocalTargetKey("The provider_key of the incoming target."),
                        "evidence": evidence
                    ])
                ])),
                "decision_derived_action_item_links": array(of: .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("incoming_decision_key"),
                        .string("prior_decision_ref"),
                        .string("action_item_key"),
                        .string("evidence")
                    ]),
                    "properties": .object([
                        "incoming_decision_key": nullableProviderLocalKey(prefix: "decision", "The incoming decision provider_key, or null when prior_decision_ref is used."),
                        "prior_decision_ref": nullablePriorReference(prefix: "decision", "The supplied opaque prior_decision reference, or null when incoming_decision_key is used."),
                        "action_item_key": providerLocalKey(prefix: "action", "The provider_key of the incoming derived action item."),
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

    private static func providerLocalKey(prefix: String, _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "pattern": .string("^\(prefix)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    private static func nullableProviderLocalKey(prefix: String, _ description: String) -> JSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "pattern": .string("^\(prefix)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    /// One field carries either shape, so the pattern admits both and `target_type` decides which
    /// namespace it is read in. A key that does not match its declared type is rejected by the
    /// mapper rather than by the schema — the two are different failures and only the mapper can
    /// tell them apart.
    private static func progressTargetReference(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "pattern": .string("^(action|prior_action)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    private static func providerLocalTargetKey(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "pattern": .string("^(decision|action|agenda)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    private static func priorReference(prefix: String, _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "pattern": .string("^prior_\(prefix)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    private static func nullablePriorReference(prefix: String, _ description: String) -> JSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "pattern": .string("^prior_\(prefix)_[1-9][0-9]{0,5}$"),
            "maxLength": .number(32),
            "description": .string(description)
        ])
    }

    private static func stringEnum(_ values: [String], _ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string)),
            "description": .string(description)
        ])
    }
}
