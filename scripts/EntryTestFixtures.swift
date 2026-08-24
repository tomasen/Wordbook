import CryptoKit
import Foundation

enum EntryFixtureError: LocalizedError {
    case invalidJSON

    var errorDescription: String? { "Entry fixture JSON is invalid." }
}

enum EntryTestFixtures {
    struct UsageSpec {
        let id: String
        let label: String
        let partOfSpeech: String
        let relation: String?
        let ipa: String
        let pronunciationLocale: String
        let explanation: String
        let example: String
        let synonyms: [String]
        let core: Bool

        init(
            id: String,
            label: String,
            partOfSpeech: String,
            relation: String?,
            ipa: String,
            pronunciationLocale: String = "en-US",
            explanation: String,
            example: String,
            synonyms: [String],
            core: Bool
        ) {
            self.id = id
            self.label = label
            self.partOfSpeech = partOfSpeech
            self.relation = relation
            self.ipa = ipa
            self.pronunciationLocale = pronunciationLocale
            self.explanation = explanation
            self.example = example
            self.synonyms = synonyms
            self.core = core
        }
    }

    static func sawEntry(
        surfaceForm: String = "saw",
        revision: Int = 1,
        coverageRevision: Int = 1,
        contentVersion: String = "server-saw-v1",
        baseContentVersion: String = "catalog-v1",
        trust: LessonTrustState = .serverReviewed,
        coverage: EntryCoverageState = .serverReviewedComplete,
        toolExplanation: String = "A tool with a toothed blade for cutting wood or other hard materials.",
        language: String = "en",
        locale: String = "en"
    ) throws -> ResolvedWordEntry {
        try entry(
            surfaceForm: surfaceForm,
            entryID: "entry-saw-opaque",
            revision: revision,
            coverageRevision: coverageRevision,
            contentVersion: contentVersion,
            baseContentVersion: baseContentVersion,
            trust: trust,
            coverage: coverage,
            language: language,
            locale: locale,
            specs: [
                UsageSpec(
                    id: "usage-seeing-opaque",
                    label: "earlier seeing or meeting",
                    partOfSpeech: "verb",
                    relation: "past form of see",
                    ipa: "sɔ",
                    explanation: "Noticed or watched something, or met someone, at an earlier time.",
                    example: "I saw a fox cross the road on my way home.",
                    synonyms: ["noticed", "watched"],
                    core: true
                ),
                UsageSpec(
                    id: "usage-tool-opaque",
                    label: "cutting tool",
                    partOfSpeech: "noun",
                    relation: nil,
                    ipa: "sɔ",
                    explanation: toolExplanation,
                    example: "He used a saw to cut the board into two shorter pieces.",
                    synonyms: ["handsaw"],
                    core: true
                ),
            ]
        )
    }

    static func entry(
        surfaceForm: String,
        entryID: String,
        revision: Int,
        coverageRevision: Int,
        contentVersion: String,
        baseContentVersion: String,
        trust: LessonTrustState,
        coverage: EntryCoverageState,
        language: String = "en",
        locale: String = "en",
        specs: [UsageSpec]
    ) throws -> ResolvedWordEntry {
        let normalized = OfflineExplanationStore.normalizeForm(surfaceForm)
        let coreCount = specs.filter(\.core).count
        let usages = try specs.enumerated().map { index, spec in
            try usage(
                spec,
                entryID: entryID,
                normalizedForm: normalized,
                index: index,
                trust: trust,
                contentRevision: revision,
                language: language,
                locale: locale
            )
        }
        return ResolvedWordEntry(
            entryID: entryID,
            encounteredSurfaceForm: surfaceForm,
            displayForm: normalized,
            normalizedForm: normalized,
            language: language,
            locale: locale,
            usages: usages,
            preferredEntryUsageID: usages[0].entryUsageID,
            orderingSource: trust == .releaseReviewed ? .build : .server,
            expectedUsageCount: usages.count,
            expectedCoreCount: coreCount,
            hasMoreUsages: usages.count > coreCount,
            coverageState: coverage,
            contentVersion: contentVersion,
            baseContentVersion: baseContentVersion,
            entryRevision: revision,
            coverageRevision: coverageRevision,
            usageSelectionPolicyVersion: 1,
            normalizationVersion: EntryContractValidator.normalizationVersion,
            resolverContractVersion: EntryContractValidator.resolverContractVersion
        )
    }

    static func replacement(
        for entry: ResolvedWordEntry,
        usageID: String,
        explanation: String,
        example: String
    ) throws -> EntryLessonReplacement {
        guard let base = entry.usages.first(where: { $0.entryUsageID == usageID }) else {
            throw EntryFixtureError.invalidJSON
        }
        let content = TeacherLessonContent(
            directExplanation: explanation,
            example: example,
            synonyms: base.content.synonyms,
            memoryCue: nil
        )
        let identity = try lessonIdentity(
            entryID: entry.entryID,
            usageID: usageID,
            normalizedForm: entry.normalizedForm,
            content: content,
            language: entry.language,
            locale: entry.locale
        )
        return EntryLessonReplacement(
            entryID: entry.entryID,
            entryUsageID: usageID,
            locale: entry.locale,
            baseEntryRevision: entry.entryRevision,
            baseExplanationID: base.explanationID,
            baseContentVersion: entry.contentVersion,
            explanationID: identity.id,
            contentHash: identity.hash,
            schemaVersion: EntryContractValidator.lessonSchemaVersion,
            lessonContractVersion: EntryContractValidator.lessonContractVersion,
            validatorVersion: 2,
            reviewPolicyVersion: EntryContractValidator.minimumReviewPolicyVersion,
            contentRevision: base.contentRevision + 1,
            trustState: .serverReviewed,
            content: content
        )
    }

    static func context(_ text: String, target: String) -> EntryResolveContext {
        let bytes = Array(text.utf8)
        let targetBytes = Array(target.utf8)
        let start = bytes.indices.first(where: { index in
            let end = index + targetBytes.count
            return end <= bytes.count && Array(bytes[index..<end]) == targetBytes
        }) ?? 0
        return EntryResolveContext(
            text: text,
            targetStart: start,
            targetLength: targetBytes.count
        )
    }

    private static func usage(
        _ spec: UsageSpec,
        entryID: String,
        normalizedForm: String,
        index: Int,
        trust: LessonTrustState,
        contentRevision: Int,
        language: String,
        locale: String
    ) throws -> UsageLesson {
        let content = TeacherLessonContent(
            directExplanation: spec.explanation,
            example: spec.example,
            synonyms: spec.synonyms,
            memoryCue: nil
        )
        let identity = try lessonIdentity(
            entryID: entryID,
            usageID: spec.id,
            normalizedForm: normalizedForm,
            content: content,
            language: language,
            locale: locale
        )
        return UsageLesson(
            entryUsageID: spec.id,
            learnerLabel: spec.label,
            partOfSpeechLabel: spec.partOfSpeech,
            pronunciations: [Pronunciation(
                ipa: spec.ipa,
                locale: spec.pronunciationLocale
            )],
            formRelationLabel: spec.relation,
            contextVector: nil,
            displayOrder: index,
            commonnessRank: index + 1,
            isCore: spec.core,
            explanationID: identity.id,
            contentHash: identity.hash,
            schemaVersion: EntryContractValidator.lessonSchemaVersion,
            lessonContractVersion: EntryContractValidator.lessonContractVersion,
            validatorVersion: 2,
            reviewPolicyVersion: EntryContractValidator.minimumReviewPolicyVersion,
            contentRevision: contentRevision,
            trustState: trust,
            content: content
        )
    }

    private static func lessonIdentity(
        entryID: String,
        usageID: String,
        normalizedForm: String,
        content: TeacherLessonContent,
        language: String,
        locale: String
    ) throws -> (id: String, hash: String) {
        let memoryCue: Any
        if let cue = content.memoryCue {
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
            "directExplanation": content.directExplanation,
            "entryID": entryID,
            "entryUsageID": usageID,
            "example": content.example,
            "language": language,
            "lessonContractVersion": EntryContractValidator.lessonContractVersion,
            "locale": locale,
            "memoryCue": memoryCue,
            "normalizedForm": normalizedForm,
            "schemaVersion": EntryContractValidator.lessonSchemaVersion,
            "synonyms": content.synonyms,
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else {
            throw EntryFixtureError.invalidJSON
        }
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return ("exp_\(hash)", hash)
    }
}
