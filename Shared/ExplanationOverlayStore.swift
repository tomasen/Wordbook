import Foundation

enum ExplanationFeedbackRating: String, Codable, Equatable, Sendable {
    case like
    case dislike
}

enum ExplanationFeedbackComponent: String, Codable, Equatable, Sendable {
    case whole
    case meaning
    case memoryAid
}

struct ExplanationFeedbackEvent: Equatable, Sendable {
    let eventID: UUID
    let explanationID: String
    let normalizedForm: String
    let senseID: String
    let rating: ExplanationFeedbackRating
    let component: ExplanationFeedbackComponent
    let requestReplacement: Bool
    let createdAt: Date
    let attemptCount: Int

    init(
        eventID: UUID = UUID(),
        explanationID: String,
        normalizedForm: String,
        senseID: String,
        rating: ExplanationFeedbackRating,
        component: ExplanationFeedbackComponent = .whole,
        requestReplacement: Bool = false,
        createdAt: Date = Date(),
        attemptCount: Int = 0
    ) {
        self.eventID = eventID
        self.explanationID = explanationID
        self.normalizedForm = normalizedForm
        self.senseID = senseID
        self.rating = rating
        self.component = component
        self.requestReplacement = requestReplacement
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

enum ExplanationOverlayStoreError: LocalizedError {
    case applicationSupportUnavailable
    case unsupportedApplicationID(expected: Int64, actual: Int64)
    case unsupportedSchemaVersion(maximum: Int64, actual: Int64)
    case invalidExplanation(String)
    case immutableExplanationConflict(String)
    case selectionUnavailable(form: String, senseID: String, explanationID: String)
    case invalidStoredJSON(field: String, explanationID: String)
    case invalidStoredMorphology(form: String, senseID: String)
    case invalidStoredMemoryTechnique(String, explanationID: String)
    case invalidFeedback(String)
    case feedbackIdempotencyConflict(UUID)
    case invalidStoredFeedbackID(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .unsupportedApplicationID(let expected, let actual):
            return "This is not a Wordbook explanation overlay (expected application ID \(expected), found \(actual))."
        case .unsupportedSchemaVersion(let maximum, let actual):
            return "The explanation overlay uses schema \(actual), but this app supports up to schema \(maximum)."
        case .invalidExplanation(let reason):
            return "The server explanation was not stored because \(reason)."
        case .immutableExplanationConflict(let explanationID):
            return "Explanation \(explanationID) was reused with different immutable content."
        case .selectionUnavailable(let form, let senseID, let explanationID):
            return "Explanation \(explanationID) is not available for \(form) / \(senseID)."
        case .invalidStoredJSON(let field, let explanationID):
            return "Explanation \(explanationID) has invalid stored \(field) data."
        case .invalidStoredMorphology(let form, let senseID):
            return "The overlay morphology for \(form) / \(senseID) is invalid."
        case .invalidStoredMemoryTechnique(let value, let explanationID):
            return "Explanation \(explanationID) has an unknown memory technique: \(value)."
        case .invalidFeedback(let reason):
            return "The feedback event was not queued because \(reason)."
        case .feedbackIdempotencyConflict(let eventID):
            return "Feedback event \(eventID.uuidString) was reused with a different payload."
        case .invalidStoredFeedbackID(let value):
            return "The feedback outbox contains an invalid event UUID: \(value)."
        }
    }
}

/// Application-owned overlay for validated server explanation revisions.
///
/// This store never opens, attaches, copies, or migrates the bundled content
/// pack. A caller can therefore resolve this overlay first and safely fall back
/// to `OfflineExplanationStore` without giving writable code access to the
/// immutable base database.
final class ExplanationOverlayStore: @unchecked Sendable {
    static let applicationID: Int64 = 1_463_963_478
    static let schemaVersion: Int64 = 1

    private let database: SQLiteWritableDatabase
    private let now: @Sendable () -> Date

    convenience init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let databaseURL = try Self.applicationSupportDatabaseURL(fileManager: fileManager)
        try self.init(databaseURL: databaseURL, fileManager: fileManager, now: now)
    }

    init(
        databaseURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try Self.preflightExistingDatabase(at: databaseURL, fileManager: fileManager)
        database = try SQLiteWritableDatabase(url: databaseURL, fileManager: fileManager)
        self.now = now
        try migrateIfNeeded()
    }

    static func applicationSupportDatabaseURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ExplanationOverlayStoreError.applicationSupportUnavailable
        }
        return applicationSupportURL
            .appendingPathComponent("Wordbook", isDirectory: true)
            .appendingPathComponent("wordbook-overlay.sqlite", isDirectory: false)
    }

    /// Persists an already validated server result as an immutable variant.
    /// The exact form and morphology supplied by the server are retained; no
    /// stemming or morphology guessing happens in this layer.
    func storeValidatedServerExplanation(
        _ record: OfflineVocabularyExplanation,
        selectForForm: Bool = true,
        makeDefaultForForm: Bool = true
    ) throws {
        try Self.validate(record)

        let morphologyJSON = try Self.encodeMorphology(record.morphology)
        let memoryAidJSON = try Self.encodeStringArray(record.explanation.memoryAid)
        let synonymsJSON = try Self.encodeStringArray(record.explanation.synonyms)
        let memoryTechnique = record.explanation.memoryTechnique?.rawValue
        let storedAt = Self.milliseconds(since1970: now())

        try database.withTransaction {
            try database.execute(
                """
                INSERT INTO explanation_variant (
                    explanation_id,
                    sense_id,
                    content_hash,
                    schema_version,
                    part_of_speech,
                    meaning,
                    example,
                    memory_technique,
                    memory_aid_json,
                    synonyms_json,
                    stored_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (explanation_id) DO NOTHING
                """,
                bindings: [
                    .text(record.explanationID),
                    .text(record.senseID),
                    .text(record.contentHash),
                    .integer(Int64(record.schemaVersion)),
                    .text(record.explanation.partOfSpeech),
                    .text(record.explanation.meaning),
                    .text(record.explanation.example),
                    memoryTechnique.map(SQLiteWritableBinding.text) ?? .null,
                    .text(memoryAidJSON),
                    .text(synonymsJSON),
                    .integer(storedAt),
                ]
            )

            guard try storedVariantMatches(
                record,
                memoryAidJSON: memoryAidJSON,
                synonymsJSON: synonymsJSON
            ) else {
                throw ExplanationOverlayStoreError.immutableExplanationConflict(
                    record.explanationID
                )
            }

            try database.execute(
                """
                INSERT INTO overlay_word_form (
                    normalized_form,
                    sense_id,
                    display_form,
                    lemma,
                    part_of_speech,
                    morphology_json
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (normalized_form, sense_id) DO UPDATE SET
                    display_form = excluded.display_form,
                    lemma = excluded.lemma,
                    part_of_speech = excluded.part_of_speech,
                    morphology_json = excluded.morphology_json
                """,
                bindings: [
                    .text(record.normalizedForm),
                    .text(record.senseID),
                    .text(record.displayForm),
                    .text(record.lemma),
                    .text(record.explanation.partOfSpeech),
                    .text(morphologyJSON),
                ]
            )

            if selectForForm {
                try database.execute(
                    """
                    INSERT INTO explanation_selection (
                        normalized_form,
                        sense_id,
                        explanation_id,
                        selected_at_ms
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT (normalized_form, sense_id) DO UPDATE SET
                        explanation_id = excluded.explanation_id,
                        selected_at_ms = excluded.selected_at_ms
                    """,
                    bindings: [
                        .text(record.normalizedForm),
                        .text(record.senseID),
                        .text(record.explanationID),
                        .integer(storedAt),
                    ]
                )
            }

            if makeDefaultForForm {
                let hasSelection = try database.queryOne(
                    """
                    SELECT 1
                      FROM explanation_selection
                     WHERE normalized_form = ? AND sense_id = ?
                     LIMIT 1
                    """,
                    bindings: [.text(record.normalizedForm), .text(record.senseID)]
                ) { row in
                    try row.integer(at: 0)
                } != nil
                if hasSelection {
                    try database.execute(
                        """
                        INSERT INTO overlay_form_default (normalized_form, sense_id)
                        VALUES (?, ?)
                        ON CONFLICT (normalized_form) DO UPDATE SET
                            sense_id = excluded.sense_id
                        """,
                        bindings: [
                            .text(record.normalizedForm),
                            .text(record.senseID),
                        ]
                    )
                }
            }
        }
    }

    /// Selects a previously stored immutable variant for one exact form/sense.
    func selectVariant(
        explanationID: String,
        forForm form: String,
        senseID: String,
        makeDefaultForForm: Bool = true
    ) throws {
        let normalizedForm = OfflineExplanationStore.normalizeForm(form)
        let timestamp = Self.milliseconds(since1970: now())

        try database.withTransaction {
            let available = try database.queryOne(
                """
                SELECT 1
                  FROM overlay_word_form AS wf
                  JOIN explanation_variant AS e ON e.sense_id = wf.sense_id
                 WHERE wf.normalized_form = ?
                   AND wf.sense_id = ?
                   AND e.explanation_id = ?
                 LIMIT 1
                """,
                bindings: [.text(normalizedForm), .text(senseID), .text(explanationID)]
            ) { row in
                try row.integer(at: 0)
            } != nil
            guard available else {
                throw ExplanationOverlayStoreError.selectionUnavailable(
                    form: normalizedForm,
                    senseID: senseID,
                    explanationID: explanationID
                )
            }

            try database.execute(
                """
                INSERT INTO explanation_selection (
                    normalized_form,
                    sense_id,
                    explanation_id,
                    selected_at_ms
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT (normalized_form, sense_id) DO UPDATE SET
                    explanation_id = excluded.explanation_id,
                    selected_at_ms = excluded.selected_at_ms
                """,
                bindings: [
                    .text(normalizedForm),
                    .text(senseID),
                    .text(explanationID),
                    .integer(timestamp),
                ]
            )

            if makeDefaultForForm {
                try database.execute(
                    """
                    INSERT INTO overlay_form_default (normalized_form, sense_id)
                    VALUES (?, ?)
                    ON CONFLICT (normalized_form) DO UPDATE SET
                        sense_id = excluded.sense_id
                    """,
                    bindings: [.text(normalizedForm), .text(senseID)]
                )
            }
        }
    }

    func explanation(for form: String) throws -> OfflineVocabularyExplanation? {
        let normalizedForm = OfflineExplanationStore.normalizeForm(form)
        guard !normalizedForm.isEmpty else {
            return nil
        }
        return try explanation(normalizedForm: normalizedForm, senseID: nil)
    }

    func explanation(
        for form: String,
        senseID: String
    ) throws -> OfflineVocabularyExplanation? {
        let normalizedForm = OfflineExplanationStore.normalizeForm(form)
        guard !normalizedForm.isEmpty else {
            return nil
        }
        return try explanation(normalizedForm: normalizedForm, senseID: senseID)
    }

    /// Enqueues feedback exactly once. Repeating the same UUID and payload is a
    /// successful no-op; reusing the UUID for different feedback is rejected.
    @discardableResult
    func enqueueFeedback(_ event: ExplanationFeedbackEvent) throws -> Bool {
        try Self.validate(event)
        let normalizedForm = OfflineExplanationStore.normalizeForm(event.normalizedForm)
        let eventID = event.eventID.uuidString.lowercased()

        return try database.withTransaction {
            let inserted = try database.execute(
                """
                INSERT INTO feedback_outbox (
                    event_id,
                    explanation_id,
                    normalized_form,
                    sense_id,
                    rating,
                    component,
                    request_replacement,
                    created_at_ms,
                    attempt_count,
                    sent_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)
                ON CONFLICT (event_id) DO NOTHING
                """,
                bindings: [
                    .text(eventID),
                    .text(event.explanationID),
                    .text(normalizedForm),
                    .text(event.senseID),
                    .text(event.rating.rawValue),
                    .text(event.component.rawValue),
                    .integer(event.requestReplacement ? 1 : 0),
                    .integer(Self.milliseconds(since1970: event.createdAt)),
                ]
            ) > 0

            guard !inserted else {
                return true
            }
            guard try storedFeedbackMatches(event, normalizedForm: normalizedForm) else {
                throw ExplanationOverlayStoreError.feedbackIdempotencyConflict(event.eventID)
            }
            return false
        }
    }

    /// Returns pending events and records one delivery attempt atomically. An
    /// app termination after dequeue leaves `sent_at_ms` nil, so the same event
    /// is safely returned on the next launch.
    func dequeuePendingFeedback(limit: Int = 50) throws -> [ExplanationFeedbackEvent] {
        let boundedLimit = max(1, min(limit, 500))
        return try database.withTransaction {
            let events = try database.query(
                """
                SELECT event_id,
                       explanation_id,
                       normalized_form,
                       sense_id,
                       rating,
                       component,
                       request_replacement,
                       created_at_ms,
                       attempt_count
                  FROM feedback_outbox
                 WHERE sent_at_ms IS NULL
                 ORDER BY created_at_ms, event_id
                 LIMIT ?
                """,
                bindings: [.integer(Int64(boundedLimit))],
                transform: Self.decodeFeedback
            )

            for event in events {
                try database.execute(
                    """
                    UPDATE feedback_outbox
                       SET attempt_count = attempt_count + 1
                     WHERE event_id = ?
                       AND sent_at_ms IS NULL
                    """,
                    bindings: [.text(event.eventID.uuidString.lowercased())]
                )
            }

            return events.map { event in
                ExplanationFeedbackEvent(
                    eventID: event.eventID,
                    explanationID: event.explanationID,
                    normalizedForm: event.normalizedForm,
                    senseID: event.senseID,
                    rating: event.rating,
                    component: event.component,
                    requestReplacement: event.requestReplacement,
                    createdAt: event.createdAt,
                    attemptCount: event.attemptCount + 1
                )
            }
        }
    }

    /// Marks an event delivered. Repeating the acknowledgement is a no-op.
    @discardableResult
    func markFeedbackSent(
        eventID: UUID,
        sentAt: Date? = nil
    ) throws -> Bool {
        try database.execute(
            """
            UPDATE feedback_outbox
               SET sent_at_ms = ?
             WHERE event_id = ?
               AND sent_at_ms IS NULL
            """,
            bindings: [
                .integer(Self.milliseconds(since1970: sentAt ?? now())),
                .text(eventID.uuidString.lowercased()),
            ]
        ) > 0
    }

    private func explanation(
        normalizedForm: String,
        senseID: String?
    ) throws -> OfflineVocabularyExplanation? {
        let defaultJoin: String
        let senseFilter: String
        let bindings: [SQLiteWritableBinding]
        if let senseID {
            defaultJoin = ""
            senseFilter = "AND wf.sense_id = ?"
            bindings = [.text(normalizedForm), .text(senseID)]
        } else {
            defaultJoin = """
            JOIN overlay_form_default AS d
              ON d.normalized_form = wf.normalized_form
            """
            senseFilter = "AND wf.sense_id = d.sense_id"
            bindings = [.text(normalizedForm)]
        }

        return try database.queryOne(
            """
            SELECT wf.normalized_form,
                   wf.display_form,
                   wf.morphology_json,
                   wf.sense_id,
                   wf.lemma,
                   e.explanation_id,
                   e.content_hash,
                   e.schema_version,
                   e.part_of_speech,
                   e.meaning,
                   e.memory_technique,
                   e.memory_aid_json,
                   e.example,
                   e.synonyms_json
              FROM overlay_word_form AS wf
              \(defaultJoin)
              JOIN explanation_selection AS selected
                ON selected.normalized_form = wf.normalized_form
               AND selected.sense_id = wf.sense_id
              JOIN explanation_variant AS e
                ON e.explanation_id = selected.explanation_id
               AND e.sense_id = selected.sense_id
             WHERE wf.normalized_form = ?
               \(senseFilter)
             LIMIT 1
            """,
            bindings: bindings
        ) { row in
            let storedForm = try row.text(at: 0)
            let storedSenseID = try row.text(at: 3)
            let explanationID = try row.text(at: 5)
            let technique: VocabularyMemoryTechnique?
            if let value = try row.optionalText(at: 10) {
                guard let parsed = VocabularyMemoryTechnique(rawValue: value) else {
                    throw ExplanationOverlayStoreError.invalidStoredMemoryTechnique(
                        value,
                        explanationID: explanationID
                    )
                }
                technique = parsed
            } else {
                technique = nil
            }

            return OfflineVocabularyExplanation(
                normalizedForm: storedForm,
                displayForm: try row.text(at: 1),
                morphology: try Self.decodeMorphology(
                    try row.text(at: 2),
                    form: storedForm,
                    senseID: storedSenseID
                ),
                senseID: storedSenseID,
                lemma: try row.text(at: 4),
                explanationID: explanationID,
                contentHash: try row.text(at: 6),
                schemaVersion: Int(try row.integer(at: 7)),
                explanation: VocabularyExplanation(
                    partOfSpeech: try row.text(at: 8),
                    meaning: try row.text(at: 9),
                    memoryTechnique: technique,
                    memoryAid: try Self.decodeStringArray(
                        try row.text(at: 11),
                        field: "memory aid",
                        explanationID: explanationID
                    ),
                    example: try row.text(at: 12),
                    synonyms: try Self.decodeStringArray(
                        try row.text(at: 13),
                        field: "synonyms",
                        explanationID: explanationID
                    )
                )
            )
        }
    }

    private func migrateIfNeeded() throws {
        let applicationID = try database.queryOne("PRAGMA application_id") { row in
            try row.integer(at: 0)
        } ?? 0
        guard applicationID == 0 || applicationID == Self.applicationID else {
            throw ExplanationOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }

        let currentVersion = try database.queryOne("PRAGMA user_version") { row in
            try row.integer(at: 0)
        } ?? 0
        guard currentVersion <= Self.schemaVersion else {
            throw ExplanationOverlayStoreError.unsupportedSchemaVersion(
                maximum: Self.schemaVersion,
                actual: currentVersion
            )
        }
        if currentVersion > 0, applicationID != Self.applicationID {
            throw ExplanationOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }

        if currentVersion == 0 {
            try database.withTransaction {
                try database.executeScript(Self.schemaV1)
                try database.executeScript("PRAGMA application_id = \(Self.applicationID)")
                try database.executeScript("PRAGMA user_version = 1")
            }
        }
    }

    /// Checks identity through a read-only connection before the writable
    /// connection configures WAL. Passing the bundled content-pack URL by
    /// mistake is therefore rejected before SQLite can change even its journal
    /// mode.
    private static func preflightExistingDatabase(
        at databaseURL: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return
        }

        let inspector = try SQLiteReadOnlyDatabase(url: databaseURL)
        let applicationID = try inspector.queryOne("PRAGMA application_id") { row in
            try row.integer(at: 0)
        } ?? 0
        let currentVersion = try inspector.queryOne("PRAGMA user_version") { row in
            try row.integer(at: 0)
        } ?? 0

        guard applicationID == 0 || applicationID == Self.applicationID else {
            throw ExplanationOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }
        guard currentVersion <= Self.schemaVersion else {
            throw ExplanationOverlayStoreError.unsupportedSchemaVersion(
                maximum: Self.schemaVersion,
                actual: currentVersion
            )
        }
        if currentVersion > 0, applicationID != Self.applicationID {
            throw ExplanationOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }
        if applicationID == 0, currentVersion == 0 {
            let existingTables = try inspector.query(
                "SELECT name FROM sqlite_schema WHERE type = 'table' LIMIT 1"
            ) { row in
                try row.text(at: 0)
            }
            guard existingTables.isEmpty else {
                throw ExplanationOverlayStoreError.unsupportedApplicationID(
                    expected: Self.applicationID,
                    actual: applicationID
                )
            }
        }
    }

    private func storedVariantMatches(
        _ record: OfflineVocabularyExplanation,
        memoryAidJSON: String,
        synonymsJSON: String
    ) throws -> Bool {
        try database.queryOne(
            """
            SELECT sense_id,
                   content_hash,
                   schema_version,
                   part_of_speech,
                   meaning,
                   example,
                   memory_technique,
                   memory_aid_json,
                   synonyms_json
              FROM explanation_variant
             WHERE explanation_id = ?
            """,
            bindings: [.text(record.explanationID)]
        ) { row in
            try row.text(at: 0) == record.senseID
                && row.text(at: 1) == record.contentHash
                && row.integer(at: 2) == Int64(record.schemaVersion)
                && row.text(at: 3) == record.explanation.partOfSpeech
                && row.text(at: 4) == record.explanation.meaning
                && row.text(at: 5) == record.explanation.example
                && row.optionalText(at: 6) == record.explanation.memoryTechnique?.rawValue
                && row.text(at: 7) == memoryAidJSON
                && row.text(at: 8) == synonymsJSON
        } ?? false
    }

    private func storedFeedbackMatches(
        _ event: ExplanationFeedbackEvent,
        normalizedForm: String
    ) throws -> Bool {
        try database.queryOne(
            """
            SELECT explanation_id,
                   normalized_form,
                   sense_id,
                   rating,
                   component,
                   request_replacement
              FROM feedback_outbox
             WHERE event_id = ?
            """,
            bindings: [.text(event.eventID.uuidString.lowercased())]
        ) { row in
            try row.text(at: 0) == event.explanationID
                && row.text(at: 1) == normalizedForm
                && row.text(at: 2) == event.senseID
                && row.text(at: 3) == event.rating.rawValue
                && row.text(at: 4) == event.component.rawValue
                && row.integer(at: 5) == (event.requestReplacement ? 1 : 0)
        } ?? false
    }

    private static func decodeFeedback(
        _ row: SQLiteWritableRow
    ) throws -> ExplanationFeedbackEvent {
        let eventIDValue = try row.text(at: 0)
        guard let eventID = UUID(uuidString: eventIDValue) else {
            throw ExplanationOverlayStoreError.invalidStoredFeedbackID(eventIDValue)
        }
        guard let rating = ExplanationFeedbackRating(rawValue: try row.text(at: 4)) else {
            throw ExplanationOverlayStoreError.invalidFeedback("its stored rating is invalid")
        }
        guard let component = ExplanationFeedbackComponent(rawValue: try row.text(at: 5)) else {
            throw ExplanationOverlayStoreError.invalidFeedback("its stored component is invalid")
        }
        return ExplanationFeedbackEvent(
            eventID: eventID,
            explanationID: try row.text(at: 1),
            normalizedForm: try row.text(at: 2),
            senseID: try row.text(at: 3),
            rating: rating,
            component: component,
            requestReplacement: try row.integer(at: 6) != 0,
            createdAt: Self.date(millisecondsSince1970: try row.integer(at: 7)),
            attemptCount: Int(try row.integer(at: 8))
        )
    }

    private static func validate(_ record: OfflineVocabularyExplanation) throws {
        let normalizedForm = OfflineExplanationStore.normalizeForm(record.normalizedForm)
        guard !normalizedForm.isEmpty, normalizedForm == record.normalizedForm else {
            throw ExplanationOverlayStoreError.invalidExplanation("its normalized form is invalid")
        }
        guard OfflineExplanationStore.normalizeForm(record.displayForm) == normalizedForm else {
            throw ExplanationOverlayStoreError.invalidExplanation("its display form does not match")
        }
        guard !record.senseID.isEmpty,
              !record.lemma.isEmpty,
              !record.explanationID.isEmpty,
              !record.contentHash.isEmpty,
              record.schemaVersion > 0 else {
            throw ExplanationOverlayStoreError.invalidExplanation("its identity metadata is incomplete")
        }
        guard !record.explanation.partOfSpeech.isEmpty,
              !record.explanation.meaning.isEmpty,
              !record.explanation.example.isEmpty else {
            throw ExplanationOverlayStoreError.invalidExplanation("its learner-facing content is incomplete")
        }
        guard record.morphology.values.allSatisfy({ !$0.isEmpty }),
              !record.morphology.values.isEmpty else {
            throw ExplanationOverlayStoreError.invalidExplanation("its exact morphology is empty")
        }
        guard (record.explanation.memoryTechnique == nil) == record.explanation.memoryAid.isEmpty else {
            throw ExplanationOverlayStoreError.invalidExplanation("its memory technique and memory aid disagree")
        }
        guard record.explanation.memoryAid.allSatisfy({ !$0.isEmpty }),
              record.explanation.synonyms.allSatisfy({ !$0.isEmpty }) else {
            throw ExplanationOverlayStoreError.invalidExplanation("its list content contains an empty value")
        }
    }

    private static func validate(_ event: ExplanationFeedbackEvent) throws {
        guard !event.explanationID.isEmpty, !event.senseID.isEmpty else {
            throw ExplanationOverlayStoreError.invalidFeedback("its explanation identity is incomplete")
        }
        let normalizedForm = OfflineExplanationStore.normalizeForm(event.normalizedForm)
        guard !normalizedForm.isEmpty else {
            throw ExplanationOverlayStoreError.invalidFeedback("its form is empty")
        }
        guard !event.requestReplacement || event.rating == .dislike else {
            throw ExplanationOverlayStoreError.invalidFeedback("only disliked content can request a replacement")
        }
        guard event.attemptCount == 0 else {
            throw ExplanationOverlayStoreError.invalidFeedback("new events must start with zero attempts")
        }
    }

    private static func encodeStringArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ExplanationOverlayStoreError.invalidExplanation("its list data is not UTF-8")
        }
        return value
    }

    private static func decodeStringArray(
        _ value: String,
        field: String,
        explanationID: String
    ) throws -> [String] {
        do {
            return try JSONDecoder().decode([String].self, from: Data(value.utf8))
        } catch {
            throw ExplanationOverlayStoreError.invalidStoredJSON(
                field: field,
                explanationID: explanationID
            )
        }
    }

    private static func encodeMorphology(_ morphology: OfflineWordFormMorphology) throws -> String {
        let data: Data
        switch morphology {
        case .single(let value):
            data = try JSONEncoder().encode(value)
        case .combined(let values):
            data = try JSONEncoder().encode(values)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw ExplanationOverlayStoreError.invalidExplanation("its morphology is not UTF-8")
        }
        return value
    }

    private static func decodeMorphology(
        _ value: String,
        form: String,
        senseID: String
    ) throws -> OfflineWordFormMorphology {
        let data = Data(value.utf8)
        if let single = try? JSONDecoder().decode(String.self, from: data), !single.isEmpty {
            return .single(single)
        }
        if let combined = try? JSONDecoder().decode([String].self, from: data),
           !combined.isEmpty,
           combined.allSatisfy({ !$0.isEmpty }) {
            return .combined(combined)
        }
        throw ExplanationOverlayStoreError.invalidStoredMorphology(
            form: form,
            senseID: senseID
        )
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(millisecondsSince1970 value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
    }

    private static let schemaV1 = """
    CREATE TABLE explanation_variant (
        explanation_id TEXT PRIMARY KEY NOT NULL,
        sense_id TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        schema_version INTEGER NOT NULL CHECK (schema_version > 0),
        part_of_speech TEXT NOT NULL,
        meaning TEXT NOT NULL,
        example TEXT NOT NULL,
        memory_technique TEXT,
        memory_aid_json TEXT NOT NULL,
        synonyms_json TEXT NOT NULL,
        stored_at_ms INTEGER NOT NULL,
        UNIQUE (explanation_id, sense_id)
    ) WITHOUT ROWID;

    CREATE INDEX explanation_variant_sense_idx
        ON explanation_variant (sense_id, stored_at_ms, explanation_id);

    CREATE TABLE overlay_word_form (
        normalized_form TEXT NOT NULL,
        sense_id TEXT NOT NULL,
        display_form TEXT NOT NULL,
        lemma TEXT NOT NULL,
        part_of_speech TEXT NOT NULL,
        morphology_json TEXT NOT NULL,
        PRIMARY KEY (normalized_form, sense_id)
    ) WITHOUT ROWID;

    CREATE TABLE overlay_form_default (
        normalized_form TEXT PRIMARY KEY NOT NULL,
        sense_id TEXT NOT NULL,
        FOREIGN KEY (normalized_form, sense_id)
            REFERENCES overlay_word_form (normalized_form, sense_id)
    ) WITHOUT ROWID;

    CREATE TABLE explanation_selection (
        normalized_form TEXT NOT NULL,
        sense_id TEXT NOT NULL,
        explanation_id TEXT NOT NULL,
        selected_at_ms INTEGER NOT NULL,
        PRIMARY KEY (normalized_form, sense_id),
        FOREIGN KEY (normalized_form, sense_id)
            REFERENCES overlay_word_form (normalized_form, sense_id),
        FOREIGN KEY (explanation_id, sense_id)
            REFERENCES explanation_variant (explanation_id, sense_id)
    ) WITHOUT ROWID;

    CREATE TABLE feedback_outbox (
        event_id TEXT PRIMARY KEY NOT NULL,
        explanation_id TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        sense_id TEXT NOT NULL,
        rating TEXT NOT NULL CHECK (rating IN ('like', 'dislike')),
        component TEXT NOT NULL CHECK (component IN ('whole', 'meaning', 'memoryAid')),
        request_replacement INTEGER NOT NULL CHECK (request_replacement IN (0, 1)),
        created_at_ms INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
        sent_at_ms INTEGER
    ) WITHOUT ROWID;

    CREATE INDEX feedback_outbox_pending_idx
        ON feedback_outbox (sent_at_ms, created_at_ms, event_id);
    """
}

// MARK: - Entry-first overlay (schema 2 learner contract)

enum EntryFeedbackRating: String, Codable, Equatable, Sendable {
    case helpful
    case notHelpful
}

enum EntryFeedbackComponent: String, Codable, Equatable, Sendable {
    case explanation
    case example
    case memoryCue
    case wholeLesson
}

struct EntryFeedbackEvent: Codable, Equatable, Sendable {
    let eventID: UUID
    let entryID: String
    let entryUsageID: String
    let explanationID: String
    let normalizedForm: String
    let language: String
    let locale: String
    let rating: EntryFeedbackRating
    let component: EntryFeedbackComponent
    let requestReplacement: Bool
    let contentVersion: String
    /// Captured when the event is created so an outbox retry remains the same
    /// logical payload after the app itself has been updated.
    let appVersion: String?
    let baseContentVersion: String
    let baseEntryRevision: Int
    let schemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let reviewPolicyVersion: Int
    let excludedExplanationIDs: [String]
    let createdAt: Date
    let attemptCount: Int
    let feedbackDelivered: Bool
    let replacementCompleted: Bool

    init(
        eventID: UUID = UUID(),
        entryID: String,
        entryUsageID: String,
        explanationID: String,
        normalizedForm: String,
        language: String,
        locale: String,
        rating: EntryFeedbackRating,
        component: EntryFeedbackComponent = .wholeLesson,
        requestReplacement: Bool = false,
        contentVersion: String,
        appVersion: String? = nil,
        baseContentVersion: String,
        baseEntryRevision: Int,
        schemaVersion: Int,
        lessonContractVersion: Int,
        validatorVersion: Int,
        reviewPolicyVersion: Int,
        excludedExplanationIDs: [String] = [],
        createdAt: Date = Date(),
        attemptCount: Int = 0,
        feedbackDelivered: Bool = false,
        replacementCompleted: Bool = false
    ) {
        self.eventID = eventID
        self.entryID = entryID
        self.entryUsageID = entryUsageID
        self.explanationID = explanationID
        self.normalizedForm = normalizedForm
        self.language = language
        self.locale = locale
        self.rating = rating
        self.component = component
        self.requestReplacement = requestReplacement
        self.contentVersion = contentVersion
        self.appVersion = appVersion
        self.baseContentVersion = baseContentVersion
        self.baseEntryRevision = baseEntryRevision
        self.schemaVersion = schemaVersion
        self.lessonContractVersion = lessonContractVersion
        self.validatorVersion = validatorVersion
        self.reviewPolicyVersion = reviewPolicyVersion
        self.excludedExplanationIDs = excludedExplanationIDs
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.feedbackDelivered = feedbackDelivered
        self.replacementCompleted = replacementCompleted
    }
}

/// One durable feedback workflow. New rows retain the exact Entry snapshot the
/// learner saw so a later catalog update or replacement selection cannot change
/// the meaning of an idempotent retry. `baseEntry` is nil only for legacy rows
/// written before the versioned outbox envelope was introduced.
struct EntryFeedbackOutboxItem: Equatable, Sendable {
    let event: EntryFeedbackEvent
    let baseEntry: ResolvedWordEntry?
}

private struct EntryFeedbackOutboxEnvelope: Codable {
    static let currentVersion = 1

    let envelopeVersion: Int
    let event: EntryFeedbackEvent
    let baseEntry: ResolvedWordEntry
}

struct EntryLessonReplacement: Codable, Equatable, Sendable {
    let entryID: String
    let entryUsageID: String
    let locale: String
    let baseEntryRevision: Int
    let baseExplanationID: String
    let baseContentVersion: String
    let explanationID: String
    let contentHash: String
    let schemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let reviewPolicyVersion: Int
    let contentRevision: Int
    let trustState: LessonTrustState
    let content: TeacherLessonContent
}

struct EntryCorrectionResolution: Codable, Equatable, Sendable {
    let candidates: [String]
    let expiresAt: Date
}

struct EntryPendingResolution: Codable, Equatable, Sendable {
    let jobID: String
    let canonicalKeyHash: String
    let jobKind: String
    let nextCheckAt: Date
    let checkCount: Int
}

struct EntryNegativeResolution: Codable, Equatable, Sendable {
    let reason: String
    let expiresAt: Date
}

struct EntryUnavailableResolution: Codable, Equatable, Sendable {
    let reason: String
    let retryAfter: Date?
}

enum EntryCachedMiss: Equatable, Sendable {
    case correctionRequired(EntryCorrectionResolution)
    case negative(EntryNegativeResolution)
}

enum EntryOverlayStoreError: LocalizedError {
    case applicationSupportUnavailable
    case unsupportedApplicationID(expected: Int64, actual: Int64)
    case unsupportedSchemaVersion(expected: Int64, actual: Int64)
    case invalidEntry(String)
    case immutableEntryConflict(entryID: String, revision: Int)
    case immutableReplacementConflict(String)
    case pendingJobIdentityConflict(String)
    case invalidReplacement(String)
    case invalidFeedback(String)
    case feedbackIdempotencyConflict(UUID)
    case invalidStoredRecord(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support directory is unavailable."
        case .unsupportedApplicationID(let expected, let actual):
            return "This is not a Wordbook Entry overlay (expected application ID \(expected), found \(actual))."
        case .unsupportedSchemaVersion(let expected, let actual):
            return "The Wordbook Entry overlay uses schema \(actual); this app supports schema \(expected)."
        case .invalidEntry(let reason):
            return "The complete Entry was not stored because \(reason)."
        case .immutableEntryConflict(let entryID, let revision):
            return "Entry \(entryID) revision \(revision) was reused with different immutable content."
        case .immutableReplacementConflict(let explanationID):
            return "Replacement \(explanationID) was reused with different immutable content."
        case .pendingJobIdentityConflict(let jobID):
            return "Pending job \(jobID) was reused for a different lookup or operation."
        case .invalidReplacement(let reason):
            return "The replacement was not stored because \(reason)."
        case .invalidFeedback(let reason):
            return "The Entry feedback was not queued because \(reason)."
        case .feedbackIdempotencyConflict(let eventID):
            return "Entry feedback event \(eventID.uuidString) was reused with a different payload."
        case .invalidStoredRecord(let reason):
            return "The Entry overlay contains an invalid stored record: \(reason)."
        }
    }
}

/// A writable cache for complete server-reviewed Entry snapshots. It is kept
/// separate from the legacy sense overlay so schema-v1 installations and their
/// feedback outbox remain readable during the Entry-first cutover.
final class EntryOverlayStore: @unchecked Sendable {
    static let applicationID: Int64 = 1_463_963_479
    static let schemaVersion: Int64 = 1

    private let database: SQLiteWritableDatabase
    private let now: @Sendable () -> Date

    convenience init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw EntryOverlayStoreError.applicationSupportUnavailable
        }
        try self.init(
            databaseURL: root
                .appendingPathComponent("Wordbook", isDirectory: true)
                .appendingPathComponent("wordbook-entry-overlay.sqlite"),
            fileManager: fileManager,
            now: now
        )
    }

    init(
        databaseURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try Self.preflightExistingDatabase(at: databaseURL, fileManager: fileManager)
        database = try SQLiteWritableDatabase(url: databaseURL, fileManager: fileManager)
        self.now = now
        try migrateIfNeeded()
        // Schema-v1 test builds existed before job/event pairing was enforced.
        // Idempotent triggers bring those databases up to the same invariant as
        // freshly created databases without rewriting user cache rows.
        try database.executeScript(Self.schemaV1Guards)
        try validateDatabaseIntegrity()
    }

    /// Installs and optionally activates one complete snapshot in one SQL
    /// transaction. The active pointer is written only after the decoded Entry
    /// passes the shared count, ordering, trust and content-identity validator.
    @discardableResult
    func installCompleteEntry(
        _ entry: ResolvedWordEntry,
        activate: Bool = true
    ) throws -> Bool {
        try Self.validateServerEntry(entry)
        // The raw encountered spelling belongs to the request, not immutable
        // snapshot identity. Canonicalizing it prevents `Saw` and `saw` from
        // colliding when the same reviewed revision is received twice.
        let storedEntry = Self.copy(
            entry,
            encounteredSurfaceForm: entry.displayForm
        )
        let payload = try encode(storedEntry)
        let storedAt = Self.milliseconds(now())

        return try database.withTransaction {
            try database.execute(
                """
                INSERT INTO entry_identity (
                    entry_id, language_tag, normalized_form, normalization_version
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT (entry_id) DO NOTHING
                """,
                bindings: [
                    .text(entry.entryID), .text(entry.language),
                    .text(entry.normalizedForm), .integer(Int64(entry.normalizationVersion)),
                ]
            )
            guard try identityMatches(entry) else {
                throw EntryOverlayStoreError.invalidEntry("its opaque Entry identity was rebound")
            }

            for usage in entry.usages {
                try database.execute(
                    """
                    INSERT INTO usage_identity (entry_usage_id, entry_id)
                    VALUES (?, ?)
                    ON CONFLICT (entry_usage_id) DO NOTHING
                    """,
                    bindings: [.text(usage.entryUsageID), .text(entry.entryID)]
                )
                guard try usageIdentityMatches(
                    entryID: entry.entryID,
                    entryUsageID: usage.entryUsageID
                ) else {
                    throw EntryOverlayStoreError.invalidEntry(
                        "Usage \(usage.entryUsageID) was rebound to another Entry"
                    )
                }
            }

            try database.execute(
                """
                INSERT INTO entry_snapshot (
                    entry_id, entry_revision, locale, language_tag,
                    normalized_form, normalization_version,
                    coverage_revision, usage_selection_policy_version,
                    base_content_version, server_content_version,
                    install_state, entry_json, stored_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                ON CONFLICT (entry_id, entry_revision, locale) DO NOTHING
                """,
                bindings: [
                    .text(entry.entryID), .integer(Int64(entry.entryRevision)),
                    .text(entry.locale), .text(entry.language),
                    .text(entry.normalizedForm), .integer(Int64(entry.normalizationVersion)),
                    .integer(Int64(entry.coverageRevision)),
                    .integer(Int64(entry.usageSelectionPolicyVersion)),
                    .text(entry.baseContentVersion), .text(entry.contentVersion),
                    .text(payload), .integer(storedAt),
                ]
            )
            guard try snapshotMatches(storedEntry, payload: payload) else {
                throw EntryOverlayStoreError.immutableEntryConflict(
                    entryID: entry.entryID,
                    revision: entry.entryRevision
                )
            }
            try database.execute(
                """
                UPDATE entry_snapshot
                   SET install_state = 'validated'
                 WHERE entry_id = ? AND entry_revision = ? AND locale = ?
                """,
                bindings: [
                    .text(entry.entryID), .integer(Int64(entry.entryRevision)),
                    .text(entry.locale),
                ]
            )

            guard activate else { return false }
            if let current = try activeEntry(
                normalizedForm: entry.normalizedForm,
                language: entry.language,
                locale: entry.locale
            ) {
                if Self.hasCompatibleRevisionLineage(storedEntry, current),
                   storedEntry.entryRevision > current.entryRevision,
                   !EntryContractValidator.isValidCoverageAdvance(
                       storedEntry,
                       over: current
                   ) {
                    throw EntryOverlayStoreError.invalidEntry(
                        "its Entry and coverage revisions do not match the reviewed Usage selection"
                    )
                }
                guard Self.isNonRegressive(candidate: storedEntry, over: current) else {
                    return false
                }
            }
            try database.execute(
                """
                INSERT INTO active_entry (
                    language_tag, normalized_form, normalization_version,
                    locale, entry_id, entry_revision
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (
                    language_tag, normalized_form, normalization_version, locale
                ) DO UPDATE SET
                    entry_id = excluded.entry_id,
                    entry_revision = excluded.entry_revision
                """,
                bindings: [
                    .text(entry.language), .text(entry.normalizedForm),
                    .integer(Int64(entry.normalizationVersion)), .text(entry.locale),
                    .text(entry.entryID), .integer(Int64(entry.entryRevision)),
                ]
            )
            try clearMissState(
                normalizedForm: entry.normalizedForm,
                language: entry.language,
                locale: entry.locale
            )
            return true
        }
    }

    func entry(
        for surfaceForm: String,
        language: String = "en",
        locale: String = "en"
    ) throws -> ResolvedWordEntry? {
        let normalizedForm = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalizedForm.isEmpty,
              EntryContractValidator.hasValidLocaleSyntax(locale) else { return nil }
        guard let stored = try activeEntry(
            normalizedForm: normalizedForm,
            language: language.lowercased(),
            locale: Self.normalizedLocale(locale)
        ) else { return nil }
        return Self.copy(stored, encounteredSurfaceForm: surfaceForm)
    }

    /// Stores a full immutable lesson replacement. The caller must supply the
    /// exact Entry snapshot against which the server reviewed it; this is the
    /// cross-database sidecar check SQLite cannot express as a foreign key.
    func installReplacement(
        _ replacement: EntryLessonReplacement,
        against baseEntry: ResolvedWordEntry
    ) throws {
        let replacementUsage = try Self.validateReplacement(
            replacement,
            against: baseEntry
        )
        let payload = try encode(replacement)
        let selectedAt = Self.milliseconds(now())

        try database.withTransaction {
            try database.execute(
                """
                INSERT INTO lesson_replacement (
                    explanation_id, entry_id, entry_usage_id, locale,
                    base_entry_revision, base_explanation_id,
                    base_content_version, replacement_json, selected_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (explanation_id) DO NOTHING
                """,
                bindings: [
                    .text(replacement.explanationID), .text(replacement.entryID),
                    .text(replacement.entryUsageID), .text(replacement.locale),
                    .integer(Int64(replacement.baseEntryRevision)),
                    .text(replacement.baseExplanationID),
                    .text(replacement.baseContentVersion), .text(payload),
                    .integer(selectedAt),
                ]
            )
            guard try replacementMatches(replacement, payload: payload) else {
                throw EntryOverlayStoreError.immutableReplacementConflict(
                    replacement.explanationID
                )
            }
            _ = replacementUsage
            try database.execute(
                """
                INSERT INTO replacement_selection (
                    entry_id, entry_usage_id, locale, explanation_id
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT (entry_id, entry_usage_id, locale) DO UPDATE SET
                    explanation_id = excluded.explanation_id
                """,
                bindings: [
                    .text(replacement.entryID), .text(replacement.entryUsageID),
                    .text(replacement.locale), .text(replacement.explanationID),
                ]
            )
        }
    }

    /// Applies only sidecars whose base binding still matches the selected
    /// whole snapshot. Stale replacements remain stored but become ineligible.
    func applyingSelectedReplacements(
        to entry: ResolvedWordEntry
    ) throws -> ResolvedWordEntry {
		do {
			try EntryContractValidator.validate(
				entry,
				expectedSurfaceForm: entry.encounteredSurfaceForm
			)
		} catch {
			throw EntryOverlayStoreError.invalidEntry(error.localizedDescription)
		}
        var usages = entry.usages
        for index in usages.indices {
            let base = usages[index]
            guard let payload = try database.queryOne(
                """
                SELECT replacement.replacement_json
                  FROM replacement_selection AS selection
                  JOIN lesson_replacement AS replacement
                    ON replacement.explanation_id = selection.explanation_id
                 WHERE selection.entry_id = ?
                   AND selection.entry_usage_id = ?
                   AND selection.locale = ?
                 LIMIT 1
                """,
                bindings: [
                    .text(entry.entryID), .text(base.entryUsageID), .text(entry.locale),
                ],
                transform: { try $0.text(at: 0) }
            ) else { continue }
            let selected: EntryLessonReplacement = try decode(
                payload,
                description: "replacement for \(base.entryUsageID)"
            )

            // A sidecar selected for an older immutable Entry snapshot is
            // intentionally retained, but it is not eligible for this one.
            guard selected.baseEntryRevision == entry.entryRevision,
                  selected.baseContentVersion == entry.contentVersion else {
                continue
            }

            // Replacements can themselves receive feedback. The selected
            // sidecar therefore may be based on an earlier replacement rather
            // than directly on the bundled lesson. Rebuild that immutable
            // chain back to the snapshot lesson, then validate and apply it in
            // forward order. Looking only for `base.explanationID` here made a
            // second reviewed replacement install successfully but disappear
            // on the next lookup.
            var reverseChain = [selected]
            var seenExplanationIDs = Set([selected.explanationID])
            var predecessorID = selected.baseExplanationID
            while predecessorID != base.explanationID {
                guard reverseChain.count < 64,
                      seenExplanationIDs.insert(predecessorID).inserted,
                      let predecessorPayload = try database.queryOne(
                        """
                        SELECT replacement_json
                          FROM lesson_replacement
                         WHERE explanation_id = ?
                           AND entry_id = ?
                           AND entry_usage_id = ?
                           AND locale = ?
                           AND base_entry_revision = ?
                           AND base_content_version = ?
                         LIMIT 1
                        """,
                        bindings: [
                            .text(predecessorID), .text(entry.entryID),
                            .text(base.entryUsageID), .text(entry.locale),
                            .integer(Int64(entry.entryRevision)),
                            .text(entry.contentVersion),
                        ],
                        transform: { try $0.text(at: 0) }
                      ) else {
                    throw EntryOverlayStoreError.invalidStoredRecord(
                        "replacement chain for \(base.entryUsageID) is incomplete or cyclic"
                    )
                }
                let predecessor: EntryLessonReplacement = try decode(
                    predecessorPayload,
                    description: "replacement predecessor \(predecessorID)"
                )
                guard predecessor.explanationID == predecessorID else {
                    throw EntryOverlayStoreError.invalidStoredRecord(
                        "replacement chain for \(base.entryUsageID) changed identity"
                    )
                }
                reverseChain.append(predecessor)
                predecessorID = predecessor.baseExplanationID
            }

            for replacement in reverseChain.reversed() {
                let currentEntry = Self.copy(entry, usages: usages)
                usages[index] = try Self.validateReplacement(
                    replacement,
                    against: currentEntry
                )
            }
        }
        let resolved = Self.copy(entry, usages: usages)
		try EntryContractValidator.validateMaterializedView(
			resolved,
			expectedSurfaceForm: resolved.encounteredSurfaceForm
		)
        return resolved
    }

    /// Returns the complete immutable rejection lineage for the lesson the
    /// learner actually saw. Keeping this in the writable overlay makes a
    /// replacement-of-a-replacement retain every earlier rejected identity
    /// after relaunch, while the server independently verifies the same chain.
    func replacementExclusionHistory(
        entryID: String,
        entryUsageID: String,
        locale: String,
        baseEntryRevision: Int,
        baseContentVersion: String,
        currentExplanationID: String
    ) throws -> [String] {
        var excluded = Set([currentExplanationID])
        var cursor = currentExplanationID
        for _ in 0..<64 {
            guard let predecessor = try database.queryOne(
                """
                SELECT base_explanation_id
                  FROM lesson_replacement
                 WHERE explanation_id = ?
                   AND entry_id = ?
                   AND entry_usage_id = ?
                   AND locale = ?
                   AND base_entry_revision = ?
                   AND base_content_version = ?
                 LIMIT 1
                """,
                bindings: [
                    .text(cursor), .text(entryID), .text(entryUsageID),
                    .text(locale), .integer(Int64(baseEntryRevision)),
                    .text(baseContentVersion),
                ],
                transform: { try $0.text(at: 0) }
            ) else {
                return excluded.sorted()
            }
            guard excluded.insert(predecessor).inserted else {
                throw EntryOverlayStoreError.invalidStoredRecord(
                    "replacement exclusion lineage is cyclic"
                )
            }
            cursor = predecessor
        }
        throw EntryOverlayStoreError.invalidStoredRecord(
            "replacement exclusion lineage exceeds its bounded depth"
        )
    }

    func storePending(
        _ pending: EntryPendingResolution,
        normalizedForm: String,
        language: String,
        locale: String,
        eventID: UUID? = nil
    ) throws {
        let normalizedForm = OfflineExplanationStore.normalizeForm(normalizedForm)
        let language = language.lowercased()
        let hasValidLocale = EntryContractValidator.hasValidLocaleSyntax(locale)
        let locale = Self.normalizedLocale(locale)
        let storedEventID = eventID?.uuidString.lowercased()
        let kindMatchesEvent = (pending.jobKind == "resolveEntry" && storedEventID == nil)
            || (pending.jobKind == "replaceExplanation" && storedEventID != nil)
        guard Self.validStableID(pending.jobID),
              Self.validHash(pending.canonicalKeyHash),
              kindMatchesEvent,
              hasValidLocale,
              !normalizedForm.isEmpty, !language.isEmpty, !locale.isEmpty,
              pending.checkCount >= 0 else {
            throw EntryOverlayStoreError.invalidStoredRecord("pending job metadata is incomplete")
        }
        try database.withTransaction {
            try database.execute(
                """
                INSERT INTO server_job (
                    job_id, canonical_key_hash, job_kind, language_tag,
                    normalized_form, locale, next_check_at_ms, check_count,
                    event_id, state, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)
                ON CONFLICT (job_id) DO NOTHING
                """,
                bindings: [
                    .text(pending.jobID), .text(pending.canonicalKeyHash),
                    .text(pending.jobKind), .text(language),
                    .text(normalizedForm), .text(locale),
                    .integer(Self.milliseconds(pending.nextCheckAt)),
                    .integer(Int64(pending.checkCount)),
                    storedEventID.map { .text($0) } ?? .null,
                    .integer(Self.milliseconds(now())),
                ]
            )
            guard try pendingJobIdentityMatches(
                pending,
                normalizedForm: normalizedForm,
                language: language,
                locale: locale,
                eventID: storedEventID
            ) else {
                throw EntryOverlayStoreError.pendingJobIdentityConflict(pending.jobID)
            }
            // A completed job is terminal. A stale pending response may refresh
            // its schedule, but it must not resurrect completed work.
            try database.execute(
                """
                UPDATE server_job
                   SET next_check_at_ms = MAX(next_check_at_ms, ?),
                       check_count = MAX(check_count, ?),
                       updated_at_ms = ?
                 WHERE job_id = ? AND state = 'pending'
                """,
                bindings: [
                    .integer(Self.milliseconds(pending.nextCheckAt)),
                    .integer(Int64(pending.checkCount)),
                    .integer(Self.milliseconds(now())),
                    .text(pending.jobID),
                ]
            )
        }
    }

    func pending(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryPendingResolution? {
        let normalized = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalized.isEmpty,
              EntryContractValidator.hasValidLocaleSyntax(locale) else { return nil }
        return try database.queryOne(
            """
            SELECT job_id, canonical_key_hash, job_kind, next_check_at_ms, check_count
              FROM server_job
             WHERE language_tag = ? AND normalized_form = ? AND locale = ?
               AND state = 'pending'
               AND job_kind = 'resolveEntry'
             ORDER BY updated_at_ms DESC
             LIMIT 1
            """,
            bindings: [
                .text(language.lowercased()), .text(normalized),
                .text(Self.normalizedLocale(locale)),
            ]
        ) { row in
            EntryPendingResolution(
                jobID: try row.text(at: 0),
                canonicalKeyHash: try row.text(at: 1),
                jobKind: try row.text(at: 2),
                nextCheckAt: Self.date(try row.integer(at: 3)),
                checkCount: Int(try row.integer(at: 4))
            )
        }
    }

    func pending(eventID: UUID) throws -> EntryPendingResolution? {
        try database.queryOne(
            """
            SELECT job_id, canonical_key_hash, job_kind, next_check_at_ms, check_count
             FROM server_job
             WHERE event_id = ? AND state = 'pending'
               AND job_kind = 'replaceExplanation'
             ORDER BY updated_at_ms DESC
             LIMIT 1
            """,
            bindings: [.text(eventID.uuidString.lowercased())]
        ) { row in
            EntryPendingResolution(
                jobID: try row.text(at: 0),
                canonicalKeyHash: try row.text(at: 1),
                jobKind: try row.text(at: 2),
                nextCheckAt: Self.date(try row.integer(at: 3)),
                checkCount: Int(try row.integer(at: 4))
            )
        }
    }

    func markJobFinished(_ jobID: String) throws {
        try database.execute(
            "UPDATE server_job SET state = 'finished', updated_at_ms = ? WHERE job_id = ?",
            bindings: [.integer(Self.milliseconds(now())), .text(jobID)]
        )
    }

    func storeCorrection(
        _ correction: EntryCorrectionResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws {
        guard !correction.candidates.isEmpty,
              correction.candidates.allSatisfy({ !$0.isEmpty }),
              correction.expiresAt > now() else {
            throw EntryOverlayStoreError.invalidStoredRecord("correction is empty or expired")
        }
        try storeMiss(
            kind: "correction", payload: try encode(correction),
            expiry: correction.expiresAt, normalizedForm: normalizedForm,
            language: language, locale: locale
        )
    }

    func storeNegative(
        _ negative: EntryNegativeResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws {
        guard !negative.reason.isEmpty, negative.expiresAt > now() else {
            throw EntryOverlayStoreError.invalidStoredRecord("negative is empty or expired")
        }
        try storeMiss(
            kind: "negative", payload: try encode(negative),
            expiry: negative.expiresAt, normalizedForm: normalizedForm,
            language: language, locale: locale
        )
    }

    func cachedMiss(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryCachedMiss? {
        let normalized = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalized.isEmpty,
              EntryContractValidator.hasValidLocaleSyntax(locale) else { return nil }
        guard let row: (String, String) = try database.queryOne(
            """
            SELECT outcome_kind, payload_json
              FROM lookup_miss
             WHERE language_tag = ? AND normalized_form = ? AND locale = ?
               AND expires_at_ms > ?
             LIMIT 1
            """,
            bindings: [
                .text(language.lowercased()), .text(normalized),
                .text(Self.normalizedLocale(locale)), .integer(Self.milliseconds(now())),
            ],
            transform: { (try $0.text(at: 0), try $0.text(at: 1)) }
        ) else { return nil }
        switch row.0 {
        case "correction":
            return .correctionRequired(try decode(row.1, description: "correction"))
        case "negative":
            return .negative(try decode(row.1, description: "negative"))
        default:
            throw EntryOverlayStoreError.invalidStoredRecord("unknown miss outcome \(row.0)")
        }
    }

    @discardableResult
    func enqueueFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) throws -> Bool {
        let storedEvent = Self.payloadEvent(event)
        try Self.validate(storedEvent, baseEntry: baseEntry)
        let payload = try encode(EntryFeedbackOutboxEnvelope(
            envelopeVersion: EntryFeedbackOutboxEnvelope.currentVersion,
            event: storedEvent,
            baseEntry: baseEntry
        ))
        let eventID = event.eventID.uuidString.lowercased()
        return try database.withTransaction {
            let inserted = try database.execute(
                """
                INSERT INTO entry_feedback_outbox (
                    event_id, payload_json, created_at_ms, attempt_count,
                    feedback_sent_at_ms, replacement_completed_at_ms
                ) VALUES (?, ?, ?, 0, NULL, ?)
                ON CONFLICT (event_id) DO NOTHING
                """,
                bindings: [
                    .text(eventID), .text(payload),
                    .integer(Self.milliseconds(event.createdAt)),
                    event.requestReplacement ? .null : .integer(Self.milliseconds(event.createdAt)),
                ]
            ) > 0
            if inserted { return true }
            let stored = try database.queryOne(
                "SELECT payload_json FROM entry_feedback_outbox WHERE event_id = ?",
                bindings: [.text(eventID)]
            ) { try $0.text(at: 0) }
            guard stored == payload else {
                throw EntryOverlayStoreError.feedbackIdempotencyConflict(event.eventID)
            }
            return false
        }
    }

    func dequeuePendingFeedback(limit: Int = 25) throws -> [EntryFeedbackOutboxItem] {
        let bounded = max(1, min(limit, 250))
        return try database.withTransaction {
            let rows: [(String, String, Int, Bool, Bool)] = try database.query(
                """
                SELECT event_id, payload_json, attempt_count,
                       feedback_sent_at_ms IS NOT NULL,
                       replacement_completed_at_ms IS NOT NULL
                  FROM entry_feedback_outbox
                 WHERE feedback_sent_at_ms IS NULL
                    OR replacement_completed_at_ms IS NULL
                 ORDER BY created_at_ms, event_id
                 LIMIT ?
                """,
                bindings: [.integer(Int64(bounded))]
            ) { row in
                (
                    try row.text(at: 0), try row.text(at: 1),
                    Int(try row.integer(at: 2)), try row.integer(at: 3) != 0,
                    try row.integer(at: 4) != 0
                )
            }
            var items = [EntryFeedbackOutboxItem]()
            items.reserveCapacity(rows.count)
            for row in rows {
                let stored: EntryFeedbackOutboxItem
                do {
                    stored = try decodeFeedbackOutboxPayload(
                        row.1,
                        description: "feedback \(row.0)"
                    )
                } catch {
                    try database.execute(
                        """
                        INSERT INTO feedback_outbox_quarantine (
                            event_id, payload_json, failure_reason, quarantined_at_ms
                        ) VALUES (?, ?, ?, ?)
                        ON CONFLICT (event_id) DO NOTHING
                        """,
                        bindings: [
                            .text(row.0), .text(row.1),
                            .text(String(error.localizedDescription.prefix(1_024))),
                            .integer(Self.milliseconds(now())),
                        ]
                    )
                    try database.execute(
                        "DELETE FROM entry_feedback_outbox WHERE event_id = ?",
                        bindings: [.text(row.0)]
                    )
                    continue
                }
                try database.execute(
                    "UPDATE entry_feedback_outbox SET attempt_count = attempt_count + 1 WHERE event_id = ?",
                    bindings: [.text(row.0)]
                )
                items.append(EntryFeedbackOutboxItem(
                    event: Self.copy(
                        stored.event,
                        attemptCount: row.2 + 1,
                        feedbackDelivered: row.3,
                        replacementCompleted: row.4
                    ),
                    baseEntry: stored.baseEntry
                ))
            }
            return items
        }
    }

    /// Claims one specific durable event for an in-place UI retry while
    /// preserving the event UUID and the delivery/replacement checkpoints.
    func pendingFeedback(eventID: UUID) throws -> EntryFeedbackOutboxItem? {
        let eventID = eventID.uuidString.lowercased()
        return try database.withTransaction {
            guard let row: (String, Int, Bool, Bool) = try database.queryOne(
                """
                SELECT payload_json, attempt_count,
                       feedback_sent_at_ms IS NOT NULL,
                       replacement_completed_at_ms IS NOT NULL
                  FROM entry_feedback_outbox
                 WHERE event_id = ?
                   AND (feedback_sent_at_ms IS NULL
                        OR replacement_completed_at_ms IS NULL)
                 LIMIT 1
                """,
                bindings: [.text(eventID)],
                transform: { row in
                    (
                        try row.text(at: 0), Int(try row.integer(at: 1)),
                        try row.integer(at: 2) != 0,
                        try row.integer(at: 3) != 0
                    )
                }
            ) else { return nil }
            try database.execute(
                "UPDATE entry_feedback_outbox SET attempt_count = attempt_count + 1 WHERE event_id = ?",
                bindings: [.text(eventID)]
            )
            let stored = try decodeFeedbackOutboxPayload(
                row.0,
                description: "feedback \(eventID)"
            )
            return EntryFeedbackOutboxItem(
                event: Self.copy(
                    stored.event,
                    attemptCount: row.1 + 1,
                    feedbackDelivered: row.2,
                    replacementCompleted: row.3
                ),
                baseEntry: stored.baseEntry
            )
        }
    }

    /// Removes a deterministically undeliverable event from the active queue
    /// while retaining its exact envelope and bounded diagnostic. This keeps a
    /// bad server-contract response or stale legacy context from blocking every
    /// later event on each one-shot background drain.
    func quarantineFeedback(eventID: UUID, failureReason: String) throws {
        let eventID = eventID.uuidString.lowercased()
        let reason = String(failureReason.prefix(1_024))
        try database.withTransaction {
            guard let payload = try database.queryOne(
                "SELECT payload_json FROM entry_feedback_outbox WHERE event_id = ?",
                bindings: [.text(eventID)],
                transform: { try $0.text(at: 0) }
            ) else { return }
            try database.execute(
                """
                INSERT INTO feedback_outbox_quarantine (
                    event_id, payload_json, failure_reason, quarantined_at_ms
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT (event_id) DO NOTHING
                """,
                bindings: [
                    .text(eventID), .text(payload), .text(reason),
                    .integer(Self.milliseconds(now())),
                ]
            )
            try database.execute(
                "DELETE FROM entry_feedback_outbox WHERE event_id = ?",
                bindings: [.text(eventID)]
            )
        }
    }

    func markFeedbackSent(eventID: UUID) throws {
        try database.execute(
            """
            UPDATE entry_feedback_outbox
               SET feedback_sent_at_ms = COALESCE(feedback_sent_at_ms, ?)
             WHERE event_id = ?
            """,
            bindings: [
                .integer(Self.milliseconds(now())),
                .text(eventID.uuidString.lowercased()),
            ]
        )
    }

    func markReplacementComplete(eventID: UUID) throws {
        try database.execute(
            """
            UPDATE entry_feedback_outbox
               SET replacement_completed_at_ms = COALESCE(replacement_completed_at_ms, ?)
             WHERE event_id = ?
            """,
            bindings: [
                .integer(Self.milliseconds(now())),
                .text(eventID.uuidString.lowercased()),
            ]
        )
    }

    private func activeEntry(
        normalizedForm: String,
        language: String,
        locale: String
    ) throws -> ResolvedWordEntry? {
        let locale = Self.normalizedLocale(locale)
        let languageLocale = locale.split(separator: "-").first.map(String.init) ?? language
        guard let payload = try database.queryOne(
            """
            SELECT snapshot.entry_json
              FROM active_entry AS active
              JOIN entry_snapshot AS snapshot
                ON snapshot.entry_id = active.entry_id
               AND snapshot.entry_revision = active.entry_revision
               AND snapshot.locale = active.locale
             WHERE active.language_tag = ?
               AND active.normalized_form = ?
               AND active.normalization_version = ?
               AND active.locale IN (?, ?, 'en')
               AND snapshot.install_state = 'validated'
             ORDER BY CASE active.locale
                        WHEN ? THEN 0 WHEN ? THEN 1 WHEN 'en' THEN 2 ELSE 3
                      END
             LIMIT 1
            """,
            bindings: [
                .text(language.lowercased()), .text(normalizedForm),
                .integer(Int64(EntryContractValidator.normalizationVersion)),
                .text(locale), .text(languageLocale),
                .text(locale), .text(languageLocale),
            ],
            transform: { try $0.text(at: 0) }
        ) else { return nil }
        let entry: ResolvedWordEntry = try decode(payload, description: "active Entry")
        try EntryContractValidator.validate(
            entry,
            expectedSurfaceForm: entry.encounteredSurfaceForm
        )
        return entry
    }

    private static func validateServerEntry(_ entry: ResolvedWordEntry) throws {
        do {
            try EntryContractValidator.validate(
                entry,
                expectedSurfaceForm: entry.encounteredSurfaceForm
            )
        } catch {
            throw EntryOverlayStoreError.invalidEntry(error.localizedDescription)
        }
        let trustMatchesCoverage = switch entry.coverageState {
        case .releaseReviewedComplete:
            entry.usages.allSatisfy({ $0.trustState == .releaseReviewed })
        case .serverReviewedComplete:
            entry.usages.allSatisfy({ $0.trustState == .serverReviewed })
        }
        guard trustMatchesCoverage, !entry.contentVersion.isEmpty,
              !entry.baseContentVersion.isEmpty else {
            throw EntryOverlayStoreError.invalidEntry(
                "its coverage and reviewed lesson trust do not match"
            )
        }
    }

    private static func validateReplacement(
        _ replacement: EntryLessonReplacement,
        against entry: ResolvedWordEntry
    ) throws -> UsageLesson {
        guard replacement.entryID == entry.entryID,
              replacement.locale == entry.locale,
              replacement.baseEntryRevision == entry.entryRevision,
              replacement.baseContentVersion == entry.contentVersion,
              replacement.trustState == .serverReviewed,
              let base = entry.usages.first(where: {
                  $0.entryUsageID == replacement.entryUsageID
              }),
              base.explanationID == replacement.baseExplanationID,
              replacement.explanationID != base.explanationID,
              replacement.schemaVersion == base.schemaVersion,
              replacement.lessonContractVersion == base.lessonContractVersion,
              replacement.validatorVersion == base.validatorVersion,
              replacement.reviewPolicyVersion >= base.reviewPolicyVersion,
              replacement.contentRevision == base.contentRevision + 1 else {
            throw EntryOverlayStoreError.invalidReplacement(
                "its Entry, Usage, or base-version binding does not match"
            )
        }
        let usage = UsageLesson(
            entryUsageID: base.entryUsageID,
            learnerLabel: base.learnerLabel,
            partOfSpeechLabel: base.partOfSpeechLabel,
            pronunciations: base.pronunciations,
            formRelationLabel: base.formRelationLabel,
            contextVector: base.contextVector,
            displayOrder: base.displayOrder,
            commonnessRank: base.commonnessRank,
            isCore: base.isCore,
            explanationID: replacement.explanationID,
            contentHash: replacement.contentHash,
            schemaVersion: replacement.schemaVersion,
            lessonContractVersion: replacement.lessonContractVersion,
            validatorVersion: replacement.validatorVersion,
            reviewPolicyVersion: replacement.reviewPolicyVersion,
            contentRevision: replacement.contentRevision,
            trustState: replacement.trustState,
            content: replacement.content
        )
        do {
            try EntryContractValidator.validateContentIdentity(
                usage,
                entryID: entry.entryID,
                normalizedForm: entry.normalizedForm,
                language: entry.language,
                locale: entry.locale
            )
        } catch {
            throw EntryOverlayStoreError.invalidReplacement(error.localizedDescription)
        }
        return usage
    }

    private static func validate(_ event: EntryFeedbackEvent) throws {
        let normalized = OfflineExplanationStore.normalizeForm(event.normalizedForm)
        guard !event.entryID.isEmpty, !event.entryUsageID.isEmpty,
              !event.explanationID.isEmpty, normalized == event.normalizedForm,
              !event.language.isEmpty, !event.locale.isEmpty,
              event.baseEntryRevision > 0, event.schemaVersion > 0,
              event.lessonContractVersion > 0, event.validatorVersion > 0,
              event.reviewPolicyVersion > 0, event.attemptCount == 0,
              !event.feedbackDelivered, !event.replacementCompleted else {
            throw EntryOverlayStoreError.invalidFeedback("its identity or versions are incomplete")
        }
        guard !event.requestReplacement || event.rating == .notHelpful else {
            throw EntryOverlayStoreError.invalidFeedback(
                "only not-helpful feedback may request a replacement"
            )
        }
    }

    private static func validate(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) throws {
        try validate(event)
		do {
			try EntryContractValidator.validateMaterializedView(
				baseEntry,
                expectedSurfaceForm: baseEntry.encounteredSurfaceForm
            )
        } catch {
            throw EntryOverlayStoreError.invalidFeedback(
                "its displayed Entry is invalid: \(error.localizedDescription)"
            )
        }
        guard event.entryID == baseEntry.entryID,
              event.normalizedForm == baseEntry.normalizedForm,
              event.language == baseEntry.language,
              event.locale == baseEntry.locale,
              event.contentVersion == baseEntry.contentVersion,
              event.baseContentVersion == baseEntry.contentVersion,
              event.baseEntryRevision == baseEntry.entryRevision,
              let usage = baseEntry.usages.first(where: {
                  $0.entryUsageID == event.entryUsageID
                    && $0.explanationID == event.explanationID
              }),
              usage.schemaVersion == event.schemaVersion,
              usage.lessonContractVersion == event.lessonContractVersion,
              usage.validatorVersion == event.validatorVersion,
              usage.reviewPolicyVersion == event.reviewPolicyVersion else {
            throw EntryOverlayStoreError.invalidFeedback(
                "its exact displayed Entry or lesson binding does not match"
            )
        }
    }

    private func identityMatches(_ entry: ResolvedWordEntry) throws -> Bool {
        try database.queryOne(
            """
            SELECT language_tag, normalized_form, normalization_version
              FROM entry_identity WHERE entry_id = ?
            """,
            bindings: [.text(entry.entryID)]
        ) { row in
            try row.text(at: 0) == entry.language
                && row.text(at: 1) == entry.normalizedForm
                && row.integer(at: 2) == Int64(entry.normalizationVersion)
        } ?? false
    }

    private func usageIdentityMatches(entryID: String, entryUsageID: String) throws -> Bool {
        try database.queryOne(
            "SELECT entry_id FROM usage_identity WHERE entry_usage_id = ?",
            bindings: [.text(entryUsageID)]
        ) { try $0.text(at: 0) == entryID } ?? false
    }

    private func snapshotMatches(_ entry: ResolvedWordEntry, payload: String) throws -> Bool {
        try database.queryOne(
            """
            SELECT language_tag, normalized_form, normalization_version,
                   coverage_revision, usage_selection_policy_version,
                   base_content_version, server_content_version, entry_json
              FROM entry_snapshot
             WHERE entry_id = ? AND entry_revision = ? AND locale = ?
            """,
            bindings: [
                .text(entry.entryID), .integer(Int64(entry.entryRevision)),
                .text(entry.locale),
            ]
        ) { row in
            try row.text(at: 0) == entry.language
                && row.text(at: 1) == entry.normalizedForm
                && row.integer(at: 2) == Int64(entry.normalizationVersion)
                && row.integer(at: 3) == Int64(entry.coverageRevision)
                && row.integer(at: 4) == Int64(entry.usageSelectionPolicyVersion)
                && row.text(at: 5) == entry.baseContentVersion
                && row.text(at: 6) == entry.contentVersion
                && row.text(at: 7) == payload
        } ?? false
    }

    private func pendingJobIdentityMatches(
        _ pending: EntryPendingResolution,
        normalizedForm: String,
        language: String,
        locale: String,
        eventID: String?
    ) throws -> Bool {
        try database.queryOne(
            """
            SELECT canonical_key_hash, job_kind, language_tag,
                   normalized_form, locale, event_id
              FROM server_job
             WHERE job_id = ?
            """,
            bindings: [.text(pending.jobID)]
        ) { row in
            try row.text(at: 0) == pending.canonicalKeyHash
                && row.text(at: 1) == pending.jobKind
                && row.text(at: 2) == language
                && row.text(at: 3) == normalizedForm
                && row.text(at: 4) == locale
                && row.optionalText(at: 5) == eventID
        } ?? false
    }

    private func replacementMatches(
        _ replacement: EntryLessonReplacement,
        payload: String
    ) throws -> Bool {
        try database.queryOne(
            """
            SELECT entry_id, entry_usage_id, locale, base_entry_revision,
                   base_explanation_id, base_content_version, replacement_json
              FROM lesson_replacement WHERE explanation_id = ?
            """,
            bindings: [.text(replacement.explanationID)]
        ) { row in
            try row.text(at: 0) == replacement.entryID
                && row.text(at: 1) == replacement.entryUsageID
                && row.text(at: 2) == replacement.locale
                && row.integer(at: 3) == Int64(replacement.baseEntryRevision)
                && row.text(at: 4) == replacement.baseExplanationID
                && row.text(at: 5) == replacement.baseContentVersion
                && row.text(at: 6) == payload
        } ?? false
    }

    private func storeMiss(
        kind: String,
        payload: String,
        expiry: Date,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws {
        guard EntryContractValidator.hasValidLocaleSyntax(locale) else {
            throw EntryOverlayStoreError.invalidStoredRecord(
                "lookup miss locale is invalid"
            )
        }
        try database.execute(
            """
            INSERT INTO lookup_miss (
                language_tag, normalized_form, normalization_version,
                locale, outcome_kind, payload_json, expires_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (
                language_tag, normalized_form, normalization_version, locale
            ) DO UPDATE SET
                outcome_kind = excluded.outcome_kind,
                payload_json = excluded.payload_json,
                expires_at_ms = excluded.expires_at_ms
            """,
            bindings: [
                .text(language.lowercased()), .text(normalizedForm),
                .integer(Int64(EntryContractValidator.normalizationVersion)),
                .text(Self.normalizedLocale(locale)), .text(kind), .text(payload),
                .integer(Self.milliseconds(expiry)),
            ]
        )
    }

    private func clearMissState(
        normalizedForm: String,
        language: String,
        locale: String
    ) throws {
        let bindings: [SQLiteWritableBinding] = [
            .text(language.lowercased()), .text(normalizedForm),
            .text(Self.normalizedLocale(locale)),
        ]
        try database.execute(
            "DELETE FROM lookup_miss WHERE language_tag = ? AND normalized_form = ? AND locale = ?",
            bindings: bindings
        )
        try database.execute(
            "UPDATE server_job SET state = 'finished' WHERE language_tag = ? AND normalized_form = ? AND locale = ? AND job_kind = 'resolveEntry'",
            bindings: bindings
        )
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> String {
        let data = try Self.makeEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EntryOverlayStoreError.invalidStoredRecord("encoded JSON is not UTF-8")
        }
        return string
    }

    private func decodeFeedbackOutboxPayload(
        _ value: String,
        description: String
    ) throws -> EntryFeedbackOutboxItem {
        let data = Data(value.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if object?["envelopeVersion"] != nil {
            let envelope: EntryFeedbackOutboxEnvelope
            do {
                envelope = try Self.makeDecoder().decode(
                    EntryFeedbackOutboxEnvelope.self,
                    from: data
                )
            } catch {
                throw EntryOverlayStoreError.invalidStoredRecord(
                    "\(description) envelope cannot be decoded: \(error.localizedDescription)"
                )
            }
            guard envelope.envelopeVersion == EntryFeedbackOutboxEnvelope.currentVersion else {
                throw EntryOverlayStoreError.invalidStoredRecord(
                    "\(description) uses unsupported outbox envelope \(envelope.envelopeVersion)"
                )
            }
            do {
                try Self.validate(envelope.event, baseEntry: envelope.baseEntry)
            } catch {
                throw EntryOverlayStoreError.invalidStoredRecord(
                    "\(description) has an invalid event/base binding: \(error.localizedDescription)"
                )
            }
            return EntryFeedbackOutboxItem(
                event: envelope.event,
                baseEntry: envelope.baseEntry
            )
        }

        // Compatibility with rows written before envelope version 1. The
        // repository reconstructs their base from the still-available catalog
        // or overlay snapshot; all newly queued rows use the durable envelope.
        let event: EntryFeedbackEvent = try decode(value, description: description)
        do {
            try Self.validate(event)
        } catch {
            throw EntryOverlayStoreError.invalidStoredRecord(
                "\(description) has an invalid legacy event: \(error.localizedDescription)"
            )
        }
        return EntryFeedbackOutboxItem(event: event, baseEntry: nil)
    }

    private func decode<Value: Decodable>(
        _ value: String,
        description: String
    ) throws -> Value {
        do {
            return try Self.makeDecoder().decode(Value.self, from: Data(value.utf8))
        } catch {
            throw EntryOverlayStoreError.invalidStoredRecord(
                "\(description) cannot be decoded: \(error.localizedDescription)"
            )
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func migrateIfNeeded() throws {
        let applicationID = try database.queryOne("PRAGMA application_id") {
            try $0.integer(at: 0)
        } ?? 0
        let version = try database.queryOne("PRAGMA user_version") {
            try $0.integer(at: 0)
        } ?? 0
        if applicationID == 0 && version == 0 {
            try database.withTransaction {
                try database.execute("PRAGMA application_id = \(Self.applicationID)")
                try database.executeScript(Self.schemaV1)
                try database.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
            return
        }
        guard applicationID == Self.applicationID else {
            throw EntryOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }
        guard version == Self.schemaVersion else {
            throw EntryOverlayStoreError.unsupportedSchemaVersion(
                expected: Self.schemaVersion,
                actual: version
            )
        }
    }

    private func validateDatabaseIntegrity() throws {
        let integrityRows = try database.query("PRAGMA quick_check") {
            try $0.text(at: 0)
        }
        guard integrityRows == ["ok"] else {
            throw EntryOverlayStoreError.invalidStoredRecord(
                "SQLite quick_check failed: \(integrityRows.joined(separator: ", "))"
            )
        }
        let foreignKeyFailures = try database.query("PRAGMA foreign_key_check") { _ in true }
        guard foreignKeyFailures.isEmpty else {
            throw EntryOverlayStoreError.invalidStoredRecord(
                "SQLite foreign_key_check failed"
            )
        }
    }

    private static func preflightExistingDatabase(
        at url: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let reader = try SQLiteReadOnlyDatabase(url: url)
        let applicationID = try reader.queryOne("PRAGMA application_id") {
            try $0.integer(at: 0)
        } ?? 0
        guard applicationID == Self.applicationID else {
            throw EntryOverlayStoreError.unsupportedApplicationID(
                expected: Self.applicationID,
                actual: applicationID
            )
        }
    }

    private static func isNonRegressive(
        candidate: ResolvedWordEntry,
        over current: ResolvedWordEntry
    ) -> Bool {
        guard hasCompatibleRevisionLineage(candidate, current) else { return false }
        if candidate.entryRevision == current.entryRevision,
           candidate.coverageRevision == current.coverageRevision {
            return candidate == current
        }
        return EntryContractValidator.isValidCoverageAdvance(candidate, over: current)
    }

    private static func hasCompatibleRevisionLineage(
        _ candidate: ResolvedWordEntry,
        _ current: ResolvedWordEntry
    ) -> Bool {
        candidate.entryID == current.entryID
            && candidate.language == current.language
            && candidate.normalizedForm == current.normalizedForm
            && candidate.locale == current.locale
            && candidate.normalizationVersion == current.normalizationVersion
            && candidate.resolverContractVersion == current.resolverContractVersion
            && candidate.usageSelectionPolicyVersion
                == current.usageSelectionPolicyVersion
    }

    private static func copy(
        _ entry: ResolvedWordEntry,
        encounteredSurfaceForm: String? = nil,
        usages: [UsageLesson]? = nil
    ) -> ResolvedWordEntry {
        ResolvedWordEntry(
            entryID: entry.entryID,
            encounteredSurfaceForm: encounteredSurfaceForm ?? entry.encounteredSurfaceForm,
            displayForm: entry.displayForm,
            normalizedForm: entry.normalizedForm,
            language: entry.language,
            locale: entry.locale,
            usages: usages ?? entry.usages,
            preferredEntryUsageID: entry.preferredEntryUsageID,
            orderingSource: entry.orderingSource,
            expectedUsageCount: entry.expectedUsageCount,
            expectedCoreCount: entry.expectedCoreCount,
            hasMoreUsages: entry.hasMoreUsages,
            coverageState: entry.coverageState,
            contentVersion: entry.contentVersion,
            baseContentVersion: entry.baseContentVersion,
            entryRevision: entry.entryRevision,
            coverageRevision: entry.coverageRevision,
            usageSelectionPolicyVersion: entry.usageSelectionPolicyVersion,
            normalizationVersion: entry.normalizationVersion,
            resolverContractVersion: entry.resolverContractVersion
        )
    }

    private static func payloadEvent(_ event: EntryFeedbackEvent) -> EntryFeedbackEvent {
        copy(
            event,
            attemptCount: 0,
            feedbackDelivered: false,
            replacementCompleted: false
        )
    }

    private static func copy(
        _ event: EntryFeedbackEvent,
        attemptCount: Int,
        feedbackDelivered: Bool,
        replacementCompleted: Bool
    ) -> EntryFeedbackEvent {
        EntryFeedbackEvent(
            eventID: event.eventID,
            entryID: event.entryID,
            entryUsageID: event.entryUsageID,
            explanationID: event.explanationID,
            normalizedForm: event.normalizedForm,
            language: event.language,
            locale: event.locale,
            rating: event.rating,
            component: event.component,
            requestReplacement: event.requestReplacement,
            contentVersion: event.contentVersion,
            appVersion: event.appVersion,
            baseContentVersion: event.baseContentVersion,
            baseEntryRevision: event.baseEntryRevision,
            schemaVersion: event.schemaVersion,
            lessonContractVersion: event.lessonContractVersion,
            validatorVersion: event.validatorVersion,
            reviewPolicyVersion: event.reviewPolicyVersion,
            excludedExplanationIDs: event.excludedExplanationIDs,
            createdAt: event.createdAt,
            attemptCount: attemptCount,
            feedbackDelivered: feedbackDelivered,
            replacementCompleted: replacementCompleted
        )
    }

    private static func normalizedLocale(_ value: String) -> String {
        EntryContractValidator.canonicalLocale(value)
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private static func validStableID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...192).contains(scalars.count),
              scalars.first.map(isASCIILetterOrDigit) == true else { return false }
        return scalars.allSatisfy { scalar in
            isASCIILetterOrDigit(scalar)
                || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static let schemaV1 = """
    CREATE TABLE entry_identity (
        entry_id TEXT PRIMARY KEY NOT NULL,
        language_tag TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        normalization_version INTEGER NOT NULL,
        UNIQUE (language_tag, normalized_form, normalization_version)
    ) WITHOUT ROWID;

    CREATE TABLE usage_identity (
        entry_usage_id TEXT PRIMARY KEY NOT NULL,
        entry_id TEXT NOT NULL REFERENCES entry_identity(entry_id)
    ) WITHOUT ROWID;

    CREATE TABLE entry_snapshot (
        entry_id TEXT NOT NULL REFERENCES entry_identity(entry_id),
        entry_revision INTEGER NOT NULL CHECK (entry_revision > 0),
        locale TEXT NOT NULL,
        language_tag TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        normalization_version INTEGER NOT NULL,
        coverage_revision INTEGER NOT NULL CHECK (coverage_revision > 0),
        usage_selection_policy_version INTEGER NOT NULL,
        base_content_version TEXT NOT NULL,
        server_content_version TEXT NOT NULL,
        install_state TEXT NOT NULL CHECK (install_state IN ('pending', 'validated')),
        entry_json TEXT NOT NULL,
        stored_at_ms INTEGER NOT NULL,
        PRIMARY KEY (entry_id, entry_revision, locale)
    ) WITHOUT ROWID;

    CREATE TABLE active_entry (
        language_tag TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        normalization_version INTEGER NOT NULL,
        locale TEXT NOT NULL,
        entry_id TEXT NOT NULL,
        entry_revision INTEGER NOT NULL,
        FOREIGN KEY (entry_id, entry_revision, locale)
            REFERENCES entry_snapshot(entry_id, entry_revision, locale),
        PRIMARY KEY (language_tag, normalized_form, normalization_version, locale)
    ) WITHOUT ROWID;

    CREATE TRIGGER active_entry_requires_validated_insert
    BEFORE INSERT ON active_entry BEGIN
        SELECT CASE WHEN NOT EXISTS (
            SELECT 1 FROM entry_snapshot AS candidate
             WHERE candidate.entry_id = NEW.entry_id
               AND candidate.entry_revision = NEW.entry_revision
               AND candidate.locale = NEW.locale
               AND candidate.install_state = 'validated'
        ) THEN RAISE(ABORT, 'Entry snapshot is not validated') END;
    END;

    CREATE TRIGGER active_entry_requires_validated_update
    BEFORE UPDATE ON active_entry BEGIN
        SELECT CASE WHEN NOT EXISTS (
            SELECT 1 FROM entry_snapshot AS candidate
             WHERE candidate.entry_id = NEW.entry_id
               AND candidate.entry_revision = NEW.entry_revision
               AND candidate.locale = NEW.locale
               AND candidate.install_state = 'validated'
        ) THEN RAISE(ABORT, 'Entry snapshot is not validated') END;
    END;

    CREATE TABLE lesson_replacement (
        explanation_id TEXT PRIMARY KEY NOT NULL,
        entry_id TEXT NOT NULL,
        entry_usage_id TEXT NOT NULL,
        locale TEXT NOT NULL,
        base_entry_revision INTEGER NOT NULL,
        base_explanation_id TEXT NOT NULL,
        base_content_version TEXT NOT NULL,
        replacement_json TEXT NOT NULL,
        selected_at_ms INTEGER NOT NULL
    ) WITHOUT ROWID;

    CREATE TABLE replacement_selection (
        entry_id TEXT NOT NULL,
        entry_usage_id TEXT NOT NULL,
        locale TEXT NOT NULL,
        explanation_id TEXT NOT NULL REFERENCES lesson_replacement(explanation_id),
        PRIMARY KEY (entry_id, entry_usage_id, locale)
    ) WITHOUT ROWID;

    CREATE TABLE lookup_miss (
        language_tag TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        normalization_version INTEGER NOT NULL,
        locale TEXT NOT NULL,
        outcome_kind TEXT NOT NULL CHECK (outcome_kind IN ('correction', 'negative')),
        payload_json TEXT NOT NULL,
        expires_at_ms INTEGER NOT NULL,
        PRIMARY KEY (language_tag, normalized_form, normalization_version, locale)
    ) WITHOUT ROWID;

    CREATE TABLE server_job (
        job_id TEXT PRIMARY KEY NOT NULL,
        canonical_key_hash TEXT NOT NULL,
        job_kind TEXT NOT NULL CHECK (
            job_kind IN ('resolveEntry', 'replaceExplanation')
        ),
        language_tag TEXT NOT NULL,
        normalized_form TEXT NOT NULL,
        locale TEXT NOT NULL,
        next_check_at_ms INTEGER NOT NULL,
        check_count INTEGER NOT NULL CHECK (check_count >= 0),
        event_id TEXT,
        state TEXT NOT NULL CHECK (state IN ('pending', 'finished')),
        updated_at_ms INTEGER NOT NULL,
        CHECK (
            (job_kind = 'resolveEntry' AND event_id IS NULL)
            OR
            (job_kind = 'replaceExplanation' AND event_id IS NOT NULL)
        )
    ) WITHOUT ROWID;

    CREATE INDEX server_job_lookup_idx
        ON server_job(language_tag, normalized_form, locale, state, updated_at_ms);

    CREATE TABLE entry_feedback_outbox (
        event_id TEXT PRIMARY KEY NOT NULL,
        payload_json TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
        feedback_sent_at_ms INTEGER,
        replacement_completed_at_ms INTEGER
    ) WITHOUT ROWID;

    CREATE INDEX entry_feedback_pending_idx
        ON entry_feedback_outbox(feedback_sent_at_ms, replacement_completed_at_ms, created_at_ms);
    """

    private static let schemaV1Guards = """
    CREATE TABLE IF NOT EXISTS feedback_outbox_quarantine (
        event_id TEXT PRIMARY KEY NOT NULL,
        payload_json TEXT NOT NULL,
        failure_reason TEXT NOT NULL,
        quarantined_at_ms INTEGER NOT NULL
    ) WITHOUT ROWID;

    CREATE TRIGGER IF NOT EXISTS server_job_kind_event_insert
    BEFORE INSERT ON server_job
    WHEN NOT (
        (NEW.job_kind = 'resolveEntry' AND NEW.event_id IS NULL)
        OR
        (NEW.job_kind = 'replaceExplanation' AND NEW.event_id IS NOT NULL)
    ) BEGIN
        SELECT RAISE(ABORT, 'server job kind/event binding is invalid');
    END;

    CREATE TRIGGER IF NOT EXISTS server_job_kind_event_update
    BEFORE UPDATE OF job_kind, event_id ON server_job
    WHEN NOT (
        (NEW.job_kind = 'resolveEntry' AND NEW.event_id IS NULL)
        OR
        (NEW.job_kind = 'replaceExplanation' AND NEW.event_id IS NOT NULL)
    ) BEGIN
        SELECT RAISE(ABORT, 'server job kind/event binding is invalid');
    END;
    """
}
