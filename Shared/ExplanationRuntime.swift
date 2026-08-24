import Foundation

private actor ExplanationResolutionCoordinator {
    private struct InFlightRequest {
        let token: UUID
        let task: Task<ExplanationResolution, Error>
    }

    private var requests: [String: InFlightRequest] = [:]

    func resolve(
        form: String,
        repository: ExplanationRepository
    ) async throws -> ExplanationResolution {
        let key = OfflineExplanationStore.normalizeForm(form)
        if let request = requests[key] {
            return try await request.task.value
        }

        let token = UUID()
        let task = Task {
            try await repository.resolve(form: form)
        }
        requests[key] = InFlightRequest(token: token, task: task)

        do {
            let resolution = try await task.value
            finish(key: key, token: token)
            return resolution
        } catch {
            finish(key: key, token: token)
            throw error
        }
    }

    private func finish(key: String, token: UUID) {
        guard requests[key]?.token == token else { return }
        requests.removeValue(forKey: key)
    }
}

/// Frozen schema-v1 compatibility runtime retained for older call sites. The
/// active explanation path uses `EntryExplanationRuntime` below and never
/// falls back to the phone language model for routine definitions.
final class ExplanationRuntime: @unchecked Sendable {
    static let shared = ExplanationRuntime()

    let repository: ExplanationRepository?
    let initializationError: String?

    private let resolutionCoordinator = ExplanationResolutionCoordinator()
    private let deliveryLock = NSLock()
    private var attemptedPendingDelivery = false

    private init(bundle: Bundle = .main) {
        guard let packURL = bundle.url(
            forResource: "wordbook-content",
            withExtension: "sqlite"
        ) else {
            repository = nil
            initializationError = nil
            return
        }

        do {
            let bundled = try OfflineExplanationStore(databaseURL: packURL)
            let overlay = try ExplanationOverlayStore()
            let server = try ExplanationServerClient(
                baseURL: Self.serverBaseURL(bundle: bundle)
            )
            repository = ExplanationRepository(
                overlay: overlay,
                bundled: bundled,
                server: server
            )
            initializationError = nil
        } catch {
            repository = nil
            initializationError = error.localizedDescription
        }
    }

    /// Coalesces a card lookup with any speculative prefetch already running
    /// for the same normalized spelling.
    func resolve(form: String) async throws -> ExplanationResolution? {
        guard let repository else { return nil }
        return try await resolutionCoordinator.resolve(
            form: form,
            repository: repository
        )
    }

    /// Starts a legacy cache-filling lookup without tying it to a view's
    /// lifetime. Returns false when the schema-v1 runtime is unavailable.
    @discardableResult
    func prefetchExplanation(for form: String) -> Bool {
        guard repository != nil else { return false }
        Task { [weak self] in
            _ = try? await self?.resolve(form: form)
        }
        return true
    }

    /// Makes one bounded outbox pass per process. Transport retries keep the
    /// original event UUID, and no call recursively drains the queue.
    func deliverPendingFeedbackOnce() {
        deliveryLock.lock()
        guard !attemptedPendingDelivery, let repository else {
            deliveryLock.unlock()
            return
        }
        attemptedPendingDelivery = true
        deliveryLock.unlock()

        Task {
            _ = try? await repository.sendPendingFeedback(limit: 25)
        }
    }

    private static func serverBaseURL(bundle: Bundle) throws -> URL {
        let configured = (bundle.object(
            forInfoDictionaryKey: "WORDBOOK_EXPLANATION_API_BASE_URL"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = configured.flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://api.wordbook.cool"
        guard let url = URL(string: value) else {
            throw ExplanationServerClientError.invalidBaseURL(
                URL(fileURLWithPath: value)
            )
        }
        return url
    }
}

// MARK: - Entry-first runtime

private struct EntryResolutionKey: Hashable, Sendable {
    let language: String
    let normalizedForm: String
    let locale: String
    let normalizationVersion: Int
    let resolverContractVersion: Int
    let confirmedRareSpelling: Bool
    let allowPendingStatusCheck: Bool
}

private actor EntryResolutionCoordinator {
    private struct InFlight {
        let token: UUID
        let task: Task<EntryResolutionOutcome, Error>
    }

    private var requests: [EntryResolutionKey: InFlight] = [:]

    func resolve(
        form: String,
        language: String,
        locale: String,
        context: EntryResolveContext?,
        confirmedRareSpelling: Bool,
        allowPendingStatusCheck: Bool,
        repository: EntryExplanationRepository
    ) async throws -> EntryResolutionOutcome {
        let key = EntryResolutionKey(
            language: language.lowercased(),
            normalizedForm: OfflineExplanationStore.normalizeForm(form),
            locale: locale.replacingOccurrences(of: "_", with: "-"),
            normalizationVersion: EntryContractValidator.normalizationVersion,
            resolverContractVersion: EntryContractValidator.resolverContractVersion,
            confirmedRareSpelling: confirmedRareSpelling,
            allowPendingStatusCheck: allowPendingStatusCheck
        )
        // Context changes ordering but never membership. A foreground lookup
        // with context should not join a context-free speculative prefetch.
        // Conversely, identical context-free work is safely coalesced.
        if context == nil, let inFlight = requests[key] {
            return try await inFlight.task.value
        }
        let token = UUID()
        let task = Task {
            try await repository.resolve(
                form: form,
                language: language,
                locale: locale,
                context: context,
                confirmedRareSpelling: confirmedRareSpelling,
                allowPendingStatusCheck: allowPendingStatusCheck
            )
        }
        if context == nil {
            requests[key] = InFlight(token: token, task: task)
        }
        do {
            let result = try await task.value
            if context == nil { finish(key: key, token: token) }
            return result
        } catch {
            if context == nil { finish(key: key, token: token) }
            throw error
        }
    }

    private func finish(key: EntryResolutionKey, token: UUID) {
        guard requests[key]?.token == token else { return }
        requests.removeValue(forKey: key)
    }
}

/// Runtime for Entry-first explanations. It never prepares or calls
/// `LocalTutorManager`; a catalog miss goes only to the bounded v3 service.
final class EntryExplanationRuntime: @unchecked Sendable {
    static let shared = EntryExplanationRuntime()

    let repository: EntryExplanationRepository?
    let initializationError: String?

    private let coordinator = EntryResolutionCoordinator()
    private let deliveryLock = NSLock()
    private var attemptedPendingDelivery = false

    private init(bundle: Bundle = .main) {
        guard let packURL = bundle.url(
            forResource: "wordbook-content",
            withExtension: "sqlite"
        ) else {
            repository = nil
            initializationError = "The reviewed explanation pack is unavailable."
            return
        }
        do {
            let catalog = try EntryCatalogStore(databaseURL: packURL)
            let overlay: any EntryOverlayRepositoryStore
            var overlayWarning: String?
            do {
                overlay = try EntryOverlayStore()
            } catch {
                // A damaged writable cache must not disable the signed catalog.
                overlay = DegradedEntryOverlayStore(error: error)
                overlayWarning = error.localizedDescription
            }
            let server = try EntryServerClient(
                baseURL: Self.serverBaseURL(bundle: bundle)
            )
            repository = EntryExplanationRepository(
                overlay: overlay,
                catalog: catalog,
                server: server,
                clientContentVersion: { catalog.contentVersion }
            )
            initializationError = overlayWarning
        } catch {
            repository = nil
            initializationError = error.localizedDescription
        }
    }

    init(repository: EntryExplanationRepository) {
        self.repository = repository
        initializationError = nil
    }

    func resolve(
        form: String,
        language: String = "en",
        locale: String = "en",
        context: EntryResolveContext? = nil,
        confirmedRareSpelling: Bool = false,
        allowPendingStatusCheck: Bool = true
    ) async throws -> EntryResolutionOutcome? {
        guard let repository else { return nil }
        return try await coordinator.resolve(
            form: form,
            language: language,
            locale: locale,
            context: context,
            confirmedRareSpelling: confirmedRareSpelling,
            allowPendingStatusCheck: allowPendingStatusCheck,
            repository: repository
        )
    }

    /// Synchronous overlay/catalog-only lookup for the paired-Watch bridge.
    /// A miss returns nil and never contacts v3 or checks a pending job.
    func resolveLocally(
        form: String,
        language: String = "en",
        locale: String = "en",
        context: EntryResolveContext? = nil
    ) throws -> ResolvedEntryResolution? {
        guard let repository else { return nil }
        return try repository.resolveLocally(
            form: form,
            language: language,
            locale: locale,
            context: context
        )
    }

    /// Resolves only the local overlay/catalog before pronunciation synthesis
    /// begins. A reviewed IPA therefore bypasses G2P on the common path, while
    /// a true local miss returns nil and lets the caller perform G2P exactly
    /// once. The synchronous SQLite read stays off the main actor.
    func preferredLocalPronunciationPhonemes(for form: String) async -> String? {
        let surfaceForm = form.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surfaceForm.isEmpty else { return nil }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            do {
                return try self.resolveLocally(form: surfaceForm)?
                    .entry.preferredPronunciationPhonemes
            } catch {
                // Pronunciation remains available through Kokoro's bundled
                // lexicon/G2P when the local explanation store cannot answer.
                return nil
            }
        }.value
    }

    @discardableResult
    func prefetchEntry(
        for form: String,
        language: String = "en",
        locale: String = "en"
    ) -> Bool {
        guard repository != nil else { return false }
        Task { [weak self] in
            _ = try? await self?.resolve(
                form: form,
                language: language,
                locale: locale,
                allowPendingStatusCheck: false
            )
        }
        return true
    }

    @discardableResult
    func deliverPendingFeedbackOnce() -> Task<Void, Never>? {
        deliveryLock.lock()
        guard !attemptedPendingDelivery, let repository else {
            deliveryLock.unlock()
            return nil
        }
        attemptedPendingDelivery = true
        deliveryLock.unlock()
        return Task { _ = try? await repository.sendPendingFeedback(limit: 25) }
    }

    private static func serverBaseURL(bundle: Bundle) throws -> URL {
        let configured = (bundle.object(
            forInfoDictionaryKey: "WORDBOOK_EXPLANATION_API_BASE_URL"
        ) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = configured.flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://api.wordbook.cool"
        guard let url = URL(string: value) else {
            throw ExplanationServerClientError.invalidBaseURL(
                URL(fileURLWithPath: value)
            )
        }
        return url
    }
}

private final class DegradedEntryOverlayStore: EntryOverlayRepositoryStore,
    @unchecked Sendable {
    private let error: Error

    init(error: Error) { self.error = error }

    func entry(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> ResolvedWordEntry? { nil }

    func installCompleteEntry(
        _ entry: ResolvedWordEntry,
        activate: Bool
    ) throws -> Bool { throw error }

    func applyingSelectedReplacements(
        to entry: ResolvedWordEntry
    ) throws -> ResolvedWordEntry { entry }

    func replacementExclusionHistory(
        entryID: String,
        entryUsageID: String,
        locale: String,
        baseEntryRevision: Int,
        baseContentVersion: String,
        currentExplanationID: String
    ) throws -> [String] { throw error }

    func installReplacement(
        _ replacement: EntryLessonReplacement,
        against baseEntry: ResolvedWordEntry
    ) throws { throw error }

    func storePending(
        _ pending: EntryPendingResolution,
        normalizedForm: String,
        language: String,
        locale: String,
        eventID: UUID?
    ) throws { throw error }

    func pending(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryPendingResolution? { nil }

    func pending(eventID: UUID) throws -> EntryPendingResolution? { nil }

    func markJobFinished(_ jobID: String) throws { throw error }

    func storeCorrection(
        _ correction: EntryCorrectionResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws { throw error }

    func storeNegative(
        _ negative: EntryNegativeResolution,
        normalizedForm: String,
        language: String,
        locale: String
    ) throws { throw error }

    func cachedMiss(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> EntryCachedMiss? { nil }

    func enqueueFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) throws -> Bool { throw error }
    func dequeuePendingFeedback(limit: Int) throws -> [EntryFeedbackOutboxItem] { throw error }
    func pendingFeedback(eventID: UUID) throws -> EntryFeedbackOutboxItem? { throw error }
    func quarantineFeedback(eventID: UUID, failureReason: String) throws { throw error }
    func markFeedbackSent(eventID: UUID) throws { throw error }
    func markReplacementComplete(eventID: UUID) throws { throw error }
}
