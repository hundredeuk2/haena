import XCTest
@testable import HAENA

/// The test this whole subsystem exists to pass.
///
/// A beta metric is the one place in a private, local-only app where a well-meaning change could
/// start writing content into a new file — "just the meeting title, so the report is readable" —
/// and nobody would notice, because the numbers would still look right. So the guarantee is checked
/// three ways over, each of which fails independently:
///
/// 1. **By content.** Every string a real meeting would carry is checked against the encoded bytes,
///    including the bytes actually written to disk.
/// 2. **By structure.** Every string value in the encoded JSON must be a UUID, a known enum case, or
///    a deduplication key — an allow-list, so an unanticipated string fails rather than slipping
///    past a list of things somebody thought to forbid.
/// 3. **By shape.** `BetaMetricEvent` is reflected field by field: exactly one `String` field exists,
///    it is `deduplicationKey`, and its contents are a type prefix and UUIDs. Adding a `String`
///    property to the type — even a nil-by-default optional — fails this test.
///
/// The forbidden samples below are also asserted to be detectable, so a mistake that made the check
/// vacuous (an empty payload, a mis-encoded string) cannot be mistaken for a pass.
final class BetaMetricsPrivacyTests: XCTestCase {
    /// Content of exactly the kinds this app handles. None of it is ever passed to a metrics API —
    /// there is no parameter that would accept it — so its only role here is to be searched for.
    private enum Private {
        static let projectName = "출시 준비"
        static let meetingTitle = "3분기 로드맵 점검 회의"
        static let participantName = "이헌득"
        static let otherParticipantName = "김민준"
        static let transcript = "그럼 배포는 다음 주 화요일로 미루겠습니다"
        static let evidenceQuote = "일정은 QA가 끝난 뒤에 다시 잡기로 했습니다"
        static let notificationBody = "마감이 내일입니다. 지금 확인해 보세요."
        static let actionItemTitle = "배포 체크리스트 정리"
        static let apiKey = "sk-proj-DO-NOT-LEAK-0123456789abcdef"

        static let samples = [
            projectName, meetingTitle, participantName, otherParticipantName, transcript,
            evidenceQuote, notificationBody, actionItemTitle, apiKey
        ]

        /// Field names that would betray a content-carrying schema even if the value happened to be
        /// empty on the day the test ran. Checked against the decoded key set rather than against
        /// the raw bytes, because a legitimate enum case can contain one of these as a substring —
        /// `pastedText` is a capture source, not a leak.
        static let forbiddenFieldNames = [
            "title", "name", "quote", "transcript", "body", "apiKey", "summary", "statement",
            "rationale", "details", "displayName", "speaker", "text", "note", "content"
        ]
    }

    private static let projectID = UUID(uuidString: "33000000-0000-0000-0000-000000000001")!
    private static let meetingID = UUID(uuidString: "33000000-0000-0000-0000-000000000002")!
    private static let proposalID = UUID(uuidString: "33000000-0000-0000-0000-000000000003")!
    private static let runID = UUID(uuidString: "33000000-0000-0000-0000-000000000004")!
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every field name the schema is allowed to have. Exact equality, not a subset: a new key
    /// arrives here deliberately or not at all.
    private static let allowedKeys: Set<String> = [
        "schemaVersion", "measurementStartedAt", "events",
        "id", "deduplicationKey", "type", "occurredAt",
        "projectID", "meetingID", "proposalID", "proposalKind",
        "verdict", "fieldCategory", "captureSource", "outcome",
        "durationMilliseconds", "resultCount", "extractionPhase"
    ]

    private static let allowedEnumRawValues: Set<String> = Set(
        BetaMetricEventType.allCases.map(\.rawValue)
            + BetaMetricExtractionPhase.allCases.map(\.rawValue)
            + BetaMetricVerdict.allCases.map(\.rawValue)
            + BetaMetricProposalKind.allCases.map(\.rawValue)
            + BetaMetricFieldCategory.allCases.map(\.rawValue)
            + BetaMetricCaptureSource.allCases.map(\.rawValue)
            + BetaMetricOutcome.allCases.map(\.rawValue)
    )

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-BetaMetricsPrivacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory!) }
    }

    // MARK: - The check itself has to be capable of failing

    /// Guards against a vacuous pass. If the containment check could not find these strings even in
    /// a payload built to contain them, every assertion below would succeed for the wrong reason.
    func testTheForbiddenContentCheckDetectsContentWhenItIsPresent() throws {
        let control = try XCTUnwrap(
            String(data: try JSONEncoder().encode(Private.samples + Private.forbiddenFieldNames), encoding: .utf8)
        )

        for sample in Private.samples + Private.forbiddenFieldNames {
            XCTAssertTrue(
                control.localizedCaseInsensitiveContains(sample),
                "The detector must be able to find \(sample); otherwise this suite proves nothing."
            )
        }
        XCTAssertFalse(Private.samples.isEmpty)
    }

    // MARK: - By content

    /// A store holding one of every event type, every optional populated, encoded exactly as the
    /// repository encodes it. Nothing a meeting carries may appear in the bytes.
    func testAFullyPopulatedStoreEncodesWithoutAnyMeetingContent() throws {
        let json = try encodedString(of: fullyPopulatedStore())

        for sample in Private.samples {
            XCTAssertFalse(
                json.localizedCaseInsensitiveContains(sample),
                "Beta metrics JSON must not contain \(sample)."
            )
        }
        // Nothing outside ASCII at all: every Korean string this app handles would show up here,
        // including one nobody thought to add to the sample list above.
        XCTAssertTrue(
            json.allSatisfy { $0.isASCII },
            "Beta metrics JSON is identifiers, enum cases and numbers — all of them ASCII."
        )
    }

    /// The same guarantee for the bytes that actually land on the user's disk, recorded through the
    /// real service and the real JSON repository rather than a hand-built value. Note what the
    /// record calls take: identifiers and enum cases. The content above is in scope here and there
    /// is no parameter it could have been passed to.
    func testTheFileWrittenToDiskContainsNoMeetingContent() async throws {
        let url = directory.appendingPathComponent("beta-metrics.json")
        let repository = JSONBetaMetricsRepository(fileURL: url, now: { Self.now })
        let service = BetaMetricsService(repository: repository, now: { Self.now }, makeID: { UUID() })

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: .recordedAudio,
            resultCount: 12
        )
        await service.recordProcessingDuration(
            runID: Self.runID,
            source: .recordedAudio,
            outcome: .succeeded,
            milliseconds: 8_421,
            meetingID: Self.meetingID
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            verdict: .approved
        )
        await service.recordProposalModified(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: .actionItem,
            field: .assignee
        )

        let onDisk = try XCTUnwrap(String(data: try Data(contentsOf: url), encoding: .utf8))
        for sample in Private.samples {
            XCTAssertFalse(
                onDisk.localizedCaseInsensitiveContains(sample),
                "beta-metrics.json on disk must not contain \(sample)."
            )
        }
        XCTAssertTrue(onDisk.allSatisfy { $0.isASCII }, "Nothing outside ASCII reaches the file.")

        let store = try await repository.store()
        XCTAssertEqual(store.events.count, 4, "One of every event type was recorded")
        try assertOnlyAllowedStrings(in: store)
        try assertDeduplicationKeysAreTypePrefixesAndUUIDs(in: store)
    }

    // MARK: - By structure

    /// An allow-list rather than a deny-list: every string in the encoded document must be something
    /// the schema is known to produce. A future field carrying a name nobody thought to forbid fails
    /// here, which is the point — a deny-list only catches leaks somebody already imagined.
    func testEveryStringInTheEncodedDocumentIsAUUIDAnEnumCaseOrADeduplicationKey() throws {
        try assertOnlyAllowedStrings(in: fullyPopulatedStore())
    }

    func testTheEncodedDocumentHasExactlyTheExpectedFieldNames() throws {
        let (keys, _) = try inspected(fullyPopulatedStore())
        XCTAssertEqual(
            keys,
            Self.allowedKeys,
            "Every optional is populated in this fixture, so the key set is exact in both directions."
        )

        for key in keys {
            for fieldName in Private.forbiddenFieldNames {
                XCTAssertFalse(
                    key.localizedCaseInsensitiveContains(fieldName),
                    "\(key) reads like a content-carrying field."
                )
            }
        }
    }

    /// A key is a type prefix and UUIDs, joined by colons — nothing else, and nothing outside ASCII,
    /// so a Korean title could not have been folded into one even as a "harmless" suffix.
    func testDeduplicationKeysAreBuiltOnlyFromATypePrefixAndUUIDs() throws {
        try assertDeduplicationKeysAreTypePrefixesAndUUIDs(in: fullyPopulatedStore())
    }

    // MARK: - By shape

    /// Reflection over the stored properties. This is the assertion that survives a refactor: it
    /// fails when a `String` field is added, whatever it is called and whether or not it happens to
    /// be populated, because the check is on the declared type rather than on a sampled value.
    func testBetaMetricEventDeclaresExactlyOneStringFieldAndItIsTheDeduplicationKey() {
        let mirror = Mirror(reflecting: fullyPopulatedEvent(type: .proposalReviewed))
        let labels = mirror.children.compactMap(\.label)

        XCTAssertEqual(
            labels,
            [
                "id", "deduplicationKey", "type", "occurredAt", "projectID", "meetingID",
                "proposalID", "proposalKind", "verdict", "fieldCategory", "captureSource",
                "outcome", "durationMilliseconds", "resultCount", "extractionPhase"
            ],
            "A changed field list is a schema change and must be reviewed here first."
        )

        var stringFields: [String] = []
        for child in mirror.children {
            let label = child.label ?? "<unlabelled>"
            let declaredType = String(describing: type(of: child.value))
            if declaredType.contains("String") {
                stringFields.append(label)
            }
            // Nothing may hide inside an optional either: unwrap and re-check the payload.
            if let unwrapped = Self.unwrapOptional(child.value), unwrapped is String {
                XCTAssertEqual(label, "deduplicationKey", "\(label) carries a String payload.")
            }
        }

        XCTAssertEqual(
            stringFields,
            ["deduplicationKey"],
            "BetaMetricEvent must keep exactly one String field. Anything else can hold a title."
        )
    }

    /// The same shape check applied to the envelope, so a "note" or "label" field cannot be added
    /// one level up from the events either.
    func testTheStoreEnvelopeDeclaresNoStringFields() {
        let mirror = Mirror(reflecting: fullyPopulatedStore())
        let labels = mirror.children.compactMap(\.label)
        XCTAssertEqual(labels, ["schemaVersion", "measurementStartedAt", "events"])

        for child in mirror.children where child.label != "events" {
            XCTAssertFalse(
                String(describing: type(of: child.value)).contains("String"),
                "\(child.label ?? "<unlabelled>") must not be a String."
            )
        }
    }

    /// The recording API is the other half of the guarantee: a caller holding a meeting title has
    /// nowhere to put it. Asserted here as a property of the values that come out — every field a
    /// service-produced event populates is an identifier, an enum case, or a number.
    func testServiceProducedEventsCarryOnlyIdentifiersEnumCasesAndNumbers() async throws {
        let repository = InMemoryBetaMetricsRepository()
        let service = BetaMetricsService(repository: repository, now: { Self.now }, makeID: { UUID() })

        await service.recordMeetingProcessed(
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            source: BetaMetricCaptureSource(.microphone),
            resultCount: 3
        )
        await service.recordProposalReviewed(
            projectID: Self.projectID,
            proposalID: Self.proposalID,
            kind: BetaMetricProposalKind(.openQuestion),
            verdict: .excluded
        )

        let store = await repository.store()
        for event in store.events {
            for child in Mirror(reflecting: event).children {
                guard let unwrapped = Self.unwrapOptional(child.value) else { continue }
                switch unwrapped {
                case is UUID, is Date, is Int:
                    continue
                case let string as String:
                    XCTAssertEqual(child.label, "deduplicationKey")
                    XCTAssertTrue(string.allSatisfy { $0.isASCII })
                default:
                    XCTAssertTrue(
                        Self.allowedEnumRawValues.contains(String(describing: unwrapped)),
                        "\(child.label ?? "?") holds \(unwrapped), which is not a known enum case."
                    )
                }
            }
        }
    }

    // MARK: - Shared assertions

    private func assertOnlyAllowedStrings(
        in store: BetaMetricsStoreFile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (_, strings) = try inspected(store)
        let deduplicationKeys = Set(store.events.map(\.deduplicationKey))

        XCTAssertFalse(strings.isEmpty, "A store with events must encode some strings to check.", file: file, line: line)
        for string in strings {
            let isAllowed = UUID(uuidString: string) != nil
                || Self.allowedEnumRawValues.contains(string)
                || deduplicationKeys.contains(string)
            XCTAssertTrue(
                isAllowed,
                "Unexpected string in beta metrics JSON: \(string)",
                file: file,
                line: line
            )
        }
    }

    private func assertDeduplicationKeysAreTypePrefixesAndUUIDs(
        in store: BetaMetricsStoreFile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(store.events.isEmpty, file: file, line: line)
        for event in store.events {
            let key = event.deduplicationKey
            XCTAssertTrue(key.allSatisfy { $0.isASCII }, "Non-ASCII in \(key)", file: file, line: line)
            // An allow-list, deliberately: a key is a type prefix, one identifier, and at most one
            // further finite enum case. Anything else — including a component that merely looks
            // harmless — fails, because the whole point is that nothing a user typed can reach here.
            let components = key.components(separatedBy: ":")
            XCTAssertTrue(
                (2...3).contains(components.count),
                "Malformed key: \(key)",
                file: file,
                line: line
            )
            XCTAssertNotNil(
                BetaMetricEventType(rawValue: components[0]),
                "\(components[0]) is not an event type prefix.",
                file: file,
                line: line
            )
            XCTAssertNotNil(
                UUID(uuidString: components[1]),
                "\(components[1]) in \(key) is not a UUID.",
                file: file,
                line: line
            )
            if components.count == 3 {
                XCTAssertNotNil(
                    BetaMetricFieldCategory(rawValue: components[2]),
                    "\(components[2]) in \(key) is not a known field category.",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - Plumbing

    /// Encoded the way `JSONBetaMetricsRepository` encodes, so what is inspected is what is written.
    private func encodedString(of store: BetaMetricsStoreFile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(String(data: try encoder.encode(store), encoding: .utf8))
    }

    /// Every field name and every string value in the encoded document, gathered by walking the
    /// decoded JSON rather than by trusting the Swift types.
    private func inspected(_ store: BetaMetricsStoreFile) throws -> (keys: Set<String>, strings: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(store))
        var keys = Set<String>()
        var strings: [String] = []
        Self.walk(object, keys: &keys, strings: &strings)
        return (keys, strings)
    }

    private static func walk(_ value: Any, keys: inout Set<String>, strings: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                keys.insert(key)
                walk(child, keys: &keys, strings: &strings)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(child, keys: &keys, strings: &strings)
            }
        } else if let string = value as? String {
            strings.append(string)
        }
    }

    private static func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    /// Every optional populated, so nothing escapes inspection by happening to be nil.
    private func fullyPopulatedEvent(type: BetaMetricEventType) -> BetaMetricEvent {
        BetaMetricEvent(
            id: UUID(uuidString: "33000000-0000-0000-0000-0000000000\(String(format: "%02d", type.hashIndex))")!,
            deduplicationKey: "\(type.rawValue):\(Self.proposalID.uuidString.lowercased())",
            type: type,
            occurredAt: Self.now,
            projectID: Self.projectID,
            meetingID: Self.meetingID,
            proposalID: Self.proposalID,
            proposalKind: .actionItem,
            verdict: .approved,
            fieldCategory: .dueDate,
            captureSource: .importedAudio,
            outcome: .succeeded,
            durationMilliseconds: 8_421,
            resultCount: 12,
            extractionPhase: .providerReturned
        )
    }

    private func fullyPopulatedStore() -> BetaMetricsStoreFile {
        BetaMetricsStoreFile(
            measurementStartedAt: Self.now,
            events: BetaMetricEventType.allCases.map { fullyPopulatedEvent(type: $0) }
        )
    }
}

private extension BetaMetricEventType {
    /// A stable small integer per case, only so the fixtures above get distinct event ids.
    var hashIndex: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}
