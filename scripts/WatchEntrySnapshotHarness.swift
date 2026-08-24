import CryptoKit
import Foundation

enum WatchSnapshotHarnessFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw WatchSnapshotHarnessFailure.message(message)
    }
}

private struct UsageSpec {
    let id: String
    let label: String
    let partOfSpeech: String
    let relation: String?
    let explanation: String
    let example: String
    let synonyms: [String]
}

private func makeEntry(
    form: String,
    specs: [UsageSpec],
    revision: Int = 1,
    preferredUsageIndex: Int = 0,
    pronunciationByUsage: [String] = []
) throws -> ResolvedWordEntry {
    let entryID = "entry-\(form)"
    let usages = try specs.enumerated().map { index, spec in
        let content = TeacherLessonContent(
            directExplanation: spec.explanation,
            example: spec.example,
            synonyms: spec.synonyms,
            memoryCue: index == 0
                ? MemoryCue(
                    technique: .contrast,
                    segments: [
                        LessonTextSegment(
                            text: "Keep the two everyday meanings apart by context.",
                            emphasized: false
                        ),
                    ]
                )
                : nil
        )
        let hash = try contentHash(
            entryID: entryID,
            usageID: spec.id,
            normalizedForm: form,
            content: content
        )
        return UsageLesson(
            entryUsageID: spec.id,
            learnerLabel: spec.label,
            partOfSpeechLabel: spec.partOfSpeech,
            pronunciations: [Pronunciation(
                ipa: pronunciationByUsage.indices.contains(index)
                    ? pronunciationByUsage[index]
                    : "sɔ",
                locale: "en-US"
            )],
            formRelationLabel: spec.relation,
            contextVector: nil,
            displayOrder: index,
            commonnessRank: index + 1,
            isCore: true,
            explanationID: "exp_\(hash)",
            contentHash: hash,
            schemaVersion: 2,
            lessonContractVersion: 2,
            validatorVersion: 2,
            reviewPolicyVersion: 5,
            contentRevision: revision,
            trustState: .releaseReviewed,
            content: content
        )
    }
    return ResolvedWordEntry(
        entryID: entryID,
        encounteredSurfaceForm: form,
        displayForm: form,
        normalizedForm: form,
        language: "en",
        locale: "en",
        usages: usages,
        preferredEntryUsageID: usages[preferredUsageIndex].entryUsageID,
        orderingSource: .build,
        expectedUsageCount: usages.count,
        expectedCoreCount: usages.count,
        hasMoreUsages: false,
        coverageState: .releaseReviewedComplete,
        contentVersion: "watch-harness-v1",
        baseContentVersion: "watch-harness-v1",
        entryRevision: revision,
        coverageRevision: 1,
        usageSelectionPolicyVersion: 1,
        normalizationVersion: 1,
        resolverContractVersion: 1
    )
}

private func contentHash(
    entryID: String,
    usageID: String,
    normalizedForm: String,
    content: TeacherLessonContent
) throws -> String {
    let memoryCue: Any
    if let cue = content.memoryCue {
        memoryCue = [
            "technique": cue.technique.rawValue,
            "segments": cue.segments.map {
                ["emphasized": $0.emphasized, "text": $0.text]
                    as [String: Any]
            },
        ] as [String: Any]
    } else {
        memoryCue = NSNull()
    }
    let identity: [String: Any] = [
        "directExplanation": content.directExplanation,
        "entryID": entryID,
        "entryUsageID": usageID,
        "example": content.example,
        "language": "en",
        "lessonContractVersion": 2,
        "locale": "en",
        "memoryCue": memoryCue,
        "normalizedForm": normalizedForm,
        "schemaVersion": 2,
        "synonyms": content.synonyms,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: identity,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func sawEntry(
    preferredUsageIndex: Int = 0,
    pronunciationByUsage: [String] = []
) throws -> ResolvedWordEntry {
    try makeEntry(
        form: "saw",
        specs: [
            UsageSpec(
                id: "usage-saw-seeing",
                label: "earlier seeing or meeting",
                partOfSpeech: "verb",
                relation: "past form of see",
                explanation: "Noticed or watched something, or met someone, at an earlier time.",
                example: "I saw a fox cross the road on my way home.",
                synonyms: ["noticed", "watched"]
            ),
            UsageSpec(
                id: "usage-saw-tool",
                label: "cutting tool",
                partOfSpeech: "noun",
                relation: nil,
                explanation: "A tool with a toothed blade for cutting wood or other hard materials.",
                example: "He used a saw to cut the board into two shorter pieces.",
                synonyms: ["handsaw"]
            ),
        ],
        preferredUsageIndex: preferredUsageIndex,
        pronunciationByUsage: pronunciationByUsage
    )
}

@main
struct WatchEntrySnapshotHarness {
    static func main() throws {
        let saw = try sawEntry()
        try require(
            saw.preferredPronunciationPhonemes == "sɔ",
            "preferred reviewed pronunciation was not selected"
        )
        let reorderedPronunciation = try sawEntry(
            preferredUsageIndex: 1,
            pronunciationByUsage: ["sɔ", "sɑ"]
        )
        try require(
            reorderedPronunciation.preferredPronunciationPhonemes == "sɑ",
            "pronunciation ignored preferredEntryUsageID"
        )
        let missingPreferredPronunciation = try sawEntry(
            pronunciationByUsage: ["   ", "sɑ"]
        )
        try require(
            missingPreferredPronunciation.preferredPronunciationPhonemes == "sɑ",
            "pronunciation did not fall back within the complete Entry"
        )
        let snapshot = try WatchEntrySnapshot(
            entry: saw,
            capturedAtMilliseconds: 1_000
        )
        let wire = try snapshot.encoded()
        let decoded = try WatchEntrySnapshot.decode(wire)
        try require(decoded == snapshot, "snapshot did not round-trip exactly")
        try require(
            decoded.entry.usages.map(\.entryUsageID) == [
                "usage-saw-seeing", "usage-saw-tool",
            ],
            "ambiguous saw lost a Usage or changed its reviewed order"
        )
        var futureObject = try JSONSerialization.jsonObject(with: wire)
            as? [String: Any] ?? [:]
        futureObject["schemaVersion"] = 2
        let futureWire = try JSONSerialization.data(
            withJSONObject: futureObject,
            options: [.sortedKeys]
        )
        var rejectedFutureVersion = false
        do {
            _ = try WatchEntrySnapshot.decode(futureWire)
        } catch is WatchEntrySnapshotContractError {
            rejectedFutureVersion = true
        }
        try require(
            rejectedFutureVersion,
            "an unsupported Watch snapshot version was accepted"
        )

        var cache = WatchEntrySnapshotCache()
        let firstInstallChanged = try cache.install(snapshot)
        try require(firstInstallChanged, "first snapshot was not installed")
        try require(
            cache.entry(for: " SAW ")?.usages.count == 2,
            "case-insensitive offline lookup did not preserve both Usages"
        )

        let apostropheKey = WatchEntrySnapshotContract.normalizeLookupForm(
            "  MOTHER’S  "
        )
        try require(
            apostropheKey == "mother's",
            "Watch lookup did not use normalization-v1 apostrophe folding"
        )
        let hyphenKey = WatchEntrySnapshotContract.normalizeLookupForm(
            "WELL–BEING"
        )
        try require(
            hyphenKey == "well-being",
            "Watch lookup did not use normalization-v1 hyphen/case folding"
        )

        let apostropheEntry = try makeEntry(
            form: "mother's",
            specs: [UsageSpec(
                id: "usage-mothers",
                label: "belonging to a mother",
                partOfSpeech: "possessive",
                relation: nil,
                explanation: "Belonging to, associated with, or intended for a mother.",
                example: "She borrowed her mother's coat.",
                synonyms: []
            )]
        )
        let apostropheSnapshot = try WatchEntrySnapshot(
            entry: apostropheEntry,
            capturedAtMilliseconds: 1_001
        )
        _ = try cache.install(apostropheSnapshot)
        try require(
            cache.entry(for: "MOTHER’S")?.entryID == apostropheEntry.entryID,
            "typographic apostrophe variant missed a cached offline Entry"
        )

        let hyphenEntry = try makeEntry(
            form: "well-being",
            specs: [UsageSpec(
                id: "usage-well-being",
                label: "health and happiness",
                partOfSpeech: "noun",
                relation: nil,
                explanation: "A person's health, comfort, and general happiness.",
                example: "Regular sleep supports her well-being.",
                synonyms: ["welfare"]
            )]
        )
        let hyphenSnapshot = try WatchEntrySnapshot(
            entry: hyphenEntry,
            capturedAtMilliseconds: 1_002
        )
        _ = try cache.install(hyphenSnapshot)
        try require(
            cache.entry(for: "WELL–BEING")?.entryID == hyphenEntry.entryID,
            "typographic hyphen/case variant missed a cached offline Entry"
        )
        let archive = try cache.encodedArchive()
        let restored = try WatchEntrySnapshotCache.decodeArchive(archive)
        try require(restored == cache, "offline cache did not round-trip")

        let stale = try WatchEntrySnapshot(
            entry: saw,
            capturedAtMilliseconds: 999
        )
        let staleInstallChanged = try cache.install(stale)
        try require(
            !staleInstallChanged,
            "an out-of-order snapshot replaced newer Watch content"
        )

        let partial = ResolvedWordEntry(
            entryID: saw.entryID,
            encounteredSurfaceForm: saw.encounteredSurfaceForm,
            displayForm: saw.displayForm,
            normalizedForm: saw.normalizedForm,
            language: saw.language,
            locale: saw.locale,
            usages: [saw.usages[0]],
            preferredEntryUsageID: saw.preferredEntryUsageID,
            orderingSource: saw.orderingSource,
            expectedUsageCount: 2,
            expectedCoreCount: 2,
            hasMoreUsages: false,
            coverageState: saw.coverageState,
            contentVersion: saw.contentVersion,
            baseContentVersion: saw.baseContentVersion,
            entryRevision: saw.entryRevision,
            coverageRevision: saw.coverageRevision,
            usageSelectionPolicyVersion: saw.usageSelectionPolicyVersion,
            normalizationVersion: saw.normalizationVersion,
            resolverContractVersion: saw.resolverContractVersion
        )
        do {
            _ = try WatchEntrySnapshot(
                entry: partial,
                capturedAtMilliseconds: 1_001
            )
            throw WatchSnapshotHarnessFailure.message(
                "partial ambiguous Entry was accepted"
            )
        } catch is WatchEntrySnapshotContractError {
            // Expected.
        }

        let originalUsage = saw.usages[0]
        let tamperedUsage = UsageLesson(
            entryUsageID: originalUsage.entryUsageID,
            learnerLabel: originalUsage.learnerLabel,
            partOfSpeechLabel: originalUsage.partOfSpeechLabel,
            pronunciations: originalUsage.pronunciations,
            formRelationLabel: originalUsage.formRelationLabel,
            contextVector: originalUsage.contextVector,
            displayOrder: originalUsage.displayOrder,
            commonnessRank: originalUsage.commonnessRank,
            isCore: originalUsage.isCore,
            explanationID: originalUsage.explanationID,
            contentHash: originalUsage.contentHash,
            schemaVersion: originalUsage.schemaVersion,
            lessonContractVersion: originalUsage.lessonContractVersion,
            validatorVersion: originalUsage.validatorVersion,
            reviewPolicyVersion: originalUsage.reviewPolicyVersion,
            contentRevision: originalUsage.contentRevision,
            trustState: originalUsage.trustState,
            content: TeacherLessonContent(
                directExplanation: "Unreviewed replacement text.",
                example: originalUsage.content.example,
                synonyms: originalUsage.content.synonyms,
                memoryCue: originalUsage.content.memoryCue
            )
        )
        let tamperedEntry = ResolvedWordEntry(
            entryID: saw.entryID,
            encounteredSurfaceForm: saw.encounteredSurfaceForm,
            displayForm: saw.displayForm,
            normalizedForm: saw.normalizedForm,
            language: saw.language,
            locale: saw.locale,
            usages: [tamperedUsage, saw.usages[1]],
            preferredEntryUsageID: saw.preferredEntryUsageID,
            orderingSource: saw.orderingSource,
            expectedUsageCount: saw.expectedUsageCount,
            expectedCoreCount: saw.expectedCoreCount,
            hasMoreUsages: saw.hasMoreUsages,
            coverageState: saw.coverageState,
            contentVersion: saw.contentVersion,
            baseContentVersion: saw.baseContentVersion,
            entryRevision: saw.entryRevision,
            coverageRevision: saw.coverageRevision,
            usageSelectionPolicyVersion: saw.usageSelectionPolicyVersion,
            normalizationVersion: saw.normalizationVersion,
            resolverContractVersion: saw.resolverContractVersion
        )
        do {
            _ = try WatchEntrySnapshot(
                entry: tamperedEntry,
                capturedAtMilliseconds: 1_002
            )
            throw WatchSnapshotHarnessFailure.message(
                "lesson text with a stale content hash was accepted"
            )
        } catch is WatchEntrySnapshotContractError {
            // Expected.
        }

        let longLessonText = String(repeating: "x", count: 7_000)
        let oversizedEntry = try makeEntry(
            form: "oversized",
            specs: (0..<4).map { index in
                UsageSpec(
                    id: "usage-oversized-\(index)",
                    label: "oversized test meaning \(index)",
                    partOfSpeech: "noun",
                    relation: nil,
                    explanation: longLessonText,
                    example: longLessonText,
                    synonyms: []
                )
            }
        )
        do {
            _ = try WatchEntrySnapshot(
                entry: oversizedEntry,
                capturedAtMilliseconds: 1_003
            ).encoded()
            throw WatchSnapshotHarnessFailure.message(
                "an oversized complete Entry crossed the Watch wire boundary"
            )
        } catch WatchEntrySnapshotContractError.snapshotTooLarge {
            // Expected: reject the whole Entry rather than dropping Usages.
        }

        var bounded = WatchEntrySnapshotCache()
        for index in 0..<(WatchEntrySnapshotContract.maximumCachedEntries + 1) {
            let form = "watchword\(index)"
            let entry = try makeEntry(
                form: form,
                specs: [UsageSpec(
                    id: "usage-\(form)",
                    label: "test meaning",
                    partOfSpeech: "noun",
                    relation: nil,
                    explanation: "A deterministic test meaning for \(form).",
                    example: "The learner reviewed \(form).",
                    synonyms: []
                )]
            )
            _ = try bounded.install(WatchEntrySnapshot(
                entry: entry,
                capturedAtMilliseconds: Int64(2_000 + index)
            ))
        }
        try require(
            bounded.count == WatchEntrySnapshotContract.maximumCachedEntries,
            "offline cache exceeded its hard Entry bound"
        )
        try require(
            bounded.entry(for: "watchword0") == nil,
            "offline cache did not evict the oldest whole Entry"
        )
        try require(
            bounded.entry(
                for: "watchword\(WatchEntrySnapshotContract.maximumCachedEntries)"
            ) != nil,
            "offline cache evicted the newest Entry"
        )
        let boundedArchive = try bounded.encodedArchive()
        try require(
            boundedArchive.count <= WatchEntrySnapshotContract.maximumArchiveBytes,
            "offline archive exceeded its WatchConnectivity byte bound"
        )

        print("Watch Entry snapshot contract passed")
    }
}
