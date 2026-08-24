import CryptoKit
import Foundation

enum OfflineWordFormMorphology: Equatable, Sendable {
    case single(String)
    case combined([String])

    var values: [String] {
        switch self {
        case .single(let value):
            return [value]
        case .combined(let values):
            return values
        }
    }
}

struct OfflineVocabularyExplanation: Equatable, Sendable {
    let normalizedForm: String
    let displayForm: String
    let morphology: OfflineWordFormMorphology
    let senseID: String
    let lemma: String
    let explanationID: String
    let contentHash: String
    let schemaVersion: Int
    let explanation: VocabularyExplanation

    /// A learner-facing description of the requested spelling's relationship
    /// to its lemma. The SQLite pack supplies the morphology; the app never
    /// guesses suffixes or silently rewrites the word on-device.
    var grammaticalFormDescription: String? {
        guard normalizedForm != OfflineExplanationStore.normalizeForm(lemma) else {
            return nil
        }

        let labels = Set(morphology.values)
        let relationship: String?
        if labels.contains("past") && labels.contains("pastParticiple") {
            relationship = "past tense and past participle"
        } else if labels.contains("past") {
            relationship = "past tense"
        } else if labels.contains("pastParticiple") {
            relationship = "past participle"
        } else if labels.contains("presentParticiple") {
            relationship = "present participle"
        } else if labels.contains("thirdPersonSingular") {
            relationship = "third-person singular"
        } else if labels.contains("plural") {
            relationship = "plural"
        } else if labels.contains("comparative") {
            relationship = "comparative"
        } else if labels.contains("superlative") {
            relationship = "superlative"
        } else {
            relationship = nil
        }
        guard let relationship else { return nil }
        return "\(relationship) of \(lemma)"
    }
}

enum OfflineExplanationStoreError: LocalizedError {
    case unsupportedApplicationID(expected: Int64, actual: Int64)
    case unsupportedSchemaVersion(expected: Int64, actual: Int64)
    case missingTables([String])
    case invalidMemoryTechnique(String, explanationID: String)
    case invalidJSON(field: String, explanationID: String)
    case invalidMorphology(form: String, senseID: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedApplicationID(let expected, let actual):
            return "This is not a Wordbook content database (expected application ID \(expected), found \(actual))."
        case .unsupportedSchemaVersion(let expected, let actual):
            return "This Wordbook content database uses schema \(actual); this app supports schema \(expected)."
        case .missingTables(let tables):
            return "The Wordbook content database is incomplete (missing: \(tables.joined(separator: ", ")))."
        case .invalidMemoryTechnique(let value, let explanationID):
            return "Explanation \(explanationID) has an unknown memory technique: \(value)."
        case .invalidJSON(let field, let explanationID):
            return "Explanation \(explanationID) has invalid \(field) data."
        case .invalidMorphology(let form, let senseID):
            return "The form \(form) has invalid morphology data for sense \(senseID)."
        }
    }
}

/// Resolves a spelling (including an inflected spelling) to the curated default
/// sense stored in an immutable Wordbook content pack.
///
/// This is an additive foundation only. Callers choose when to use the store;
/// constructing it does not alter LocalTutor or application startup behavior.
final class OfflineExplanationStore: @unchecked Sendable {
    static let applicationID: Int64 = 1_463_960_400
    static let schemaVersion: Int64 = 1

    private static let requiredTables: Set<String> = [
        "metadata",
        "sense",
        "explanation",
        "word_form",
        "form_default",
        "book_membership",
    ]

    private let database: SQLiteReadOnlyDatabase

    init(databaseURL: URL) throws {
        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        try Self.validate(database)
        self.database = database
    }

    func explanation(for form: String) throws -> OfflineVocabularyExplanation? {
        let normalizedForm = Self.normalizeForm(form)
        guard !normalizedForm.isEmpty else {
            return nil
        }

        return try database.queryOne(
            """
            SELECT d.normalized_form,
                   wf.display_form,
                   wf.morphology_json,
                   s.sense_id,
                   s.lemma,
                   s.part_of_speech,
                   e.explanation_id,
                   e.content_hash,
                   e.schema_version,
                   e.meaning,
                   e.example,
                   e.memory_technique,
                   e.memory_aid_json,
                   e.synonyms_json
              FROM form_default AS d
              JOIN word_form AS wf
                ON wf.normalized_form = d.normalized_form
               AND wf.sense_id = d.sense_id
              JOIN sense AS s
                ON s.sense_id = d.sense_id
              JOIN explanation AS e
                ON e.sense_id = d.sense_id
             WHERE d.normalized_form = ?
             LIMIT 1
            """,
            bindings: [.text(normalizedForm)]
        ) { row in
            let storedNormalizedForm = try row.text(at: 0)
            let senseID = try row.text(at: 3)
            let explanationID = try row.text(at: 6)
            let techniqueValue = try row.optionalText(at: 11)
            let memoryTechnique: VocabularyMemoryTechnique?
            if let techniqueValue {
                guard let parsed = VocabularyMemoryTechnique(rawValue: techniqueValue) else {
                    throw OfflineExplanationStoreError.invalidMemoryTechnique(
                        techniqueValue,
                        explanationID: explanationID
                    )
                }
                memoryTechnique = parsed
            } else {
                memoryTechnique = nil
            }

            let memoryAid = try Self.decodeStringArray(
                try row.text(at: 12),
                field: "memory aid",
                explanationID: explanationID
            )
            let synonyms = try Self.decodeStringArray(
                try row.text(at: 13),
                field: "synonyms",
                explanationID: explanationID
            )

            return OfflineVocabularyExplanation(
                normalizedForm: storedNormalizedForm,
                displayForm: try row.text(at: 1),
                morphology: try Self.decodeMorphology(
                    try row.text(at: 2),
                    form: storedNormalizedForm,
                    senseID: senseID
                ),
                senseID: senseID,
                lemma: try row.text(at: 4),
                explanationID: explanationID,
                contentHash: try row.text(at: 7),
                schemaVersion: Int(try row.integer(at: 8)),
                explanation: VocabularyExplanation(
                    partOfSpeech: try row.text(at: 5),
                    meaning: try row.text(at: 9),
                    memoryTechnique: memoryTechnique,
                    memoryAid: memoryAid,
                    example: try row.text(at: 10),
                    synonyms: synonyms
                )
            )
        }
    }

    /// Uses the phrase-capable Unicode-15.1-pinned normalization primitive
    /// shared with content production and the API. Unsupported input fails
    /// closed to an empty key. Resolver request shape is deliberately checked
    /// separately at the network boundary so historical local keys such as
    /// `a.m.` remain addressable.
    static func normalizeForm(_ form: String) -> String {
        WordbookNormalizationV1.normalize(form) ?? ""
    }

    private static func validate(_ database: SQLiteReadOnlyDatabase) throws {
        let actualApplicationID = try database.queryOne("PRAGMA application_id") { row in
            try row.integer(at: 0)
        } ?? 0
        guard actualApplicationID == applicationID else {
            throw OfflineExplanationStoreError.unsupportedApplicationID(
                expected: applicationID,
                actual: actualApplicationID
            )
        }

        let actualSchemaVersion = try database.queryOne("PRAGMA user_version") { row in
            try row.integer(at: 0)
        } ?? 0
        guard actualSchemaVersion == schemaVersion else {
            throw OfflineExplanationStoreError.unsupportedSchemaVersion(
                expected: schemaVersion,
                actual: actualSchemaVersion
            )
        }

        let tables = Set(try database.query(
            "SELECT name FROM sqlite_schema WHERE type = 'table'"
        ) { row in
            try row.text(at: 0)
        })
        let missingTables = requiredTables.subtracting(tables).sorted()
        guard missingTables.isEmpty else {
            throw OfflineExplanationStoreError.missingTables(missingTables)
        }
    }

    private static func decodeStringArray(
        _ json: String,
        field: String,
        explanationID: String
    ) throws -> [String] {
        do {
            return try JSONDecoder().decode([String].self, from: Data(json.utf8))
        } catch {
            throw OfflineExplanationStoreError.invalidJSON(
                field: field,
                explanationID: explanationID
            )
        }
    }

    private static func decodeMorphology(
        _ json: String,
        form: String,
        senseID: String
    ) throws -> OfflineWordFormMorphology {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if let value = try? decoder.decode(String.self, from: data), !value.isEmpty {
            return .single(value)
        }
        if let values = try? decoder.decode([String].self, from: data),
           !values.isEmpty,
           values.allSatisfy({ !$0.isEmpty }) {
            return .combined(values)
        }
        throw OfflineExplanationStoreError.invalidMorphology(
            form: form,
            senseID: senseID
        )
    }
}

// MARK: - Entry-first schema-2 catalog

enum EntryCatalogStoreError: LocalizedError {
    case unsupportedApplicationID(expected: Int64, actual: Int64)
    case unsupportedSchemaVersion(expected: Int64, actual: Int64)
    case missingTables([String])
    case invalidRecord(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedApplicationID(let expected, let actual):
            return "This is not a Wordbook content database (expected application ID \(expected), found \(actual))."
        case .unsupportedSchemaVersion(let expected, let actual):
            return "This Wordbook content database uses schema \(actual); this app supports schema \(expected)."
        case .missingTables(let tables):
            return "The Wordbook Entry catalog is incomplete (missing: \(tables.joined(separator: ", ")))."
        case .invalidRecord(let reason):
            return "The Wordbook Entry catalog contains an invalid record: \(reason)"
        }
    }
}

/// Reads one complete learner-facing Entry by exact normalized spelling.
/// It deliberately has no lemma/sense/morphology query surface.
final class EntryCatalogStore: @unchecked Sendable {
    static let applicationID: Int64 = OfflineExplanationStore.applicationID
    static let schemaVersion: Int64 = 2
    static let normalizationVersion = 1
    static let normalizationContractSHA256 = WordbookNormalizationV1.contractSHA256
    static let resolverContractVersion = 1

    private static let requiredTables: Set<String> = [
        "metadata",
        "word_entry",
        "entry_usage",
        "released_lesson_variant",
        "entry_default",
        "entry_coverage",
    ]

    private struct Header {
        let entryID: String
        let displayForm: String
        let normalizedForm: String
        let language: String
        let normalizationVersion: Int
        let entryRevision: Int
        let locale: String
        let coverageRevision: Int
        let expectedUsageCount: Int
        let expectedCoreCount: Int
        let hasMoreUsages: Bool
        let coverageState: EntryCoverageState
        let contentVersion: String
        let usageSelectionPolicyVersion: Int
        let lessonContractVersion: Int
        let validatorVersion: Int
        let reviewPolicyVersion: Int
    }

    private let database: SQLiteReadOnlyDatabase
    let contentVersion: String

    init(databaseURL: URL) throws {
        let database = try SQLiteReadOnlyDatabase(url: databaseURL)
        try Self.validateDatabase(database)
        guard let contentVersion = try database.queryOne(
            "SELECT value FROM metadata WHERE key = 'content_version'",
            transform: { try $0.text(at: 0) }
        ),
              !contentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EntryCatalogStoreError.invalidRecord(
                "metadata is missing content_version"
            )
        }
        let mismatchedCoverageVersions = try database.queryOne(
            "SELECT COUNT(*) FROM entry_coverage WHERE content_version <> ?",
            bindings: [.text(contentVersion)],
            transform: { try $0.integer(at: 0) }
        ) ?? 0
        guard mismatchedCoverageVersions == 0 else {
            throw EntryCatalogStoreError.invalidRecord(
                "entry coverage content_version does not match catalog metadata"
            )
        }
        self.database = database
        self.contentVersion = contentVersion
    }

    func entry(
        for surfaceForm: String,
        language: String = "en",
        locale: String = "en"
    ) throws -> ResolvedWordEntry? {
        let normalizedForm = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalizedForm.isEmpty,
              EntryContractValidator.hasValidLocaleSyntax(locale) else { return nil }
        let normalizedLanguage = language.lowercased()
        let normalizedLocale = EntryContractValidator.canonicalLocale(locale)
        let languageLocale = normalizedLocale.split(separator: "-").first
            .map(String.init)?.lowercased() ?? normalizedLanguage

        guard let header: Header = try database.queryOne(
            """
            SELECT we.entry_id,
                   we.display_form,
                   we.normalized_form,
                   we.language_tag,
                   we.normalization_version,
                   we.entry_revision,
                   ec.locale,
                   ec.coverage_revision,
                   ec.expected_usage_count,
                   ec.expected_core_count,
                   ec.has_more_usages,
                   ec.coverage_state,
                   ec.content_version,
                   ec.usage_selection_policy_version,
                   ec.lesson_contract_version,
                   ec.validator_version,
                   ec.review_policy_version
              FROM word_entry AS we
              JOIN entry_coverage AS ec ON ec.entry_id = we.entry_id
             WHERE we.language_tag = ?
               AND we.normalized_form = ?
               AND we.normalization_version = ?
               AND ec.locale IN (?, ?, 'en')
             ORDER BY CASE ec.locale
                        WHEN ? THEN 0
                        WHEN ? THEN 1
                        WHEN 'en' THEN 2
                        ELSE 3
                      END
             LIMIT 1
            """,
            bindings: [
                .text(normalizedLanguage),
                .text(normalizedForm),
                .integer(Int64(Self.normalizationVersion)),
                .text(normalizedLocale),
                .text(languageLocale),
                .text(normalizedLocale),
                .text(languageLocale),
            ],
            transform: { row -> Header in
            guard let coverageState = EntryCoverageState(
                rawValue: try row.text(at: 11)
            ) else {
                throw EntryCatalogStoreError.invalidRecord(
                    "unsupported coverage state"
                )
            }
            return Header(
                entryID: try row.text(at: 0),
                displayForm: try row.text(at: 1),
                normalizedForm: try row.text(at: 2),
                language: try row.text(at: 3),
                normalizationVersion: Int(try row.integer(at: 4)),
                entryRevision: Int(try row.integer(at: 5)),
                locale: try row.text(at: 6),
                coverageRevision: Int(try row.integer(at: 7)),
                expectedUsageCount: Int(try row.integer(at: 8)),
                expectedCoreCount: Int(try row.integer(at: 9)),
                hasMoreUsages: try row.integer(at: 10) == 1,
                coverageState: coverageState,
                contentVersion: try row.text(at: 12),
                usageSelectionPolicyVersion: Int(try row.integer(at: 13)),
                lessonContractVersion: Int(try row.integer(at: 14)),
                validatorVersion: Int(try row.integer(at: 15)),
                reviewPolicyVersion: Int(try row.integer(at: 16))
            )
        }) else {
            return nil
        }

        let usages = try database.query(
            """
            SELECT eu.entry_usage_id,
                   eu.learner_label,
                   eu.part_of_speech_label,
                   eu.pronunciation_json,
                   eu.form_relation_label,
                   eu.context_vector_format_version,
                   eu.context_vector,
                   eu.display_order,
                   eu.commonness_rank,
                   eu.is_core,
                   lv.explanation_id,
                   lv.content_hash,
                   lv.schema_version,
                   lv.lesson_contract_version,
                   lv.validator_version,
                   lv.review_policy_version,
                   lv.content_revision,
                   lv.trust_state,
                   lv.direct_explanation,
                   lv.example,
                   lv.synonyms_json,
                   lv.memory_cue_json
              FROM entry_usage AS eu
              JOIN entry_default AS ed
                ON ed.entry_id = eu.entry_id
               AND ed.entry_usage_id = eu.entry_usage_id
               AND ed.locale = ?
              JOIN released_lesson_variant AS lv
                ON lv.explanation_id = ed.explanation_id
               AND lv.entry_id = eu.entry_id
               AND lv.entry_usage_id = eu.entry_usage_id
               AND lv.locale = ed.locale
             WHERE eu.entry_id = ?
             ORDER BY eu.display_order, eu.entry_usage_id
            """,
            bindings: [.text(header.locale), .text(header.entryID)]
        ) { row in
            let usageID = try row.text(at: 0)
            let pronunciations: [Pronunciation] = try Self.decodeJSON(
                try row.text(at: 3),
                field: "pronunciation",
                recordID: usageID
            )
            let contextVector: ContextRankingVector?
            if let format = try row.optionalInteger(at: 5),
               let bytes = try row.optionalData(at: 6) {
                contextVector = ContextRankingVector(
                    formatVersion: Int(format),
                    values: bytes.map { Int8(bitPattern: $0) }
                )
            } else if try row.optionalInteger(at: 5) == nil,
                      try row.optionalData(at: 6) == nil {
                contextVector = nil
            } else {
                throw EntryCatalogStoreError.invalidRecord(
                    "usage \(usageID) has a partial context vector"
                )
            }

            let explanationID = try row.text(at: 10)
            let memoryCue: MemoryCue?
            if let memoryJSON = try row.optionalText(at: 21) {
                memoryCue = try Self.decodeJSON(
                    memoryJSON,
                    field: "memory cue",
                    recordID: explanationID
                )
            } else {
                memoryCue = nil
            }
            let content = TeacherLessonContent(
                directExplanation: try row.text(at: 18),
                example: try row.text(at: 19),
                synonyms: try Self.decodeJSON(
                    try row.text(at: 20),
                    field: "synonyms",
                    recordID: explanationID
                ),
                memoryCue: memoryCue
            )
            guard let trustState = LessonTrustState(rawValue: try row.text(at: 17)) else {
                throw EntryCatalogStoreError.invalidRecord(
                    "lesson \(explanationID) has an unsupported trust state"
                )
            }
            return UsageLesson(
                entryUsageID: usageID,
                learnerLabel: try row.optionalText(at: 1),
                partOfSpeechLabel: try row.optionalText(at: 2),
                pronunciations: pronunciations,
                formRelationLabel: try row.optionalText(at: 4),
                contextVector: contextVector,
                displayOrder: Int(try row.integer(at: 7)),
                commonnessRank: Int(try row.integer(at: 8)),
                isCore: try row.integer(at: 9) == 1,
                explanationID: explanationID,
                contentHash: try row.text(at: 11),
                schemaVersion: Int(try row.integer(at: 12)),
                lessonContractVersion: Int(try row.integer(at: 13)),
                validatorVersion: Int(try row.integer(at: 14)),
                reviewPolicyVersion: Int(try row.integer(at: 15)),
                contentRevision: Int(try row.integer(at: 16)),
                trustState: trustState,
                content: content
            )
        }

        let entry = ResolvedWordEntry(
            entryID: header.entryID,
            encounteredSurfaceForm: surfaceForm,
            displayForm: header.displayForm,
            normalizedForm: header.normalizedForm,
            language: header.language,
            locale: header.locale,
            usages: usages,
            preferredEntryUsageID: usages.first?.entryUsageID ?? "",
            orderingSource: .build,
            expectedUsageCount: header.expectedUsageCount,
            expectedCoreCount: header.expectedCoreCount,
            hasMoreUsages: header.hasMoreUsages,
            coverageState: header.coverageState,
            contentVersion: header.contentVersion,
            baseContentVersion: header.contentVersion,
            entryRevision: header.entryRevision,
            coverageRevision: header.coverageRevision,
            usageSelectionPolicyVersion: header.usageSelectionPolicyVersion,
            normalizationVersion: header.normalizationVersion,
            resolverContractVersion: Self.resolverContractVersion
        )
        try EntryContractValidator.validate(
            entry,
            expectedSurfaceForm: surfaceForm,
            expectedCatalogVersions: (
                header.lessonContractVersion,
                header.validatorVersion,
                header.reviewPolicyVersion
            )
        )
        return entry
    }

    private static func validateDatabase(_ database: SQLiteReadOnlyDatabase) throws {
        let actualApplicationID = try database.queryOne("PRAGMA application_id") {
            try $0.integer(at: 0)
        } ?? 0
        guard actualApplicationID == applicationID else {
            throw EntryCatalogStoreError.unsupportedApplicationID(
                expected: applicationID,
                actual: actualApplicationID
            )
        }
        let actualSchemaVersion = try database.queryOne("PRAGMA user_version") {
            try $0.integer(at: 0)
        } ?? 0
        guard actualSchemaVersion == schemaVersion else {
            throw EntryCatalogStoreError.unsupportedSchemaVersion(
                expected: schemaVersion,
                actual: actualSchemaVersion
            )
        }
        let tables = Set(try database.query(
            "SELECT name FROM sqlite_schema WHERE type = 'table'"
        ) { try $0.text(at: 0) })
        let missing = requiredTables.subtracting(tables).sorted()
        guard missing.isEmpty else {
            throw EntryCatalogStoreError.missingTables(missing)
        }
        let foreignKeyFailures = try database.query("PRAGMA foreign_key_check") { _ in true }
        guard foreignKeyFailures.isEmpty else {
            throw EntryCatalogStoreError.invalidRecord("foreign-key check failed")
        }
    }

    private static func decodeJSON<Value: Decodable>(
        _ json: String,
        field: String,
        recordID: String
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        } catch {
            throw EntryCatalogStoreError.invalidRecord(
                "\(recordID) has invalid \(field) JSON"
            )
        }
    }
}

enum EntryContractValidator {
    static let lessonSchemaVersion = 2
    static let lessonContractVersion = 2
    static let validatorVersion = 2
    static let normalizationVersion = 1
    static let normalizationContractSHA256 = WordbookNormalizationV1.contractSHA256
    static let resolverContractVersion = 1
    static let usageSelectionPolicyVersion = 1
    static let minimumReviewPolicyVersion = 5

    static func validate(
        _ entry: ResolvedWordEntry,
        expectedSurfaceForm: String,
        expectedCatalogVersions: (lesson: Int, validator: Int, review: Int)? = nil
    ) throws {
		try validate(
			entry,
			expectedSurfaceForm: expectedSurfaceForm,
			expectedCatalogVersions: expectedCatalogVersions,
			allowServerReviewedSidecars: false
		)
	}

	/// Validates the private learner-facing view produced after independently
	/// reviewed lesson sidecars are applied to a strict immutable snapshot. This
	/// must not be used for catalog, overlay snapshot, or server Entry payloads.
	static func validateMaterializedView(
		_ entry: ResolvedWordEntry,
		expectedSurfaceForm: String
	) throws {
		try validate(
			entry,
			expectedSurfaceForm: expectedSurfaceForm,
			expectedCatalogVersions: nil,
			allowServerReviewedSidecars: true
		)
	}

	private static func validate(
		_ entry: ResolvedWordEntry,
		expectedSurfaceForm: String,
		expectedCatalogVersions: (lesson: Int, validator: Int, review: Int)?,
		allowServerReviewedSidecars: Bool
	) throws {
        let normalized = OfflineExplanationStore.normalizeForm(expectedSurfaceForm)
        guard !normalized.isEmpty,
              entry.normalizedForm == normalized,
              OfflineExplanationStore.normalizeForm(entry.normalizedForm) == normalized,
              entry.normalizationVersion == normalizationVersion,
              entry.resolverContractVersion == resolverContractVersion,
              !entry.entryID.isEmpty,
              !entry.displayForm.isEmpty,
              !entry.language.isEmpty,
              !entry.locale.isEmpty,
              entry.entryRevision > 0,
              entry.coverageRevision > 0,
              entry.coverageRevision <= entry.entryRevision,
              entry.language == "en",
              isCanonicalLocale(entry.locale),
              entry.usageSelectionPolicyVersion == usageSelectionPolicyVersion else {
            throw EntryCatalogStoreError.invalidRecord("Entry identity or versions are inconsistent")
        }
        guard !entry.contentVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              !entry.baseContentVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              entry.coverageState != .releaseReviewedComplete
                || entry.baseContentVersion == entry.contentVersion else {
            throw EntryCatalogStoreError.invalidRecord(
                "Entry content-version lineage is inconsistent"
            )
        }
        guard entry.coverageState == .releaseReviewedComplete
                || entry.coverageState == .serverReviewedComplete,
              entry.expectedUsageCount == entry.usages.count,
              entry.expectedUsageCount > 0,
              (1...4).contains(entry.expectedCoreCount),
              entry.expectedCoreCount <= entry.expectedUsageCount,
              entry.hasMoreUsages == (entry.expectedUsageCount > entry.expectedCoreCount),
              entry.usages.first?.entryUsageID == entry.preferredEntryUsageID else {
            throw EntryCatalogStoreError.invalidRecord("Entry coverage is incomplete")
        }

        var usageIDs = Set<String>()
        var explanationIDs = Set<String>()
        for (index, usage) in entry.usages.enumerated() {
            guard !usage.entryUsageID.isEmpty,
                  usageIDs.insert(usage.entryUsageID).inserted,
                  usage.displayOrder == index,
                  usage.isCore == (index < entry.expectedCoreCount),
                  usage.commonnessRank >= 0,
                  usage.schemaVersion == lessonSchemaVersion,
                  usage.lessonContractVersion == lessonContractVersion,
                  usage.validatorVersion >= validatorVersion,
                  usage.reviewPolicyVersion >= minimumReviewPolicyVersion,
                  usage.contentRevision > 0,
                  explanationIDs.insert(usage.explanationID).inserted,
                  !usage.content.directExplanation.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !usage.content.example.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  usage.content.synonyms.allSatisfy({ !$0.isEmpty }),
                  usage.content.memoryCue?.segments.isEmpty != true,
                  usage.pronunciations.allSatisfy({
                    !$0.ipa.isEmpty && hasValidLocaleSyntax($0.locale)
                  }) else {
                throw EntryCatalogStoreError.invalidRecord(
                    "Usage \(usage.entryUsageID) is incomplete"
                )
            }
			let trustIsValid: Bool
			switch entry.coverageState {
			case .releaseReviewedComplete where allowServerReviewedSidecars:
				trustIsValid = usage.trustState == .releaseReviewed
					|| usage.trustState == .serverReviewed
			case .releaseReviewedComplete:
				trustIsValid = usage.trustState == .releaseReviewed
			case .serverReviewedComplete:
				trustIsValid = usage.trustState == .serverReviewed
			}
			guard trustIsValid else {
                throw EntryCatalogStoreError.invalidRecord(
                    "Usage \(usage.entryUsageID) trust does not match Entry coverage"
                )
            }
            if let expectedCatalogVersions {
                guard usage.lessonContractVersion == expectedCatalogVersions.lesson,
                      usage.validatorVersion == expectedCatalogVersions.validator,
                      usage.reviewPolicyVersion == expectedCatalogVersions.review else {
                    throw EntryCatalogStoreError.invalidRecord(
                        "Usage \(usage.entryUsageID) is incompatible with catalog coverage"
                    )
                }
            }
            try validateContentIdentity(
                usage,
                entryID: entry.entryID,
                normalizedForm: entry.normalizedForm,
                language: entry.language,
                locale: entry.locale
            )
        }
    }

    /// The exact reviewed selection decision carried by coverageRevision.
    /// Lesson prose and presentation-only metadata deliberately do not belong
    /// to this projection.
    static func hasSameCoverageProjection(
        _ lhs: ResolvedWordEntry,
        _ rhs: ResolvedWordEntry
    ) -> Bool {
        guard lhs.usageSelectionPolicyVersion == rhs.usageSelectionPolicyVersion,
              lhs.expectedUsageCount == rhs.expectedUsageCount,
              lhs.expectedCoreCount == rhs.expectedCoreCount,
              lhs.hasMoreUsages == rhs.hasMoreUsages,
              lhs.usages.count == rhs.usages.count else { return false }
        return zip(lhs.usages, rhs.usages).allSatisfy { left, right in
            left.entryUsageID == right.entryUsageID
                && left.displayOrder == right.displayOrder
                && left.commonnessRank == right.commonnessRank
                && left.isCore == right.isCore
        }
    }

    static func isValidCoverageAdvance(
        _ candidate: ResolvedWordEntry,
        over current: ResolvedWordEntry
    ) -> Bool {
        guard candidate.entryRevision > current.entryRevision,
              candidate.coverageRevision >= current.coverageRevision else {
            return false
        }
        let projectionChanged = !hasSameCoverageProjection(candidate, current)
        let coverageAdvanced = candidate.coverageRevision > current.coverageRevision
        return projectionChanged == coverageAdvanced
    }

    /// Exact ASCII grammar shared with the Go v3 contract:
    /// `^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$`.
    ///
    /// This deliberately does not use CharacterSet letter classes, which
    /// accept non-ASCII Unicode scalars and would make the Swift client more
    /// permissive than the server.
    static func hasValidLocaleSyntax(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first,
              (2...8).contains(language.utf8.count),
              language.utf8.allSatisfy(Self.isASCIILetter) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.utf8.count)
                && part.utf8.allSatisfy(Self.isASCIILetterOrDigit)
        }
    }

    static func isCanonicalLocale(_ value: String) -> Bool {
        hasValidLocaleSyntax(value) && canonicalLocale(value) == value
    }

    static func canonicalLocale(_ value: String) -> String {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, !language.isEmpty else { return value }
        return ([language.lowercased()] + parts.dropFirst().map { part in
            let value = String(part)
            if value.utf8.count == 2 && value.utf8.allSatisfy(Self.isASCIILetter) {
                return value.uppercased()
            }
            return value.lowercased()
        }).joined(separator: "-")
    }

    private static func isASCIILetter(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isASCIILetterOrDigit(_ value: UInt8) -> Bool {
        isASCIILetter(value) || (48...57).contains(value)
    }

    static func validateContentIdentity(
        _ usage: UsageLesson,
        entryID: String,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws {
        let memoryCue: Any
        if let cue = usage.content.memoryCue {
            memoryCue = [
                "technique": cue.technique.rawValue,
                "segments": cue.segments.map {
                    ["emphasized": $0.emphasized, "text": $0.text] as [String: Any]
                },
            ] as [String: Any]
        } else {
            memoryCue = NSNull()
        }
        let envelope: [String: Any] = [
            "directExplanation": usage.content.directExplanation,
            "entryID": entryID,
            "entryUsageID": usage.entryUsageID,
            "example": usage.content.example,
            "language": language,
            "lessonContractVersion": usage.lessonContractVersion,
            "locale": locale,
            "memoryCue": memoryCue,
            "normalizedForm": normalizedForm,
            "schemaVersion": usage.schemaVersion,
            "synonyms": usage.content.synonyms,
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw EntryCatalogStoreError.invalidRecord("lesson cannot be canonicalized")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw EntryCatalogStoreError.invalidRecord("lesson cannot be canonicalized")
        }
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard usage.contentHash == hash,
              usage.explanationID == "exp_\(hash)" else {
            throw EntryCatalogStoreError.invalidRecord(
                "lesson \(usage.explanationID) has a mismatched immutable identity"
            )
        }
    }
}
