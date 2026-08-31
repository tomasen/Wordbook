import Foundation
import CryptoKit

/// A short, conversational explanation intended to be read or spoken aloud.
enum VocabularyMemoryTechnique: String, Codable, Equatable, Sendable {
    case parts
    case letters
    case image
    case sound
    case contrast
}

struct VocabularyExplanation: Codable, Equatable, Sendable {
    let partOfSpeech: String
    let meaning: String
    let memoryTechnique: VocabularyMemoryTechnique?
    let memoryAid: [String]
    let example: String
    let synonyms: [String]

    var memoryAidText: String {
        memoryAid.joined(separator: " ")
    }
}

enum ExplanationLoadState: Equatable {
    case idle
    case loading
    case ready(VocabularyExplanation)
    case unavailable(String)
}

// MARK: - Entry-first learner content (schema 2)

/// These values are presentation metadata only. They are never used to infer
/// a lemma, sense, or relationship to another spelling on the device.
struct Pronunciation: Codable, Equatable, Sendable {
    let ipa: String
    let locale: String
}

enum MemoryTechnique: String, Codable, Equatable, Sendable {
    case wordParts
    case spelling
    case image
    case sound
    case contrast
}

struct LessonTextSegment: Codable, Equatable, Sendable {
    let text: String
    let emphasized: Bool
}

struct MemoryCue: Codable, Equatable, Sendable {
    let technique: MemoryTechnique
    let segments: [LessonTextSegment]

    var plainText: String {
        segments.map(\.text).joined()
    }
}

struct TeacherLessonContent: Codable, Equatable, Sendable {
    let directExplanation: String
    let example: String
    let synonyms: [String]
    let memoryCue: MemoryCue?
}

struct ContextRankingVector: Codable, Equatable, Sendable {
    let formatVersion: Int
    let values: [Int8]
}

enum LessonTrustState: String, Codable, Equatable, Sendable {
    case releaseReviewed
    case serverReviewed
}

enum EntryCoverageState: String, Codable, Equatable, Sendable {
    case releaseReviewedComplete
    case serverReviewedComplete
}

enum EntryOrderingSource: String, Codable, Equatable, Sendable {
    case build
    case server
    case context
}

struct UsageLesson: Codable, Equatable, Identifiable, Sendable {
    let entryUsageID: String
    let learnerLabel: String?
    let partOfSpeechLabel: String?
    let pronunciations: [Pronunciation]
    let formRelationLabel: String?
    let contextVector: ContextRankingVector?
    let displayOrder: Int
    let commonnessRank: Int
    let isCore: Bool
    let explanationID: String
    let contentHash: String
    let schemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let reviewPolicyVersion: Int
    let contentRevision: Int
    let trustState: LessonTrustState
    let content: TeacherLessonContent

    var id: String { entryUsageID }
}

struct ResolvedWordEntry: Codable, Equatable, Sendable {
    let entryID: String
    let encounteredSurfaceForm: String
    let displayForm: String
    let normalizedForm: String
    let language: String
    let locale: String
    let usages: [UsageLesson]
    let preferredEntryUsageID: String
    let orderingSource: EntryOrderingSource
    let expectedUsageCount: Int
    let expectedCoreCount: Int
    let hasMoreUsages: Bool
    let coverageState: EntryCoverageState
    let contentVersion: String
    let baseContentVersion: String
    let entryRevision: Int
    let coverageRevision: Int
    let usageSelectionPolicyVersion: Int
    let normalizationVersion: Int
    let resolverContractVersion: Int

    var initiallyVisibleUsages: ArraySlice<UsageLesson> {
        usages.prefix(expectedCoreCount)
    }

    /// The pronunciation attached to the Usage selected for this Entry. A
    /// reviewed Entry normally carries it on the preferred Usage; scanning the
    /// remaining complete Entry is a defensive fallback for older content
    /// packs that omitted pronunciation on that one row.
    var preferredPronunciationPhonemes: String? {
        let preferredUsage = usages.first {
            $0.entryUsageID == preferredEntryUsageID
        }
        let orderedUsages = preferredUsage.map { preferred in
            [preferred] + usages.filter {
                $0.entryUsageID != preferred.entryUsageID
            }
        } ?? usages

        for usage in orderedUsages {
            for pronunciation in usage.pronunciations {
                let phonemes = pronunciation.ipa.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !phonemes.isEmpty { return phonemes }
            }
        }
        return nil
    }
}

enum WordEntryLoadState: Equatable {
    case idle
    case loading
    case ready(ResolvedWordEntry)
    /// Ephemeral last-resort output. It is never written to the reviewed
    /// catalog/overlay, sent to Watch, or made eligible for feedback.
    case localFallback(VocabularyExplanation)
    case correctionRequired([String])
    case pending
    case unavailable(String)
}

// MARK: - Apple Watch Entry snapshots

/// The Watch receives reviewed Entry content from its paired iPhone. It does
/// not carry the SQLite catalog, explanation service, or a language model.
/// This envelope keeps the wire format explicit and rejects partial Entries;
/// an ambiguous spelling such as `saw` therefore arrives with every reviewed
/// Usage or not at all.
struct WatchEntrySnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let capturedAtMilliseconds: Int64
    let entry: ResolvedWordEntry

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case capturedAtMilliseconds
        case entry
    }

    init(
        entry: ResolvedWordEntry,
        capturedAtMilliseconds: Int64
    ) throws {
        self.schemaVersion = WatchEntrySnapshotContract.schemaVersion
        self.capturedAtMilliseconds = capturedAtMilliseconds
        self.entry = entry
        try WatchEntrySnapshotContract.validate(self)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        capturedAtMilliseconds = try values.decode(
            Int64.self,
            forKey: .capturedAtMilliseconds
        )
        entry = try values.decode(ResolvedWordEntry.self, forKey: .entry)
        do {
            try WatchEntrySnapshotContract.validate(self)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .entry,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }

    func encoded() throws -> Data {
        try WatchEntrySnapshotContract.encode(self)
    }

    static func decode(_ data: Data) throws -> WatchEntrySnapshot {
        try WatchEntrySnapshotContract.decode(data)
    }
}

enum WatchEntrySnapshotContractError: LocalizedError, Equatable {
    case invalid(String)
    case snapshotTooLarge(Int)
    case archiveTooLarge(Int)
    case conflictingSnapshotVersion

    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "The Watch explanation snapshot is invalid: \(reason)."
        case .snapshotTooLarge(let bytes):
            return "The Watch explanation snapshot is too large (\(bytes) bytes)."
        case .archiveTooLarge(let bytes):
            return "The Watch explanation cache is too large (\(bytes) bytes)."
        case .conflictingSnapshotVersion:
            return "Two different Watch snapshots use the same capture version."
        }
    }
}

/// A small newest-first offline cache. It is the Watch's only learner-content
/// cache; legacy `VocabularyExplanation` Core Data records are not consulted.
struct WatchEntrySnapshotCache: Equatable, Sendable {
    private(set) var snapshots: [WatchEntrySnapshot] = []

    var count: Int { snapshots.count }

    func snapshot(for surfaceForm: String) -> WatchEntrySnapshot? {
        let key = WatchEntrySnapshotContract.normalizeLookupForm(surfaceForm)
        guard !key.isEmpty else { return nil }
        return snapshots.first { snapshot in
            let entry = snapshot.entry
            return WatchEntrySnapshotContract.normalizeLookupForm(
                entry.normalizedForm
            ) == key
                || WatchEntrySnapshotContract.normalizeLookupForm(
                    entry.encounteredSurfaceForm
                ) == key
                || WatchEntrySnapshotContract.normalizeLookupForm(
                    entry.displayForm
                ) == key
        }
    }

    func entry(for surfaceForm: String) -> ResolvedWordEntry? {
        snapshot(for: surfaceForm)?.entry
    }

    @discardableResult
    mutating func install(_ snapshot: WatchEntrySnapshot) throws -> Bool {
        try WatchEntrySnapshotContract.validate(snapshot)
        // Also enforce the actual encoded wire-size bound before accepting it
        // into persistent storage.
        _ = try snapshot.encoded()

        let key = WatchEntrySnapshotContract.entryKey(snapshot.entry)
        if let current = snapshots.first(where: {
            WatchEntrySnapshotContract.entryKey($0.entry) == key
        }) {
            if current.capturedAtMilliseconds > snapshot.capturedAtMilliseconds {
                return false
            }
            if current.capturedAtMilliseconds == snapshot.capturedAtMilliseconds {
                guard current == snapshot else {
                    throw WatchEntrySnapshotContractError
                        .conflictingSnapshotVersion
                }
                return false
            }
        }

        snapshots.removeAll {
            WatchEntrySnapshotContract.entryKey($0.entry) == key
        }
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > WatchEntrySnapshotContract.maximumCachedEntries {
            snapshots.removeLast(
                snapshots.count
                    - WatchEntrySnapshotContract.maximumCachedEntries
            )
        }

        // A single snapshot has already passed its wire bound. Drop only the
        // oldest whole Entries until the archive fits; never truncate Usages.
        while snapshots.count > 1,
              (try encodedArchiveUnchecked()).count
                > WatchEntrySnapshotContract.maximumArchiveBytes {
            snapshots.removeLast()
        }
        _ = try encodedArchive()
        return true
    }

    func encodedArchive() throws -> Data {
        for snapshot in snapshots {
            try WatchEntrySnapshotContract.validate(snapshot)
            _ = try snapshot.encoded()
        }
        let data = try encodedArchiveUnchecked()
        guard data.count <= WatchEntrySnapshotContract.maximumArchiveBytes else {
            throw WatchEntrySnapshotContractError.archiveTooLarge(data.count)
        }
        return data
    }

    static func decodeArchive(_ data: Data) throws -> WatchEntrySnapshotCache {
        guard data.count <= WatchEntrySnapshotContract.maximumArchiveBytes else {
            throw WatchEntrySnapshotContractError.archiveTooLarge(data.count)
        }
        let archive: WatchEntrySnapshotArchive
        do {
            archive = try JSONDecoder().decode(
                WatchEntrySnapshotArchive.self,
                from: data
            )
        } catch let error as WatchEntrySnapshotContractError {
            throw error
        } catch {
            throw WatchEntrySnapshotContractError.invalid(
                "the cache archive cannot be decoded"
            )
        }
        guard archive.schemaVersion
                == WatchEntrySnapshotContract.archiveSchemaVersion,
              archive.snapshots.count
                <= WatchEntrySnapshotContract.maximumCachedEntries else {
            throw WatchEntrySnapshotContractError.invalid(
                "the cache version or Entry count is unsupported"
            )
        }

        var result = WatchEntrySnapshotCache()
        // Install oldest first to preserve the archive's newest-first order.
        for snapshot in archive.snapshots.reversed() {
            _ = try result.install(snapshot)
        }
        guard result.snapshots.count == archive.snapshots.count else {
            throw WatchEntrySnapshotContractError.invalid(
                "the cache contains duplicate or stale Entry versions"
            )
        }
        return result
    }

    private func encodedArchiveUnchecked() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            WatchEntrySnapshotArchive(
                schemaVersion: WatchEntrySnapshotContract.archiveSchemaVersion,
                snapshots: snapshots
            )
        )
    }
}

private struct WatchEntrySnapshotArchive: Codable {
    let schemaVersion: Int
    let snapshots: [WatchEntrySnapshot]
}

enum WatchEntrySnapshotContract {
    static let schemaVersion = 1
    static let archiveSchemaVersion = 1
    // Keep every property-list transport comfortably below WatchConnectivity's
    // opaque maximum-size boundary. Complete Entries that cannot fit are
    // rejected whole; learner-facing Usages are never silently truncated.
    static let maximumSnapshotBytes = 48 * 1_024
    static let maximumArchiveBytes = 48 * 1_024
    static let maximumCachedEntries = 32

    private static let maximumUsages = 128
    private static let maximumPronunciations = 8
    private static let maximumSynonyms = 32
    private static let maximumMemorySegments = 24
    private static let maximumContextValues = 8 * 1_024
    private static let maximumIdentifierBytes = 256
    private static let maximumLabelBytes = 512
    private static let maximumLessonTextBytes = 8 * 1_024

    static func encode(_ snapshot: WatchEntrySnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumSnapshotBytes else {
            throw WatchEntrySnapshotContractError.snapshotTooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws -> WatchEntrySnapshot {
        guard data.count <= maximumSnapshotBytes else {
            throw WatchEntrySnapshotContractError.snapshotTooLarge(data.count)
        }
        let snapshot: WatchEntrySnapshot
        do {
            snapshot = try JSONDecoder().decode(WatchEntrySnapshot.self, from: data)
        } catch {
            throw WatchEntrySnapshotContractError.invalid(
                "the wire payload cannot be decoded"
            )
        }
        try validate(snapshot)
        return snapshot
    }

    static func validate(_ snapshot: WatchEntrySnapshot) throws {
        guard snapshot.schemaVersion == schemaVersion,
              snapshot.capturedAtMilliseconds > 0 else {
            throw WatchEntrySnapshotContractError.invalid(
                "the snapshot version is unsupported"
            )
        }
        try validate(snapshot.entry)
    }

    static func normalizeLookupForm(_ form: String) -> String {
        // Keep the Watch cache on the exact same pinned identity contract as
        // the phone catalog, overlay, and server. Foundation-only lowercasing
        // does not fold typographic apostrophes or hyphens, so an Entry cached
        // as `mother's` could otherwise miss an offline lookup for `mother’s`.
        WordbookNormalizationV1.normalize(form) ?? ""
    }

    static func entryKey(_ entry: ResolvedWordEntry) -> String {
        "\(entry.language.lowercased())|\(entry.locale)|\(entry.normalizedForm)"
    }

    private static func validate(_ entry: ResolvedWordEntry) throws {
        guard validRequired(entry.entryID, maximum: maximumIdentifierBytes),
              validRequired(entry.encounteredSurfaceForm, maximum: maximumLabelBytes),
              validRequired(entry.displayForm, maximum: maximumLabelBytes),
              validRequired(entry.normalizedForm, maximum: maximumLabelBytes),
              entry.language == "en",
              validCanonicalLocale(entry.locale),
              validRequired(entry.contentVersion, maximum: maximumIdentifierBytes),
              validRequired(entry.baseContentVersion, maximum: maximumIdentifierBytes),
              entry.coverageState != .releaseReviewedComplete
                || entry.baseContentVersion == entry.contentVersion,
              entry.entryRevision > 0,
              entry.coverageRevision > 0,
              entry.coverageRevision <= entry.entryRevision,
              entry.usageSelectionPolicyVersion == 1,
              entry.normalizationVersion == 1,
              entry.resolverContractVersion == 1 else {
            throw WatchEntrySnapshotContractError.invalid(
                "the Entry identity or contract versions are inconsistent"
            )
        }
        guard entry.expectedUsageCount == entry.usages.count,
              (1...maximumUsages).contains(entry.expectedUsageCount),
              (1...4).contains(entry.expectedCoreCount),
              entry.expectedCoreCount <= entry.expectedUsageCount,
              entry.hasMoreUsages
                == (entry.expectedUsageCount > entry.expectedCoreCount),
              entry.usages.first?.entryUsageID
                == entry.preferredEntryUsageID else {
            throw WatchEntrySnapshotContractError.invalid(
                "the Entry does not contain its complete reviewed Usage set"
            )
        }

        var usageIDs = Set<String>()
        var explanationIDs = Set<String>()
        for (index, usage) in entry.usages.enumerated() {
            guard validRequired(
                    usage.entryUsageID,
                    maximum: maximumIdentifierBytes
                  ),
                  usageIDs.insert(usage.entryUsageID).inserted,
                  optionalTextIsValid(usage.learnerLabel),
                  optionalTextIsValid(usage.partOfSpeechLabel),
                  optionalTextIsValid(usage.formRelationLabel),
                  usage.pronunciations.count <= maximumPronunciations,
                  usage.displayOrder == index,
                  usage.commonnessRank >= 0,
                  usage.isCore == (index < entry.expectedCoreCount),
                  validHash(usage.contentHash),
                  usage.explanationID == "exp_\(usage.contentHash)",
                  explanationIDs.insert(usage.explanationID).inserted,
                  usage.schemaVersion == 2,
                  usage.lessonContractVersion == 2,
                  usage.validatorVersion >= 2,
                  usage.reviewPolicyVersion >= 5,
                  usage.contentRevision > 0 else {
                throw WatchEntrySnapshotContractError.invalid(
                    "Usage \(usage.entryUsageID) is incomplete"
                )
            }
            let allowedTrust: Bool
            switch entry.coverageState {
            case .releaseReviewedComplete:
                // A selected, independently reviewed replacement may be
                // materialized over a release-reviewed Entry.
                allowedTrust = usage.trustState == .releaseReviewed
                    || usage.trustState == .serverReviewed
            case .serverReviewedComplete:
                allowedTrust = usage.trustState == .serverReviewed
            }
            guard allowedTrust,
                  usage.pronunciations.allSatisfy({ pronunciation in
                    validRequired(
                        pronunciation.ipa,
                        maximum: maximumLabelBytes
                    ) && validLocale(pronunciation.locale)
                  }),
                  usage.contextVector?.values.count ?? 0
                    <= maximumContextValues,
                  usage.contextVector?.formatVersion ?? 1 > 0 else {
                throw WatchEntrySnapshotContractError.invalid(
                    "Usage \(usage.entryUsageID) has invalid metadata"
                )
            }
            try validateContent(usage, entry: entry)
        }
    }

    private static func validateContent(
        _ usage: UsageLesson,
        entry: ResolvedWordEntry
    ) throws {
        let content = usage.content
        guard validRequired(
                content.directExplanation,
                maximum: maximumLessonTextBytes
              ),
              validRequired(content.example, maximum: maximumLessonTextBytes),
              content.synonyms.count <= maximumSynonyms,
              content.synonyms.allSatisfy({
                validRequired($0, maximum: maximumLabelBytes)
              }) else {
            throw WatchEntrySnapshotContractError.invalid(
                "Usage \(usage.entryUsageID) has incomplete lesson text"
            )
        }
        if let cue = content.memoryCue {
            guard (1...maximumMemorySegments).contains(cue.segments.count),
                  cue.segments.allSatisfy({
                    validRequired($0.text, maximum: maximumLessonTextBytes)
                  }) else {
                throw WatchEntrySnapshotContractError.invalid(
                    "Usage \(usage.entryUsageID) has an invalid memory cue"
                )
            }
        }

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
            "entryID": entry.entryID,
            "entryUsageID": usage.entryUsageID,
            "example": content.example,
            "language": entry.language,
            "lessonContractVersion": usage.lessonContractVersion,
            "locale": entry.locale,
            "memoryCue": memoryCue,
            "normalizedForm": entry.normalizedForm,
            "schemaVersion": usage.schemaVersion,
            "synonyms": content.synonyms,
        ]
        guard JSONSerialization.isValidJSONObject(identity),
              let data = try? JSONSerialization.data(
                withJSONObject: identity,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            throw WatchEntrySnapshotContractError.invalid(
                "Usage \(usage.entryUsageID) cannot be canonicalized"
            )
        }
        let expectedHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard usage.contentHash == expectedHash else {
            throw WatchEntrySnapshotContractError.invalid(
                "Usage \(usage.entryUsageID) has a mismatched content identity"
            )
        }
    }

    private static func validRequired(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && value.utf8.count <= maximum
    }

    private static func optionalTextIsValid(_ value: String?) -> Bool {
        guard let value else { return true }
        return validRequired(value, maximum: maximumLabelBytes)
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func validLocale(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first,
              (2...8).contains(language.utf8.count),
              language.utf8.allSatisfy(isASCIILetter) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.utf8.count)
                && part.utf8.allSatisfy {
                    isASCIILetter($0) || (48...57).contains($0)
                }
        }
    }

    private static func validCanonicalLocale(_ value: String) -> Bool {
        guard validLocale(value) else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first else { return false }
        let canonical = ([language.lowercased()] + parts.dropFirst().map { part in
            let value = String(part)
            if value.utf8.count == 2,
               value.utf8.allSatisfy(isASCIILetter) {
                return value.uppercased()
            }
            return value.lowercased()
        }).joined(separator: "-")
        return value == canonical
    }

    private static func isASCIILetter(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }
}
