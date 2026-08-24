import Foundation

protocol ExplanationLookupStore: Sendable {
    func explanation(for form: String) throws -> OfflineVocabularyExplanation?
}

protocol ExplanationOverlayRepositoryStore: ExplanationLookupStore {
    func explanation(
        for form: String,
        senseID: String
    ) throws -> OfflineVocabularyExplanation?

    func storeValidatedServerExplanation(
        _ record: OfflineVocabularyExplanation,
        selectForForm: Bool,
        makeDefaultForForm: Bool
    ) throws

    @discardableResult
    func enqueueFeedback(_ event: ExplanationFeedbackEvent) throws -> Bool

    func dequeuePendingFeedback(limit: Int) throws -> [ExplanationFeedbackEvent]

    @discardableResult
    func markFeedbackSent(eventID: UUID, sentAt: Date?) throws -> Bool
}

extension OfflineExplanationStore: ExplanationLookupStore {}
extension ExplanationOverlayStore: ExplanationOverlayRepositoryStore {}

enum ExplanationResolutionSource: String, Equatable, Sendable {
    case overlay
    case bundled
    case server
}

struct ExplanationResolution: Equatable, Sendable {
    /// The exact spelling supplied by the caller. Lookup normalization never
    /// replaces the title/pronunciation surface form at this boundary.
    let surfaceForm: String
    let source: ExplanationResolutionSource
    let record: OfflineVocabularyExplanation
}

enum ExplanationFeedbackDeliveryState: String, Equatable, Sendable {
    case sent
    case queued
}

struct ExplanationFeedbackSubmission: Equatable, Sendable {
    let eventID: UUID
    let deliveryState: ExplanationFeedbackDeliveryState
    let replacementStatus: ExplanationReplacementStatus?
    let replacement: OfflineVocabularyExplanation?
    let failureCode: String?
    let deliveryFailure: String?
}

enum ExplanationRepositoryError: LocalizedError {
    case emptySurfaceForm
    case displayedRecordMismatch
    case invalidReplacementRequest
    case feedbackContextUnavailable(form: String, senseID: String)

    var errorDescription: String? {
        switch self {
        case .emptySurfaceForm:
            return "An explanation cannot be resolved for an empty form."
        case .displayedRecordMismatch:
            return "The displayed explanation does not belong to the supplied surface form."
        case .invalidReplacementRequest:
            return "Only an explicit dislike can request one replacement."
        case .feedbackContextUnavailable(let form, let senseID):
            return "Feedback for \(form) could not be sent because sense \(senseID) is unavailable."
        }
    }
}

/// Overlay-first facade for curated explanation lookup and feedback delivery.
///
/// A miss makes one server resolve request. An explicit feedback tap creates
/// one UUID and makes at most one immediate delivery attempt. Pending retries
/// reuse that UUID, so the server cannot start another replacement generation.
final class ExplanationRepository: @unchecked Sendable {
    private let overlay: any ExplanationOverlayRepositoryStore
    private let bundled: any ExplanationLookupStore
    private let server: any ExplanationServerServing
    private let makeEventID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        overlay: any ExplanationOverlayRepositoryStore,
        bundled: any ExplanationLookupStore,
        server: any ExplanationServerServing,
        makeEventID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.overlay = overlay
        self.bundled = bundled
        self.server = server
        self.makeEventID = makeEventID
        self.now = now
    }

    func resolve(form surfaceForm: String) async throws -> ExplanationResolution {
        let normalizedForm = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalizedForm.isEmpty else {
            throw ExplanationRepositoryError.emptySurfaceForm
        }

        if let record = try overlay.explanation(for: surfaceForm) {
            return ExplanationResolution(
                surfaceForm: surfaceForm,
                source: .overlay,
                record: record
            )
        }
        if let record = try bundled.explanation(for: surfaceForm) {
            return ExplanationResolution(
                surfaceForm: surfaceForm,
                source: .bundled,
                record: record
            )
        }

        let serverResolution = try await server.resolve(form: surfaceForm)
        // Make all server-declared form analyses available for later explicit
        // selection, but establish a default only for the requested surface.
        for record in serverResolution.records
            where record.normalizedForm != serverResolution.primary.normalizedForm {
            try overlay.storeValidatedServerExplanation(
                record,
                selectForForm: false,
                makeDefaultForForm: false
            )
        }
        try overlay.storeValidatedServerExplanation(
            serverResolution.primary,
            selectForForm: true,
            makeDefaultForForm: true
        )
        return ExplanationResolution(
            surfaceForm: surfaceForm,
            source: .server,
            record: serverResolution.primary
        )
    }

    /// Queues feedback before attempting delivery. A retryable network or HTTP
    /// failure returns `.queued`; a structurally invalid server receipt throws
    /// and deliberately remains pending for diagnosis instead of being lost.
    func submitFeedback(
        for resolution: ExplanationResolution,
        rating: ExplanationFeedbackRating,
        component: ExplanationFeedbackComponent = .whole,
        requestReplacement: Bool = false
    ) async throws -> ExplanationFeedbackSubmission {
        let record = resolution.record
        guard OfflineExplanationStore.normalizeForm(resolution.surfaceForm)
                == record.normalizedForm else {
            throw ExplanationRepositoryError.displayedRecordMismatch
        }
        guard !requestReplacement || rating == .dislike else {
            throw ExplanationRepositoryError.invalidReplacementRequest
        }

        let event = ExplanationFeedbackEvent(
            eventID: makeEventID(),
            explanationID: record.explanationID,
            normalizedForm: record.normalizedForm,
            senseID: record.senseID,
            rating: rating,
            component: component,
            requestReplacement: requestReplacement,
            createdAt: now()
        )
        _ = try overlay.enqueueFeedback(event)
        return try await deliver(
            event,
            surfaceForm: resolution.surfaceForm,
            lexicalContext: record
        )
    }

    /// Makes one delivery attempt for each event returned by one bounded outbox
    /// dequeue. It never recursively drains or resubmits a replacement request.
    func sendPendingFeedback(limit: Int = 25) async throws -> [ExplanationFeedbackSubmission] {
        let events = try overlay.dequeuePendingFeedback(limit: limit)
        var submissions: [ExplanationFeedbackSubmission] = []
        submissions.reserveCapacity(events.count)

        for event in events {
            let context = try feedbackContext(for: event)
            submissions.append(try await deliver(
                event,
                surfaceForm: event.normalizedForm,
                lexicalContext: context
            ))
        }
        return submissions
    }

    private func feedbackContext(
        for event: ExplanationFeedbackEvent
    ) throws -> OfflineVocabularyExplanation {
        if let overlayRecord = try overlay.explanation(
            for: event.normalizedForm,
            senseID: event.senseID
        ) {
            return overlayRecord
        }
        if let bundledRecord = try bundled.explanation(for: event.normalizedForm),
           bundledRecord.senseID == event.senseID {
            return bundledRecord
        }
        throw ExplanationRepositoryError.feedbackContextUnavailable(
            form: event.normalizedForm,
            senseID: event.senseID
        )
    }

    private func deliver(
        _ event: ExplanationFeedbackEvent,
        surfaceForm: String,
        lexicalContext: OfflineVocabularyExplanation
    ) async throws -> ExplanationFeedbackSubmission {
        let receipt: ValidatedServerFeedbackReceipt
        do {
            receipt = try await server.sendFeedback(
                event,
                surfaceForm: surfaceForm,
                lexicalContext: lexicalContext
            )
        } catch let error as ExplanationServerClientError
            where error.isRetryableDeliveryFailure {
            return ExplanationFeedbackSubmission(
                eventID: event.eventID,
                deliveryState: .queued,
                replacementStatus: nil,
                replacement: nil,
                failureCode: nil,
                deliveryFailure: error.localizedDescription
            )
        }

        if let replacement = receipt.replacement {
            try overlay.storeValidatedServerExplanation(
                replacement,
                selectForForm: true,
                makeDefaultForForm: true
            )
        }
        _ = try overlay.markFeedbackSent(eventID: event.eventID, sentAt: now())
        return ExplanationFeedbackSubmission(
            eventID: event.eventID,
            deliveryState: .sent,
            replacementStatus: receipt.replacementStatus,
            replacement: receipt.replacement,
            failureCode: receipt.failureCode,
            deliveryFailure: nil
        )
    }
}

// MARK: - Entry-first repository

protocol EntryCatalogLookupStore: Sendable {
    func entry(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> ResolvedWordEntry?
}

protocol EntryOverlayRepositoryStore: EntryCatalogLookupStore {
    @discardableResult
    func installCompleteEntry(
        _ entry: ResolvedWordEntry,
        activate: Bool
    ) throws -> Bool
    func applyingSelectedReplacements(
        to entry: ResolvedWordEntry
    ) throws -> ResolvedWordEntry
    func replacementExclusionHistory(
        entryID: String,
        entryUsageID: String,
        locale: String,
        baseEntryRevision: Int,
        baseContentVersion: String,
        currentExplanationID: String
    ) throws -> [String]
    func installReplacement(
        _ replacement: EntryLessonReplacement,
        against baseEntry: ResolvedWordEntry
    ) throws
    func storePending(
        _ pending: EntryPendingResolution,
        normalizedForm: String,
        language: String,
        locale: String,
        eventID: UUID?
    ) throws
    func pending(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryPendingResolution?
    func pending(eventID: UUID) throws -> EntryPendingResolution?
    func markJobFinished(_ jobID: String) throws
    func storeCorrection(
        _ correction: EntryCorrectionResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws
    func storeNegative(
        _ negative: EntryNegativeResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws
    func cachedMiss(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryCachedMiss?
    @discardableResult
    func enqueueFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) throws -> Bool
    func dequeuePendingFeedback(limit: Int) throws -> [EntryFeedbackOutboxItem]
    func pendingFeedback(eventID: UUID) throws -> EntryFeedbackOutboxItem?
    func quarantineFeedback(eventID: UUID, failureReason: String) throws
    func markFeedbackSent(eventID: UUID) throws
    func markReplacementComplete(eventID: UUID) throws
}

extension EntryCatalogStore: EntryCatalogLookupStore {}
extension EntryOverlayStore: EntryOverlayRepositoryStore {}

enum EntryResolutionSource: String, Equatable, Sendable {
    case overlay
    case catalog
    case server
}

struct ResolvedEntryResolution: Equatable, Sendable {
    let surfaceForm: String
    let source: EntryResolutionSource
    let entry: ResolvedWordEntry
}

enum EntryResolutionOutcome: Equatable, Sendable {
    case resolved(ResolvedEntryResolution)
    case correctionRequired(EntryCorrectionResolution)
    case pending(EntryPendingResolution)
    case negative(EntryNegativeResolution)
    case unavailable(EntryUnavailableResolution)
}

/// A visible card may make its initial request and follow one durable job
/// checkpoint. Anything still pending remains in the overlay for a later app
/// session instead of keeping the learner in a foreground polling loop.
struct EntryForegroundStatusCheckBudget: Equatable, Sendable {
    private(set) var remainingChecks = 1

    mutating func claimStatusCheck() -> Bool {
        guard remainingChecks > 0 else { return false }
        remainingChecks -= 1
        return true
    }
}

enum EntryFeedbackDeliveryState: String, Equatable, Sendable {
    case sent
    case queued
}

enum EntryReplacementDeliveryState: Equatable, Sendable {
    case notRequested
    case complete(EntryLessonReplacement)
    case pending(EntryPendingResolution)
    case failed(String)
    case queued
}

struct EntryFeedbackSubmission: Equatable, Sendable {
    let eventID: UUID
    let deliveryState: EntryFeedbackDeliveryState
    let replacementState: EntryReplacementDeliveryState
    let deliveryFailure: String?
}

enum EntryRepositoryError: LocalizedError {
    case emptySurfaceForm
    case unsupportedLanguage(String)
    case invalidLocale(String)
    case displayedEntryMismatch
    case usageUnavailable(String)
    case invalidReplacementRequest
    case feedbackContextUnavailable(UUID)

    var errorDescription: String? {
        switch self {
        case .emptySurfaceForm:
            return "An Entry cannot be resolved for an empty spelling."
        case .unsupportedLanguage(let language):
            return "The Entry service does not support language \(language)."
        case .invalidLocale(let locale):
            return "The locale tag \(locale) is invalid."
        case .displayedEntryMismatch:
            return "The displayed Entry does not belong to the supplied spelling."
        case .usageUnavailable(let entryUsageID):
            return "Usage \(entryUsageID) is not part of the displayed Entry."
        case .invalidReplacementRequest:
            return "Only not-helpful feedback may request one replacement."
        case .feedbackContextUnavailable(let eventID):
            return "The Entry for queued feedback \(eventID.uuidString) is unavailable."
        }
    }
}

/// Local-first facade for one exact spelling. Catalog and overlay are queried
/// independently, then one complete snapshot wins; their Usage rows are never
/// merged. Only a true local miss reaches v3.
final class EntryExplanationRepository: @unchecked Sendable {
    private let overlay: any EntryOverlayRepositoryStore
    private let catalog: any EntryCatalogLookupStore
    private let server: any EntryServerServing
    private let makeRequestID: @Sendable () -> UUID
    private let makeEventID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let clientContentVersion: @Sendable () -> String

    init(
        overlay: any EntryOverlayRepositoryStore,
        catalog: any EntryCatalogLookupStore,
        server: any EntryServerServing,
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() },
        makeEventID: @escaping @Sendable () -> UUID = { UUID() },
        now: @escaping @Sendable () -> Date = { Date() },
        clientContentVersion: @escaping @Sendable () -> String = { "unknown" }
    ) {
        self.overlay = overlay
        self.catalog = catalog
        self.server = server
        self.makeRequestID = makeRequestID
        self.makeEventID = makeEventID
        self.now = now
        self.clientContentVersion = clientContentVersion
    }

    /// Returns only a complete overlay/catalog Entry. This is used by the
    /// paired-Watch bridge so a Watch request can never start a cold-miss API
    /// workflow as a side effect. The learner can open a true miss on iPhone;
    /// once reviewed there, the normal publication path sends the snapshot.
    func resolveLocally(
        form surfaceForm: String,
        language: String = "en",
        locale: String = "en",
        context: EntryResolveContext? = nil
    ) throws -> ResolvedEntryResolution? {
        let normalized = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalized.isEmpty else { throw EntryRepositoryError.emptySurfaceForm }
        let language = language.lowercased()
        guard language == "en" else {
            throw EntryRepositoryError.unsupportedLanguage(language)
        }
        guard EntryContractValidator.hasValidLocaleSyntax(locale) else {
            throw EntryRepositoryError.invalidLocale(locale)
        }
        return try localResolution(
            surfaceForm: surfaceForm,
            language: language,
            locale: Self.normalizedLocale(locale),
            context: context
        )
    }

    func resolve(
        form surfaceForm: String,
        language: String = "en",
        locale: String = "en",
        context: EntryResolveContext? = nil,
        confirmedRareSpelling: Bool = false,
        allowPendingStatusCheck: Bool = true
    ) async throws -> EntryResolutionOutcome {
        let normalized = OfflineExplanationStore.normalizeForm(surfaceForm)
        guard !normalized.isEmpty else { throw EntryRepositoryError.emptySurfaceForm }
        let language = language.lowercased()
        guard language == "en" else {
            throw EntryRepositoryError.unsupportedLanguage(language)
        }
        guard EntryContractValidator.hasValidLocaleSyntax(locale) else {
            throw EntryRepositoryError.invalidLocale(locale)
        }
        let locale = Self.normalizedLocale(locale)

        if let local = try localResolution(
            surfaceForm: surfaceForm,
            language: language,
            locale: locale,
            context: context
        ) {
            return .resolved(local)
        }

        if let cached = try? overlay.cachedMiss(
            for: surfaceForm,
            language: language,
            locale: locale
        ) {
            switch cached {
            case .correctionRequired(let correction):
                // A learner may explicitly confirm this exact spelling once.
                // Keep the cached correction intact, but let that confirmed
                // request reach the server. Finite negatives remain binding.
                if !confirmedRareSpelling {
                    return .correctionRequired(correction)
                }
            case .negative(let negative):
                return .negative(negative)
            }
        }

        if let pending = try? overlay.pending(
            for: surfaceForm,
            language: language,
            locale: locale
        ) {
            if !allowPendingStatusCheck || pending.nextCheckAt > now() {
                return .pending(pending)
            }
            do {
                let result = try await server.jobStatus(
                    jobID: pending.jobID,
                    expectedCanonicalKeyHash: pending.canonicalKeyHash
                )
                if case .pending(let refreshed) = result,
                   refreshed.canonicalKeyHash != pending.canonicalKeyHash {
                    throw ExplanationServerClientError.invalidResponse(
                        "job response changed its canonical work identity"
                    )
                }
                return try handle(
                    result,
                    surfaceForm: surfaceForm,
                    normalizedForm: normalized,
                    language: language,
                    locale: locale,
                    context: context,
                    completedJobID: pending.jobID
                )
            } catch let error as ExplanationServerClientError
                where error.isRetryableDeliveryFailure {
                return .pending(pending)
            }
        }

        let request = EntryResolveRequest(
            requestID: makeRequestID(),
            encounteredSurfaceForm: surfaceForm,
            language: language,
            locale: locale,
            context: context,
            clientContentVersion: clientContentVersion(),
            normalizationVersion: EntryContractValidator.normalizationVersion,
            resolverContractVersion: EntryContractValidator.resolverContractVersion,
            lessonSchemaVersion: EntryContractValidator.lessonSchemaVersion,
            lessonContractVersion: EntryContractValidator.lessonContractVersion,
            validatorVersion: EntryContractValidator.validatorVersion,
            minimumReviewPolicyVersion: EntryContractValidator.minimumReviewPolicyVersion,
            minimumUsageSelectionPolicyVersion:
                EntryContractValidator.usageSelectionPolicyVersion,
            confirmedRareSpelling: confirmedRareSpelling
        )
        do {
            return try await handle(
                server.resolve(request),
                surfaceForm: surfaceForm,
                normalizedForm: normalized,
                language: language,
                locale: locale,
                context: context,
                completedJobID: nil
            )
        } catch let error as ExplanationServerClientError
            where error.isRetryableDeliveryFailure {
            return .unavailable(EntryUnavailableResolution(
                reason: error.localizedDescription,
                retryAfter: nil
            ))
        }
    }

    private func localResolution(
        surfaceForm: String,
        language: String,
        locale: String,
        context: EntryResolveContext?
    ) throws -> ResolvedEntryResolution? {
        // Both reads always happen. Overlay corruption must not suppress a
        // healthy catalog hit, and an overlay-only rare Entry needs no catalog
        // identity to exist.
        let overlayCandidate = try? overlay.entry(
            for: surfaceForm,
            language: language,
            locale: locale
        )
        // A catalog read/validation failure is not a local miss. Propagate it
        // instead of sending the same spelling to the network, while still
        // allowing a broken overlay to degrade to the healthy signed catalog.
        let catalogCandidate = try catalog.entry(
            for: surfaceForm,
            language: language,
            locale: locale
        )
        guard let selected = Self.selectWholeSnapshot(
            catalog: catalogCandidate,
            overlay: overlayCandidate
        ) else { return nil }
        let replaced = (try? overlay.applyingSelectedReplacements(to: selected.entry))
            ?? selected.entry
        return ResolvedEntryResolution(
            surfaceForm: surfaceForm,
            source: selected.source,
            entry: Self.contextRank(replaced, context: context)
        )
    }

    func submitFeedback(
        for resolution: ResolvedEntryResolution,
        entryUsageID: String,
        rating: EntryFeedbackRating,
        component: EntryFeedbackComponent = .wholeLesson,
        requestReplacement: Bool = false
    ) async throws -> EntryFeedbackSubmission {
        let entry = resolution.entry
        guard OfflineExplanationStore.normalizeForm(resolution.surfaceForm)
                == entry.normalizedForm else {
            throw EntryRepositoryError.displayedEntryMismatch
        }
        guard let usage = entry.usages.first(where: {
            $0.entryUsageID == entryUsageID
        }) else { throw EntryRepositoryError.usageUnavailable(entryUsageID) }
        guard !requestReplacement || rating == .notHelpful else {
            throw EntryRepositoryError.invalidReplacementRequest
        }
        let excludedExplanationIDs = requestReplacement
            ? try overlay.replacementExclusionHistory(
                entryID: entry.entryID,
                entryUsageID: usage.entryUsageID,
                locale: entry.locale,
                baseEntryRevision: entry.entryRevision,
                baseContentVersion: entry.contentVersion,
                currentExplanationID: usage.explanationID
            )
            : []
        let event = EntryFeedbackEvent(
            eventID: makeEventID(),
            entryID: entry.entryID,
            entryUsageID: usage.entryUsageID,
            explanationID: usage.explanationID,
            normalizedForm: entry.normalizedForm,
            language: entry.language,
            locale: entry.locale,
            rating: rating,
            component: component,
            requestReplacement: requestReplacement,
            contentVersion: entry.contentVersion,
            appVersion: Self.applicationVersion,
            baseContentVersion: entry.contentVersion,
            baseEntryRevision: entry.entryRevision,
            schemaVersion: usage.schemaVersion,
            lessonContractVersion: usage.lessonContractVersion,
            validatorVersion: usage.validatorVersion,
            reviewPolicyVersion: usage.reviewPolicyVersion,
            excludedExplanationIDs: excludedExplanationIDs,
            createdAt: now()
        )
        _ = try overlay.enqueueFeedback(event, baseEntry: entry)
        return try await deliver(event, baseEntry: entry)
    }

    func sendPendingFeedback(limit: Int = 25) async throws -> [EntryFeedbackSubmission] {
        let items = try overlay.dequeuePendingFeedback(limit: limit)
        var submissions: [EntryFeedbackSubmission] = []
        submissions.reserveCapacity(items.count)
        for item in items {
            do {
                let baseEntry = try feedbackEntry(
                    for: item.event,
                    persistedBase: item.baseEntry
                )
                submissions.append(try await deliver(item.event, baseEntry: baseEntry))
            } catch let error as ExplanationServerClientError
                where !error.isRetryableDeliveryFailure {
                try overlay.quarantineFeedback(
                    eventID: item.event.eventID,
                    failureReason: "Nonretryable server contract failure: \(error.localizedDescription)"
                )
            } catch let error as EntryRepositoryError {
                try overlay.quarantineFeedback(
                    eventID: item.event.eventID,
                    failureReason: "Invalid persisted feedback context: \(error.localizedDescription)"
                )
            }
        }
        return submissions
    }

    /// Resumes exactly one durable feedback/replacement workflow. This lets a
    /// visible card follow the job it started without recursively draining the
    /// whole outbox or accidentally creating a second feedback event.
    func resumeFeedback(eventID: UUID) async throws -> EntryFeedbackSubmission? {
        guard let item = try overlay.pendingFeedback(eventID: eventID) else {
            return nil
        }
        let baseEntry = try feedbackEntry(
            for: item.event,
            persistedBase: item.baseEntry
        )
        return try await deliver(item.event, baseEntry: baseEntry)
    }

    private func handle(
        _ result: EntryServerResult,
        surfaceForm: String,
        normalizedForm: String,
        language: String,
        locale: String,
        context: EntryResolveContext?,
        completedJobID: String?
    ) throws -> EntryResolutionOutcome {
        switch result {
        case .resolved(let entry):
            guard entry.normalizedForm == normalizedForm,
                  entry.language == language,
                  Self.normalizedLocale(entry.locale) == Self.normalizedLocale(locale) else {
                throw ExplanationServerClientError.invalidResponse(
                    "completed job returned an Entry for another lookup key"
                )
            }
            // A resolve request is made only after both local layers miss, so
            // this is an overlay-only complete snapshot. Future refresh paths
            // use the same installer but decide catalog compatibility first.
            let selected: ResolvedWordEntry
            do {
                _ = try overlay.installCompleteEntry(entry, activate: true)
                selected = try overlay.entry(
                    for: surfaceForm,
                    language: language,
                    locale: locale
                ) ?? entry
            } catch {
                // The server DTO already passed the strict public contract.
                // A writable-cache failure must not make a rare valid word
                // disappear; retain a diagnosable device log and use the
                // validated transient value for this resolution.
                NSLog("Wordbook Entry overlay cache degraded: %@", error.localizedDescription)
                selected = entry
            }
            if let completedJobID { try? overlay.markJobFinished(completedJobID) }
            return .resolved(ResolvedEntryResolution(
                surfaceForm: surfaceForm,
                source: .server,
                entry: Self.contextRank(selected, context: context)
            ))
        case .correctionRequired(let correction):
            try overlay.storeCorrection(
                correction,
                normalizedForm: normalizedForm,
                language: language,
                locale: locale
            )
            if let completedJobID { try? overlay.markJobFinished(completedJobID) }
            return .correctionRequired(correction)
        case .pending(let pending):
            try overlay.storePending(
                pending,
                normalizedForm: normalizedForm,
                language: language,
                locale: locale,
                eventID: nil
            )
            return .pending(pending)
        case .negative(let negative):
            try overlay.storeNegative(
                negative,
                normalizedForm: normalizedForm,
                language: language,
                locale: locale
            )
            if let completedJobID { try? overlay.markJobFinished(completedJobID) }
            return .negative(negative)
        case .unavailable(let unavailable):
            if let completedJobID { try? overlay.markJobFinished(completedJobID) }
            return .unavailable(unavailable)
        }
    }

    private func feedbackEntry(
        for event: EntryFeedbackEvent,
        persistedBase: ResolvedWordEntry?
    ) throws -> ResolvedWordEntry {
        if let persistedBase {
            guard Self.feedbackEvent(event, matches: persistedBase) else {
                throw EntryRepositoryError.feedbackContextUnavailable(event.eventID)
            }
            return persistedBase
        }

        // Compatibility path for schema-v1 rows written before the outbox
        // retained its exact displayed Entry. It can recover the raw or current
        // selected lesson while that revision is still locally available.
        let overlayEntry = try? overlay.entry(
            for: event.normalizedForm,
            language: event.language,
            locale: event.locale
        )
        let catalogEntry = try catalog.entry(
            for: event.normalizedForm,
            language: event.language,
            locale: event.locale
        )
        guard let selected = Self.selectWholeSnapshot(
            catalog: catalogEntry,
            overlay: overlayEntry
        ) else { throw EntryRepositoryError.feedbackContextUnavailable(event.eventID) }
        let rawEntry = selected.entry
        let replacedEntry = (try? overlay.applyingSelectedReplacements(to: rawEntry))
            ?? rawEntry
        let entry = rawEntry.usages.contains(where: {
            $0.entryUsageID == event.entryUsageID
                && $0.explanationID == event.explanationID
        }) ? rawEntry : replacedEntry
        guard Self.feedbackEvent(event, matches: entry) else {
            throw EntryRepositoryError.feedbackContextUnavailable(event.eventID)
        }
        return entry
    }

    private static func feedbackEvent(
        _ event: EntryFeedbackEvent,
        matches entry: ResolvedWordEntry
    ) -> Bool {
        guard event.entryID == entry.entryID,
              event.normalizedForm == entry.normalizedForm,
              event.language == entry.language,
              event.locale == entry.locale,
              event.contentVersion == entry.contentVersion,
              event.baseContentVersion == entry.contentVersion,
              event.baseEntryRevision == entry.entryRevision,
              let usage = entry.usages.first(where: {
                  $0.entryUsageID == event.entryUsageID
                    && $0.explanationID == event.explanationID
              }) else { return false }
        return usage.schemaVersion == event.schemaVersion
            && usage.lessonContractVersion == event.lessonContractVersion
            && usage.validatorVersion == event.validatorVersion
            && usage.reviewPolicyVersion == event.reviewPolicyVersion
    }

    private func deliver(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryFeedbackSubmission {
        var feedbackReplacementResult: EntryServerReplacementResult?
        if !event.feedbackDelivered {
            do {
                let receipt = try await server.sendFeedback(
                    event,
                    baseEntry: baseEntry
                )
                guard receipt.accepted, receipt.eventID == event.eventID else {
                    throw ExplanationServerClientError.invalidResponse(
                        "feedback receipt does not acknowledge the queued event"
                    )
                }
                try overlay.markFeedbackSent(eventID: event.eventID)
                feedbackReplacementResult = receipt.replacementResult
            } catch let error as ExplanationServerClientError
                where error.isRetryableDeliveryFailure {
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .queued,
                    replacementState: event.requestReplacement ? .queued : .notRequested,
                    deliveryFailure: error.localizedDescription
                )
            }
        }

        guard event.requestReplacement, !event.replacementCompleted else {
            return EntryFeedbackSubmission(
                eventID: event.eventID,
                deliveryState: .sent,
                replacementState: .notRequested,
                deliveryFailure: nil
            )
        }

        do {
            let pendingJob = event.feedbackDelivered
                ? try overlay.pending(eventID: event.eventID)
                : nil
            if let pendingJob, pendingJob.nextCheckAt > now() {
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .sent,
                    replacementState: .pending(pendingJob),
                    deliveryFailure: nil
                )
            }
            let result: EntryServerReplacementResult
            if let feedbackReplacementResult {
                result = feedbackReplacementResult
            } else if let pendingJob {
                result = try await server.replacementJobStatus(
                    jobID: pendingJob.jobID,
                    expectedCanonicalKeyHash: pendingJob.canonicalKeyHash,
                    baseEntry: baseEntry
                )
            } else {
                result = try await server.requestReplacement(
                    for: event,
                    baseEntry: baseEntry
                )
            }
            switch result {
            case .complete(let replacement):
                try overlay.installReplacement(replacement, against: baseEntry)
                try overlay.markReplacementComplete(eventID: event.eventID)
                if let pendingJob { try? overlay.markJobFinished(pendingJob.jobID) }
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .sent,
                    replacementState: .complete(replacement),
                    deliveryFailure: nil
                )
            case .pending(let pending):
                try overlay.storePending(
                    pending,
                    normalizedForm: event.normalizedForm,
                    language: event.language,
                    locale: event.locale,
                    eventID: event.eventID
                )
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .sent,
                    replacementState: .pending(pending),
                    deliveryFailure: nil
                )
            case .failed(let code):
                try overlay.markReplacementComplete(eventID: event.eventID)
                if let pendingJob { try? overlay.markJobFinished(pendingJob.jobID) }
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .sent,
                    replacementState: .failed(code),
                    deliveryFailure: nil
                )
            case .unavailable(let unavailable):
                return EntryFeedbackSubmission(
                    eventID: event.eventID,
                    deliveryState: .sent,
                    replacementState: .queued,
                    deliveryFailure: unavailable.reason
                )
            }
        } catch let error as ExplanationServerClientError
            where error.isRetryableDeliveryFailure {
            return EntryFeedbackSubmission(
                eventID: event.eventID,
                deliveryState: .sent,
                replacementState: .queued,
                deliveryFailure: error.localizedDescription
            )
        }
    }

    private static func selectWholeSnapshot(
        catalog: ResolvedWordEntry?,
        overlay: ResolvedWordEntry?
    ) -> (source: EntryResolutionSource, entry: ResolvedWordEntry)? {
        switch (catalog, overlay) {
        case (nil, nil):
            return nil
        case (let catalog?, nil):
            return (.catalog, catalog)
        case (nil, let overlay?):
            return (.overlay, overlay)
        case (let catalog?, let overlay?):
            let compatible = overlay.entryID == catalog.entryID
                && overlay.language == catalog.language
                && overlay.normalizedForm == catalog.normalizedForm
                && overlay.locale == catalog.locale
                && overlay.normalizationVersion == catalog.normalizationVersion
                && overlay.resolverContractVersion == catalog.resolverContractVersion
                && overlay.usageSelectionPolicyVersion
                    == catalog.usageSelectionPolicyVersion
                && overlay.baseContentVersion == catalog.contentVersion
            let newer = EntryContractValidator.isValidCoverageAdvance(
                overlay,
                over: catalog
            )
            return compatible && newer ? (.overlay, overlay) : (.catalog, catalog)
        }
    }

    /// Public-only deterministic fallback when no model-produced numeric
    /// context vector is available. It only reorders existing reviewed Usages.
    /// Core/non-core membership remains intact, and ties keep reviewed order.
    static func contextRank(
        _ entry: ResolvedWordEntry,
        context: EntryResolveContext?
    ) -> ResolvedWordEntry {
        guard let context,
              contextTargetMatches(
                context,
                normalizedForm: entry.normalizedForm
              ),
              let targetIndex = contextTargetTokenIndex(context),
              entry.usages.count > 1 else { return entry }
        let tokens = tokenize(context.text)
        guard targetIndex < tokens.count else { return entry }
        let preceding = targetIndex > 0 ? tokens[targetIndex - 1] : nil
        let contextWords = Set(tokens.enumerated().compactMap {
            $0.offset == targetIndex ? nil : $0.element
        })
        let determiners: Set<String> = [
            "a", "an", "the", "this", "that", "these", "those", "my", "your",
            "his", "her", "its", "our", "their", "some", "each", "every",
        ]
        let pronouns: Set<String> = [
            "i", "you", "he", "she", "it", "we", "they", "who", "someone",
        ]
        let tenseMarkers: Set<String> = [
            "yesterday", "ago", "last", "did", "had", "was", "were", "will",
            "would", "could", "should", "already", "earlier", "before",
        ]

        func score(_ usage: UsageLesson) -> Int {
            let label = usage.partOfSpeechLabel?.lowercased() ?? ""
            var value = 0
            if label.contains("noun"), preceding.map(determiners.contains) == true {
                value += 120
            }
            if label.contains("verb"), preceding.map(pronouns.contains) == true {
                value += 100
            }
            if label.contains("verb"), !contextWords.isDisjoint(with: tenseMarkers) {
                value += 45
            }
            let searchable = [
                usage.learnerLabel ?? "",
                usage.content.directExplanation,
                usage.content.example,
                usage.content.synonyms.joined(separator: " "),
            ].joined(separator: " ")
            let lessonWords = Set(tokenize(searchable))
            value += contextWords.intersection(lessonWords).count * 8
            return value
        }

        func reordered(_ usages: [UsageLesson]) -> [UsageLesson] {
            usages.enumerated().sorted { left, right in
                let leftScore = score(left.element)
                let rightScore = score(right.element)
                if leftScore != rightScore { return leftScore > rightScore }
                if left.element.commonnessRank != right.element.commonnessRank {
                    return left.element.commonnessRank < right.element.commonnessRank
                }
                return left.offset < right.offset
            }.map(\.element)
        }

        let core = reordered(entry.usages.filter(\.isCore))
        let additional = reordered(entry.usages.filter({ !$0.isCore }))
        let ordered = core + additional
        guard ordered.map(\.entryUsageID) != entry.usages.map(\.entryUsageID) else {
            return entry
        }
        let usages = ordered.enumerated().map { index, usage in
            UsageLesson(
                entryUsageID: usage.entryUsageID,
                learnerLabel: usage.learnerLabel,
                partOfSpeechLabel: usage.partOfSpeechLabel,
                pronunciations: usage.pronunciations,
                formRelationLabel: usage.formRelationLabel,
                contextVector: usage.contextVector,
                displayOrder: index,
                commonnessRank: usage.commonnessRank,
                isCore: index < entry.expectedCoreCount,
                explanationID: usage.explanationID,
                contentHash: usage.contentHash,
                schemaVersion: usage.schemaVersion,
                lessonContractVersion: usage.lessonContractVersion,
                validatorVersion: usage.validatorVersion,
                reviewPolicyVersion: usage.reviewPolicyVersion,
                contentRevision: usage.contentRevision,
                trustState: usage.trustState,
                content: usage.content
            )
        }
        let ranked = ResolvedWordEntry(
            entryID: entry.entryID,
            encounteredSurfaceForm: entry.encounteredSurfaceForm,
            displayForm: entry.displayForm,
            normalizedForm: entry.normalizedForm,
            language: entry.language,
            locale: entry.locale,
            usages: usages,
            preferredEntryUsageID: usages[0].entryUsageID,
            orderingSource: .context,
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
		if (try? EntryContractValidator.validateMaterializedView(
			ranked,
            expectedSurfaceForm: ranked.encounteredSurfaceForm
        )) != nil {
            return ranked
        }
        return entry
    }

    private static func contextTargetTokenIndex(
        _ context: EntryResolveContext
    ) -> Int? {
        guard context.offsetEncoding == "utf8", context.targetStart >= 0,
              context.targetLength > 0 else { return nil }
        let bytes = Array(context.text.utf8)
        let end = context.targetStart + context.targetLength
        guard end <= bytes.count else { return nil }
        let prefix = String(decoding: bytes[..<context.targetStart], as: UTF8.self)
        let target = String(decoding: bytes[context.targetStart..<end], as: UTF8.self)
        let prefixTokens = tokenize(prefix)
        guard !tokenize(target).isEmpty else { return nil }
        return prefixTokens.count
    }

    private static func contextTargetMatches(
        _ context: EntryResolveContext,
        normalizedForm: String
    ) -> Bool {
        guard context.offsetEncoding == "utf8", context.targetStart >= 0,
              context.targetLength > 0 else { return false }
        let bytes = Array(context.text.utf8)
        let end = context.targetStart + context.targetLength
        guard end <= bytes.count,
              let target = String(
                data: Data(bytes[context.targetStart..<end]),
                encoding: .utf8
              ) else { return false }
        return OfflineExplanationStore.normalizeForm(target) == normalizedForm
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber && $0 != "'"
        }).map(String.init)
    }

    private static func normalizedLocale(_ value: String) -> String {
        EntryContractValidator.canonicalLocale(value)
    }

    private static var applicationVersion: String {
        let values = [
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        ]
        return values.compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first(where: { !$0.isEmpty }) ?? "unknown"
    }
}
