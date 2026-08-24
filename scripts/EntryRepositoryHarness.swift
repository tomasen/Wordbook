import Foundation

enum EntryRepositoryHarnessFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

private final class CountingEntryCatalog: EntryCatalogLookupStore, @unchecked Sendable {
    private let lock = NSLock()
    private let entries: [String: ResolvedWordEntry]
    private(set) var calls = 0

    init(_ entries: [ResolvedWordEntry]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.normalizedForm, $0)
        })
    }

    func entry(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> ResolvedWordEntry? {
        lock.lock()
        calls += 1
        lock.unlock()
        guard let entry = entries[OfflineExplanationStore.normalizeForm(surfaceForm)] else {
            return nil
        }
        return ResolvedWordEntry(
            entryID: entry.entryID,
            encounteredSurfaceForm: surfaceForm,
            displayForm: entry.displayForm,
            normalizedForm: entry.normalizedForm,
            language: entry.language,
            locale: entry.locale,
            usages: entry.usages,
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
}

private enum FailingEntryCatalogError: Error {
    case corruptCatalog
}

private final class FailingEntryCatalog: EntryCatalogLookupStore,
    @unchecked Sendable {
    func entry(
        for surfaceForm: String,
        language: String,
        locale: String
    ) throws -> ResolvedWordEntry? {
        throw FailingEntryCatalogError.corruptCatalog
    }
}

private final class ScriptedEntryServer: EntryServerServing, @unchecked Sendable {
    private let lock = NSLock()
    private var resolveResults: [EntryServerResult]
    private var jobResults: [EntryServerResult]
    var replacementResult: EntryServerReplacementResult?
    var feedbackFailuresRemaining = 0
    var invalidFeedbackReceiptsRemaining = 0
    private(set) var resolveCalls = 0
    private(set) var jobCalls = 0
    private(set) var feedbackCalls = 0
    private(set) var replacementCalls = 0
    private(set) var resolveRequests: [EntryResolveRequest] = []
    private(set) var feedbackEvents: [EntryFeedbackEvent] = []
    private(set) var feedbackBaseEntries: [ResolvedWordEntry] = []

    init(
        resolveResults: [EntryServerResult] = [],
        jobResults: [EntryServerResult] = []
    ) {
        self.resolveResults = resolveResults
        self.jobResults = jobResults
    }

    func resolve(_ request: EntryResolveRequest) async throws -> EntryServerResult {
        try takeResolveResult(request)
    }

    private func takeResolveResult(_ request: EntryResolveRequest) throws -> EntryServerResult {
        lock.lock()
        defer { lock.unlock() }
        resolveCalls += 1
        resolveRequests.append(request)
        guard !resolveResults.isEmpty else {
            throw ExplanationServerClientError.transportFailed("fixture network unavailable")
        }
        return resolveResults.removeFirst()
    }

    func jobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?
    ) async throws -> EntryServerResult {
        try takeJobResult()
    }

    private func takeJobResult() throws -> EntryServerResult {
        lock.lock()
        defer { lock.unlock() }
        jobCalls += 1
        guard !jobResults.isEmpty else {
            throw ExplanationServerClientError.transportFailed("fixture job unavailable")
        }
        return jobResults.removeFirst()
    }

    func sendFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerFeedbackReceipt {
        let result = recordFeedbackCall(event: event, baseEntry: baseEntry)
        if result.shouldFail {
            throw ExplanationServerClientError.transportFailed(
                "fixture feedback network unavailable"
            )
        }
        if result.shouldReturnInvalidReceipt {
            return EntryServerFeedbackReceipt(
                eventID: event.eventID,
                accepted: false,
                replacementResult: nil
            )
        }
        return EntryServerFeedbackReceipt(
            eventID: event.eventID,
            accepted: true,
            replacementResult: event.requestReplacement ? result.replacementResult : nil
        )
    }

    private func recordFeedbackCall(
        event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) -> (
        shouldFail: Bool,
        shouldReturnInvalidReceipt: Bool,
        replacementResult: EntryServerReplacementResult?
    ) {
        lock.lock()
        defer { lock.unlock() }
        feedbackCalls += 1
        feedbackEvents.append(event)
        feedbackBaseEntries.append(baseEntry)
        let shouldFail = feedbackFailuresRemaining > 0
        if shouldFail { feedbackFailuresRemaining -= 1 }
        let shouldReturnInvalidReceipt = !shouldFail && invalidFeedbackReceiptsRemaining > 0
        if shouldReturnInvalidReceipt { invalidFeedbackReceiptsRemaining -= 1 }
        return (shouldFail, shouldReturnInvalidReceipt, replacementResult)
    }

    func requestReplacement(
        for event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult {
        try takeReplacementResult()
    }

    func replacementJobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult {
        try takeReplacementResult()
    }

    private func takeReplacementResult() throws -> EntryServerReplacementResult {
        lock.lock()
        defer { lock.unlock() }
        replacementCalls += 1
        guard let replacementResult else {
            throw ExplanationServerClientError.transportFailed("fixture replacement unavailable")
        }
        return replacementResult
    }
}

private final class StaticEntryTransport: ExplanationServerTransport, @unchecked Sendable {
    private let response: ExplanationTransportResponse
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    init(data: Data, statusCode: Int = 200) {
        response = ExplanationTransportResponse(data: data, statusCode: statusCode)
    }

    func send(_ request: URLRequest) async throws -> ExplanationTransportResponse {
        record(request)
        return response
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

@main
struct EntryRepositoryHarness {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordbookEntryRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalogSaw = try EntryTestFixtures.sawEntry(
            contentVersion: "catalog-v1",
            baseContentVersion: "catalog-v1",
            trust: .releaseReviewed,
            coverage: .releaseReviewedComplete
        )
        let catalog = CountingEntryCatalog([catalogSaw])
        let overlayURL = directory.appendingPathComponent("overlay.sqlite")
        let overlay = try EntryOverlayStore(
            databaseURL: overlayURL,
            now: { now }
        )
        let server = ScriptedEntryServer()
        var repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: server,
            now: { now },
            clientContentVersion: { "catalog-v1" }
        )
		try verifyPublicEntryTrustAndReleaseVersionBoundaries()
		try await verifyReleaseSidecarFeedbackAndOutboxContinuation(
			directory: directory,
			now: now,
			catalogEntry: catalogSaw
		)
		try await verifyNonretryableFeedbackDoesNotBlockOutbox(
			directory: directory,
			now: now,
			catalogEntry: catalogSaw
		)
        try await verifyCatalogFailureDoesNotBecomeNetworkMiss(
            directory: directory,
            now: now,
            serverEntry: catalogSaw
        )
        try await verifyForegroundResolveStatusIsBounded(
            directory: directory,
            now: now
        )
        try await verifyForegroundReplacementStatusIsBounded(
            directory: directory,
            now: now,
            catalogEntry: catalogSaw
        )
        try await verifyConfirmedRareSpellingCacheBoundary(
            directory: directory,
            now: now
        )
        try await verifyEntryRuntimeOutboxSinglePass(
            directory: directory,
            now: now,
            catalogEntry: catalogSaw
        )
        try verifyWatchLookupStaysLocal(
            directory: directory,
            now: now,
            catalogEntry: catalogSaw
        )

        let seeing = try resolved(try await repository.resolve(
            form: "saw",
            context: EntryTestFixtures.context("I saw a fox.", target: "saw")
        ))
        try expect(
            seeing.entry.usages.first?.entryUsageID == "usage-seeing-opaque",
            "Pronoun + target did not prefer the reviewed verb Usage."
        )
        let tool = try resolved(try await repository.resolve(
            form: "saw",
            context: EntryTestFixtures.context("Pass me the saw.", target: "saw")
        ))
        try expect(
            tool.entry.usages.first?.entryUsageID == "usage-tool-opaque",
            "Determiner + target did not prefer the reviewed noun Usage."
        )
        try expect(
            tool.entry.usages.count == 2,
            "Context ranking discarded an existing Usage."
        )
        try expect(server.resolveCalls == 0, "Complete catalog hits used the network.")
        try expect(catalog.calls == 2, "Catalog was not queried for every exact lookup.")

        let invalidLookupLocales = [
            "e--US", "e-US", "en-123456789", "en_US", "é-US",
        ]
        for locale in invalidLookupLocales {
            do {
                _ = try await repository.resolve(form: "saw", locale: locale)
                throw EntryRepositoryHarnessFailure.failed(
                    "Repository accepted invalid locale \(locale)."
                )
            } catch let error as EntryRepositoryError {
                guard case .invalidLocale(let rejected) = error,
                      rejected == locale else { throw error }
            }
        }
        do {
            _ = try await repository.resolve(form: "saw", language: "fr")
            throw EntryRepositoryHarnessFailure.failed(
                "Repository accepted unsupported language fr."
            )
        } catch let error as EntryRepositoryError {
            guard case .unsupportedLanguage(let rejected) = error,
                  rejected == "fr" else { throw error }
        }
        try expect(
            catalog.calls == 2 && server.resolveCalls == 0,
            "An invalid locale reached a local store or the server."
        )

        let overlaySaw = try EntryTestFixtures.sawEntry(
            revision: 2,
            coverageRevision: 1,
            contentVersion: "server-saw-v2",
            baseContentVersion: "catalog-v1"
        )
        try expect(
            try overlay.installCompleteEntry(overlaySaw),
            "Compatible newer overlay Entry was not activated."
        )
        let newer = try resolved(try await repository.resolve(form: "saw"))
        try expect(newer.source == .overlay, "Compatible newer overlay did not win.")
        try expect(
            newer.entry.entryRevision == 2 && newer.entry.usages.count == 2,
            "Precedence merged or truncated the chosen whole snapshot."
        )
        try expect(catalog.calls == 3, "Overlay hit incorrectly skipped catalog comparison.")

        let pending = EntryPendingResolution(
            jobID: "job-rare-opaque",
            canonicalKeyHash: String(repeating: "b", count: 64),
            jobKind: "resolveEntry",
            nextCheckAt: now.addingTimeInterval(60),
            checkCount: 0
        )
        let pendingServer = ScriptedEntryServer(resolveResults: [.pending(pending)])
        repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: pendingServer,
            now: { now }
        )
        let firstPending = try await repository.resolve(form: "extremelyrare")
        try expect(firstPending == .pending(pending), "Pending v3 result was lost.")
        let secondPending = try await repository.resolve(form: "extremelyrare")
        try expect(secondPending == .pending(pending), "Durable pending result was not reused.")
        try expect(
            pendingServer.resolveCalls == 1,
            "A pending job started another generation request before nextCheckAt."
        )

        let terminalPending = EntryPendingResolution(
            jobID: "job-terminal-unavailable-opaque",
            canonicalKeyHash: String(repeating: "9", count: 64),
            jobKind: "resolveEntry",
            nextCheckAt: now.addingTimeInterval(-1),
            checkCount: 2
        )
        let terminalUnavailable = EntryUnavailableResolution(
            reason: "review_failed",
            retryAfter: nil
        )
        let terminalServer = ScriptedEntryServer(
            resolveResults: [
                .pending(terminalPending),
                .unavailable(terminalUnavailable),
            ],
            jobResults: [.unavailable(terminalUnavailable)]
        )
        repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: terminalServer,
            now: { now }
        )
        let firstTerminal = try await repository.resolve(form: "terminalrare")
        try expect(
            firstTerminal == .pending(terminalPending),
            "The terminal-unavailable fixture did not first persist its job."
        )
        let terminalPoll = try await repository.resolve(form: "terminalrare")
        try expect(
            terminalPoll == .unavailable(terminalUnavailable),
            "A terminal unavailable job result was not surfaced."
        )
        let afterTerminal = try await repository.resolve(form: "terminalrare")
        try expect(
            afterTerminal == .unavailable(terminalUnavailable),
            "A new lookup was not allowed after the terminal unavailable job."
        )
        try expect(
            terminalServer.jobCalls == 1 && terminalServer.resolveCalls == 2,
            "A terminal unavailable job was polled again instead of being finished."
        )

        let gynecologists = try EntryTestFixtures.entry(
            surfaceForm: "gynecologists",
            entryID: "entry-gynecologists-opaque",
            revision: 1,
            coverageRevision: 1,
            contentVersion: "server-gynecologists-v1",
            baseContentVersion: "catalog-v1",
            trust: .serverReviewed,
            coverage: .serverReviewedComplete,
            specs: [EntryTestFixtures.UsageSpec(
                id: "usage-gynecologists-opaque",
                label: "women's reproductive-health doctors",
                partOfSpeech: "plural noun",
                relation: "plural form",
                ipa: "ˌɡaɪnəˈkɑlədʒɪsts",
                explanation: "Doctors who specialize in the female reproductive system, including the uterus and ovaries.",
                example: "The clinic has two gynecologists available for routine checkups.",
                synonyms: [],
                core: true
            )]
        )
		try await verifyValidServerEntrySurvivesOverlayCacheFailure(
			directory: directory,
			now: now,
			entry: gynecologists
		)
        let resolvingServer = ScriptedEntryServer(resolveResults: [.resolved(gynecologists)])
        repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: resolvingServer,
            now: { now }
        )
        let remote = try resolved(try await repository.resolve(form: "gynecologists"))
        try expect(remote.source == .server, "Rare resolved Entry lost its server source.")
        try expect(remote.entry.usages.count == 1, "Server Entry was not complete.")

        let offlineServer = ScriptedEntryServer()
        repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: offlineServer,
            now: { now }
        )
        let cached = try resolved(try await repository.resolve(form: "gynecologists"))
        try expect(cached.source == .overlay, "Server Entry did not become an offline hit.")
        try expect(offlineServer.resolveCalls == 0, "Cached overlay-only Entry used the server.")

        let replacement = try EntryTestFixtures.replacement(
            for: overlaySaw,
            usageID: "usage-tool-opaque",
            explanation: "A hand or powered tool whose toothed blade cuts wood and other firm materials.",
            example: "Pass me the saw so I can cut this shelf to length."
        )
        offlineServer.replacementResult = .complete(replacement)
        let sawResolution = try resolved(try await repository.resolve(form: "saw"))
        let submission = try await repository.submitFeedback(
            for: sawResolution,
            entryUsageID: "usage-tool-opaque",
            rating: .notHelpful,
            component: .example,
            requestReplacement: true
        )
        try expect(
            submission.replacementState == .complete(replacement),
            "Full lesson replacement did not complete."
        )
        let afterReplacement = try resolved(try await repository.resolve(form: "saw"))
        try expect(
            afterReplacement.entry.usages.first(where: {
                $0.entryUsageID == "usage-tool-opaque"
            })?.explanationID == replacement.explanationID,
            "Replacement sidecar was not visible on the next lookup."
        )
        try expect(
            afterReplacement.entry.usages.first(where: {
                $0.entryUsageID == "usage-seeing-opaque"
            })?.explanationID == overlaySaw.usages[0].explanationID,
            "Full lesson replacement changed another Usage."
        )

        // Queue feedback against exactly the R1 lesson the learner saw. R2 is
        // selected before delivery, so a reopened repository must still send
        // the retained R1 snapshot rather than reconstructing current state.
        offlineServer.feedbackFailuresRemaining = 1
        let queuedR1 = try await repository.submitFeedback(
            for: afterReplacement,
            entryUsageID: "usage-tool-opaque",
            rating: .helpful,
            component: .wholeLesson,
            requestReplacement: false
        )
        try expect(
            queuedR1.deliveryState == .queued,
            "R1 feedback did not remain queued after its retryable failure."
        )

        // A visible card must be able to resume its exact durable replacement
        // job, and a replacement of a replacement must remain selected.
        let chainedReplacement = try EntryTestFixtures.replacement(
            for: afterReplacement.entry,
            usageID: "usage-tool-opaque",
            explanation: "A toothed tool used to cut firm material such as wood.",
            example: "She used the saw to trim the board."
        )
        let dueReplacement = EntryPendingResolution(
            jobID: "job-replacement-due-opaque",
            canonicalKeyHash: String(repeating: "d", count: 64),
            jobKind: "replaceExplanation",
            nextCheckAt: now.addingTimeInterval(-1),
            checkCount: 0
        )
        offlineServer.replacementResult = .pending(dueReplacement)
        let dueSubmission = try await repository.submitFeedback(
            for: afterReplacement,
            entryUsageID: "usage-tool-opaque",
            rating: .notHelpful,
            component: .explanation,
            requestReplacement: true
        )
        try expect(
            dueSubmission.replacementState == .pending(dueReplacement),
            "Due replacement job was not persisted."
        )
        offlineServer.replacementResult = .complete(chainedReplacement)
        let resumed = try require(
            try await repository.resumeFeedback(eventID: dueSubmission.eventID),
            "The exact durable feedback event could not be resumed."
        )
        try expect(
            resumed.replacementState == .complete(chainedReplacement),
            "Resumed replacement job did not complete."
        )
        let afterChainedReplacement = try resolved(
            try await repository.resolve(form: "saw")
        )
        try expect(
            afterChainedReplacement.entry.usages.first(where: {
                $0.entryUsageID == "usage-tool-opaque"
            })?.explanationID == chainedReplacement.explanationID,
            "Replacement chaining was lost on the next repository lookup."
        )

        let reopenedOverlay = try EntryOverlayStore(
            databaseURL: overlayURL,
            now: { now }
        )
        let replayServer = ScriptedEntryServer()
        let reopenedRepository = EntryExplanationRepository(
            overlay: reopenedOverlay,
            catalog: catalog,
            server: replayServer,
            now: { now },
            clientContentVersion: { "catalog-v1" }
        )
        let reopenedSaw = try resolved(
            try await reopenedRepository.resolve(form: "saw")
        )
        try expect(
            reopenedSaw.entry.usages.first(where: {
                $0.entryUsageID == "usage-tool-opaque"
            })?.explanationID == chainedReplacement.explanationID,
            "R2 was not selected after reopening the overlay."
        )
        let replayed = try await reopenedRepository.sendPendingFeedback(limit: 10)
        try expect(
            replayed.count == 1
                && replayed[0].eventID == queuedR1.eventID
                && replayed[0].deliveryState == .sent,
            "The exact queued R1 feedback event was not replayed after reopening."
        )
        let replayedEvent = try require(
            replayServer.feedbackEvents.first(where: { $0.eventID == queuedR1.eventID }),
            "The replay server did not receive the queued R1 event."
        )
        let replayedBase = try require(
            replayServer.feedbackBaseEntries.first,
            "The replay server did not receive the queued event's base Entry."
        )
        try expect(
            replayedEvent.explanationID == replacement.explanationID
                && replayedBase.usages.first(where: {
                    $0.entryUsageID == "usage-tool-opaque"
                })?.explanationID == replacement.explanationID,
            "Queued R1 feedback was rebound to the selected R2 lesson."
        )

        // Keep the rest of the workflow on the original scripted server; the
        // durable database state is shared by both store instances.
        repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: offlineServer,
            now: { now }
        )

        let replacementPending = EntryPendingResolution(
            jobID: "job-replacement-opaque",
            canonicalKeyHash: String(repeating: "c", count: 64),
            jobKind: "replaceExplanation",
            nextCheckAt: now.addingTimeInterval(60),
            checkCount: 0
        )
        offlineServer.replacementResult = .pending(replacementPending)
        let pendingSubmission = try await repository.submitFeedback(
            for: afterReplacement,
            entryUsageID: "usage-seeing-opaque",
            rating: .notHelpful,
            component: .explanation,
            requestReplacement: true
        )
        try expect(
            pendingSubmission.replacementState == .pending(replacementPending),
            "Replacement pending state was not surfaced."
        )
        let replacementCallsBeforeRetry = offlineServer.replacementCalls
        let pendingRetry = try await repository.sendPendingFeedback(limit: 10)
        try expect(
            pendingRetry.contains(where: {
                $0.replacementState == .pending(replacementPending)
            }),
            "Durable replacement job was not retained for retry."
        )
        try expect(
            offlineServer.replacementCalls == replacementCallsBeforeRetry,
            "Replacement endpoint was called again before durable nextCheckAt."
        )

        try await verifyV3ClientRejectsPartialEntry(gynecologists)
        try await verifyV3ClientRejectsNoncanonicalEntryKeys()
        print("EntryExplanationRepository harness passed")
    }

    private static func verifyWatchLookupStaysLocal(
        directory: URL,
        now: Date,
        catalogEntry: ResolvedWordEntry
    ) throws {
        let catalog = CountingEntryCatalog([catalogEntry])
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("watch-local.sqlite"),
            now: { now }
        )
        let server = ScriptedEntryServer()
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: catalog,
            server: server,
            now: { now }
        )
        let local = try repository.resolveLocally(form: "saw")
        try expect(
            local?.entry.usages.count == 2,
            "Watch-local resolution lost an ambiguous Usage."
        )
        let miss = try repository.resolveLocally(
            form: "not-in-the-reviewed-catalog"
        )
        try expect(
            miss == nil && server.resolveCalls == 0,
            "A Watch-local miss started an explanation server request."
        )
    }

    private static func verifyCatalogFailureDoesNotBecomeNetworkMiss(
        directory: URL,
        now: Date,
        serverEntry: ResolvedWordEntry
    ) async throws {
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("fail-closed-catalog.sqlite"),
            now: { now }
        )
        let server = ScriptedEntryServer(resolveResults: [.resolved(serverEntry)])
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: FailingEntryCatalog(),
            server: server,
            now: { now }
        )
        do {
            _ = try await repository.resolve(form: "not-a-network-miss")
            throw EntryRepositoryHarnessFailure.failed(
                "A catalog read failure was reclassified as a network miss."
            )
        } catch FailingEntryCatalogError.corruptCatalog {
            // Expected: catalog integrity failures propagate unchanged.
        }
        try expect(
            server.resolveCalls == 0,
            "A catalog read failure called the explanation server."
        )
    }

    private static func verifyForegroundResolveStatusIsBounded(
        directory: URL,
        now: Date
    ) async throws {
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("foreground-resolve.sqlite"),
            now: { now }
        )
        let firstPending = EntryPendingResolution(
            jobID: "job-foreground-resolve-first",
            canonicalKeyHash: String(repeating: "1", count: 64),
            jobKind: "resolveEntry",
            nextCheckAt: now.addingTimeInterval(-1),
            checkCount: 0
        )
        let stillPending = EntryPendingResolution(
            jobID: firstPending.jobID,
            canonicalKeyHash: firstPending.canonicalKeyHash,
            jobKind: firstPending.jobKind,
            nextCheckAt: now.addingTimeInterval(30),
            checkCount: 1
        )
        let server = ScriptedEntryServer(
            resolveResults: [.pending(firstPending)],
            jobResults: [.pending(stillPending)]
        )
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: CountingEntryCatalog([]),
            server: server,
            now: { now }
        )

        var budget = EntryForegroundStatusCheckBudget()
        let initial = try await repository.resolve(
            form: "foregroundrare",
            allowPendingStatusCheck: false
        )
        try expect(initial == .pending(firstPending), "Initial foreground resolve was lost.")
        try expect(
            server.resolveCalls == 1 && server.jobCalls == 0,
            "The initial foreground resolve also checked job status."
        )
        try expect(budget.claimStatusCheck(), "Foreground status budget had no first check.")
        let checked = try await repository.resolve(
            form: "foregroundrare",
            allowPendingStatusCheck: true
        )
        try expect(checked == .pending(stillPending), "The one status check was not persisted.")
        try expect(
            server.resolveCalls == 1 && server.jobCalls == 1,
            "Foreground resolve made more than one request/status pair."
        )
        try expect(
            !budget.claimStatusCheck(),
            "Foreground resolve budget allowed a second status check."
        )
        try expect(
            try overlay.pending(
                for: "foregroundrare",
                language: "en",
                locale: "en"
            ) == stillPending,
            "Pending foreground resolve was not durable for a later opportunity."
        )
    }

    private static func verifyForegroundReplacementStatusIsBounded(
        directory: URL,
        now: Date,
        catalogEntry: ResolvedWordEntry
    ) async throws {
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("foreground-replacement.sqlite"),
            now: { now }
        )
        let server = ScriptedEntryServer()
        let firstPending = EntryPendingResolution(
            jobID: "job-foreground-replacement",
            canonicalKeyHash: String(repeating: "2", count: 64),
            jobKind: "replaceExplanation",
            nextCheckAt: now.addingTimeInterval(-1),
            checkCount: 0
        )
        let stillPending = EntryPendingResolution(
            jobID: firstPending.jobID,
            canonicalKeyHash: firstPending.canonicalKeyHash,
            jobKind: firstPending.jobKind,
            nextCheckAt: now.addingTimeInterval(30),
            checkCount: 1
        )
        server.replacementResult = .pending(firstPending)
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: CountingEntryCatalog([catalogEntry]),
            server: server,
            now: { now }
        )
        let resolution = try resolved(try await repository.resolve(form: "saw"))
        var submission = try await repository.submitFeedback(
            for: resolution,
            entryUsageID: "usage-tool-opaque",
            rating: .notHelpful,
            component: .explanation,
            requestReplacement: true
        )
        try expect(
            submission.replacementState == .pending(firstPending),
            "Initial replacement request did not persist its pending job."
        )

        var budget = EntryForegroundStatusCheckBudget()
        try expect(budget.claimStatusCheck(), "Replacement status budget had no first check.")
        server.replacementResult = .pending(stillPending)
        submission = try require(
            try await repository.resumeFeedback(eventID: submission.eventID),
            "Pending replacement disappeared before its one foreground check."
        )
        try expect(
            submission.replacementState == .pending(stillPending)
                && server.feedbackCalls == 1
                && server.replacementCalls == 1,
            "Foreground replacement made more than one initial/status request pair."
        )
        try expect(
            !budget.claimStatusCheck(),
            "Foreground replacement budget allowed a second status check."
        )
        try expect(
            try overlay.pending(eventID: submission.eventID) == stillPending,
            "Pending replacement was not durable for a later opportunity."
        )
    }

    private static func verifyConfirmedRareSpellingCacheBoundary(
        directory: URL,
        now: Date
    ) async throws {
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("confirmed-spelling.sqlite"),
            now: { now }
        )
        let correction = EntryCorrectionResolution(
            candidates: ["psithurism"],
            expiresAt: now.addingTimeInterval(3_600)
        )
        let resolvedEntry = try EntryTestFixtures.entry(
            surfaceForm: "psithurysm",
            entryID: "entry-confirmed-rare-opaque",
            revision: 1,
            coverageRevision: 1,
            contentVersion: "server-confirmed-rare-v1",
            baseContentVersion: "catalog-v1",
            trust: .serverReviewed,
            coverage: .serverReviewedComplete,
            specs: [EntryTestFixtures.UsageSpec(
                id: "usage-confirmed-rare-opaque",
                label: "a soft rustling sound",
                partOfSpeech: "noun",
                relation: nil,
                ipa: "sɪθərɪzəm",
                explanation: "A soft rustling sound, especially wind moving through leaves.",
                example: "They listened to the psithurysm in the trees.",
                synonyms: ["rustling"],
                core: true
            )]
        )
        let server = ScriptedEntryServer(
            resolveResults: [.correctionRequired(correction), .resolved(resolvedEntry)]
        )
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: CountingEntryCatalog([]),
            server: server,
            now: { now }
        )
        let first = try await repository.resolve(form: "psithurysm")
        let cached = try await repository.resolve(form: "psithurysm")
        try expect(
            first == .correctionRequired(correction)
                && cached == .correctionRequired(correction)
                && server.resolveCalls == 1,
            "A normal lookup bypassed or refetched its cached correction."
        )
        let confirmed = try await repository.resolve(
            form: "psithurysm",
            confirmedRareSpelling: true,
            allowPendingStatusCheck: false
        )
        try expect(
            try resolved(confirmed).entry.entryID == resolvedEntry.entryID,
            "Confirmed rare spelling did not bypass its matching correction once."
        )
        try expect(
            server.resolveCalls == 2
                && server.resolveRequests.last?.confirmedRareSpelling == true,
            "Confirmed rare spelling was not carried on the retry request."
        )

        let negative = EntryNegativeResolution(
            reason: "notFound",
            expiresAt: now.addingTimeInterval(3_600)
        )
        try overlay.storeNegative(
            negative,
            normalizedForm: "definitelynotaword",
            language: "en",
            locale: "en"
        )
        let callsBeforeNegative = server.resolveCalls
        let confirmedNegative = try await repository.resolve(
            form: "definitelynotaword",
            confirmedRareSpelling: true,
            allowPendingStatusCheck: false
        )
        try expect(
            confirmedNegative == .negative(negative)
                && server.resolveCalls == callsBeforeNegative,
            "Rare-spelling confirmation bypassed a finite negative."
        )

        let unrelated = EntryCorrectionResolution(
            candidates: ["another"],
            expiresAt: now.addingTimeInterval(3_600)
        )
        try overlay.storeCorrection(
            unrelated,
            normalizedForm: "anothre",
            language: "en",
            locale: "en"
        )
        try expect(
            try overlay.cachedMiss(
                for: "anothre",
                language: "en",
                locale: "en"
            ) == .correctionRequired(unrelated),
            "Confirming one spelling changed an unrelated correction cache row."
        )
    }

    private static func verifyEntryRuntimeOutboxSinglePass(
        directory: URL,
        now: Date,
        catalogEntry: ResolvedWordEntry
    ) async throws {
        let overlay = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent("runtime-outbox.sqlite"),
            now: { now }
        )
        let server = ScriptedEntryServer()
        let repository = EntryExplanationRepository(
            overlay: overlay,
            catalog: CountingEntryCatalog([catalogEntry]),
            server: server,
            now: { now }
        )
        let resolution = try resolved(try await repository.resolve(form: "saw"))
        server.feedbackFailuresRemaining = 1
        let queued = try await repository.submitFeedback(
            for: resolution,
            entryUsageID: "usage-seeing-opaque",
            rating: .helpful
        )
        try expect(queued.deliveryState == .queued, "Runtime outbox fixture was not queued.")

        let runtime = EntryExplanationRuntime(repository: repository)
        let firstPass = try require(
            runtime.deliverPendingFeedbackOnce(),
            "Runtime did not start its process-level outbox pass."
        )
        try expect(
            runtime.deliverPendingFeedbackOnce() == nil,
            "Runtime started a second process-level outbox pass."
        )
        await firstPass.value
        try expect(
            server.feedbackCalls == 2,
            "Runtime outbox pass did not retry the one queued event exactly once."
        )
        let remaining = try await repository.sendPendingFeedback(limit: 10)
        try expect(
            remaining.isEmpty,
            "Runtime outbox pass left the delivered event queued."
        )
    }

    private static func verifyV3ClientRejectsPartialEntry(
        _ entry: ResolvedWordEntry
    ) async throws {
        let valid = try responseData(for: entry)
        let transport = StaticEntryTransport(data: valid)
        let client = try EntryServerClient(
            baseURL: try require(URL(string: "https://example.test"), "Invalid test URL."),
            transport: transport
        )
        let request = EntryResolveRequest(
            requestID: UUID(),
            encounteredSurfaceForm: entry.encounteredSurfaceForm,
            language: "en",
            locale: "en",
            context: nil,
            clientContentVersion: "catalog-v1",
            normalizationVersion: EntryContractValidator.normalizationVersion,
            resolverContractVersion: EntryContractValidator.resolverContractVersion,
            lessonSchemaVersion: EntryContractValidator.lessonSchemaVersion,
            lessonContractVersion: EntryContractValidator.lessonContractVersion,
            validatorVersion: 2,
            minimumReviewPolicyVersion: EntryContractValidator.minimumReviewPolicyVersion,
            minimumUsageSelectionPolicyVersion: 1,
            confirmedRareSpelling: false
        )
        guard case .resolved = try await client.resolve(request) else {
            throw EntryRepositoryHarnessFailure.failed("Valid v3 Entry did not decode.")
        }

        var partial = try require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any],
            "Valid response is not an object."
        )
        partial["expectedUsageCount"] = 2
        let invalidData = try JSONSerialization.data(
            withJSONObject: partial,
            options: [.sortedKeys]
        )
        let invalidClient = try EntryServerClient(
            baseURL: try require(URL(string: "https://example.test"), "Invalid test URL."),
            transport: StaticEntryTransport(data: invalidData)
        )
        var rejected = false
        do {
            _ = try await invalidClient.resolve(request)
        } catch ExplanationServerClientError.invalidResponse {
            rejected = true
        }
        try expect(rejected, "v3 client accepted mismatched complete-Entry counts.")
    }

	private static func verifyPublicEntryTrustAndReleaseVersionBoundaries() throws {
		let mismatchedRelease = try EntryTestFixtures.sawEntry(
			contentVersion: "catalog-v2",
			baseContentVersion: "catalog-v1",
			trust: .releaseReviewed,
			coverage: .releaseReviewedComplete
		)
		do {
			try EntryContractValidator.validate(
				mismatchedRelease,
				expectedSurfaceForm: mismatchedRelease.encounteredSurfaceForm
			)
			throw EntryRepositoryHarnessFailure.failed(
				"A release Entry accepted divergent base/content versions."
			)
		} catch is EntryCatalogStoreError {
			// Expected.
		}

		let release = try EntryTestFixtures.sawEntry(
			contentVersion: "catalog-v1",
			baseContentVersion: "catalog-v1",
			trust: .releaseReviewed,
			coverage: .releaseReviewedComplete
		)
		let encoded = try JSONEncoder().encode(release)
		var object = try require(
			JSONSerialization.jsonObject(with: encoded) as? [String: Any],
			"Encoded trust fixture is not an object."
		)
		object["coverageState"] = EntryCoverageState.serverReviewedComplete.rawValue
		object["orderingSource"] = EntryOrderingSource.server.rawValue
		object["contentVersion"] = "server-v1"
		var usages = try require(
			object["usages"] as? [[String: Any]],
			"Encoded trust fixture has no usages."
		)
		usages[0]["trustState"] = LessonTrustState.serverReviewed.rawValue
		object["usages"] = usages
		let mixed = try JSONDecoder().decode(
			ResolvedWordEntry.self,
			from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		)
		do {
			try EntryContractValidator.validate(
				mixed,
				expectedSurfaceForm: mixed.encounteredSurfaceForm
			)
			throw EntryRepositoryHarnessFailure.failed(
				"A mixed-trust server Entry was accepted as a public snapshot."
			)
		} catch is EntryCatalogStoreError {
			// Expected.
		}
		usages[1]["trustState"] = LessonTrustState.serverReviewed.rawValue
		object["usages"] = usages
		let allServer = try JSONDecoder().decode(
			ResolvedWordEntry.self,
			from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
		)
		try EntryContractValidator.validate(
			allServer,
			expectedSurfaceForm: allServer.encounteredSurfaceForm
		)
	}

	private static func verifyReleaseSidecarFeedbackAndOutboxContinuation(
		directory: URL,
		now: Date,
		catalogEntry: ResolvedWordEntry
	) async throws {
		let overlay = try EntryOverlayStore(
			databaseURL: directory.appendingPathComponent("sidecar-outbox.sqlite"),
			now: { now }
		)
		let firstReplacement = try EntryTestFixtures.replacement(
			for: catalogEntry,
			usageID: "usage-tool-opaque",
			explanation: "A toothed hand or powered tool used to cut firm material.",
			example: "She used the saw to trim the board."
		)
		try overlay.installReplacement(firstReplacement, against: catalogEntry)
		let firstEffective = try overlay.applyingSelectedReplacements(to: catalogEntry)
		let replacement = try EntryTestFixtures.replacement(
			for: firstEffective,
			usageID: "usage-tool-opaque",
			explanation: "A toothed tool that cuts firm material by moving its blade through it.",
			example: "She used the saw to cut the board cleanly."
		)
		try overlay.installReplacement(replacement, against: firstEffective)
		let effective = try overlay.applyingSelectedReplacements(to: catalogEntry)
		let resolution = ResolvedEntryResolution(
			surfaceForm: "saw",
			source: .catalog,
			entry: effective
		)
		let server = ScriptedEntryServer()
		server.feedbackFailuresRemaining = 2
		let repository = EntryExplanationRepository(
			overlay: overlay,
			catalog: CountingEntryCatalog([catalogEntry]),
			server: server,
			now: { now },
			clientContentVersion: { "catalog-v1" }
		)
		let replacementSubmission = try await repository.submitFeedback(
			for: resolution,
			entryUsageID: replacement.entryUsageID,
			rating: .notHelpful,
			component: .explanation,
			requestReplacement: true
		)
		let helpfulSubmission = try await repository.submitFeedback(
			for: resolution,
			entryUsageID: "usage-seeing-opaque",
			rating: .helpful
		)
		try expect(
			replacementSubmission.deliveryState == .queued
				&& helpfulSubmission.deliveryState == .queued,
			"The sidecar outbox fixture did not queue both retryable events."
		)
		let expectedExclusions = Set([
			catalogEntry.usages.first(where: { $0.entryUsageID == replacement.entryUsageID })!.explanationID,
			firstReplacement.explanationID,
			replacement.explanationID,
		])
		try expect(
			server.feedbackEvents.contains(where: {
				$0.eventID == replacementSubmission.eventID
					&& Set($0.excludedExplanationIDs) == expectedExclusions
			}),
			"Replacement feedback did not persist the complete rejected lesson lineage."
		)
		server.replacementResult = .failed("baseSuperseded")
		let delivered = try await repository.sendPendingFeedback(limit: 10)
		try expect(
			delivered.count == 2
				&& delivered.contains(where: {
					$0.eventID == replacementSubmission.eventID
						&& $0.deliveryState == .sent
						&& $0.replacementState == .failed("baseSuperseded")
				})
				&& delivered.contains(where: {
					$0.eventID == helpfulSubmission.eventID
						&& $0.deliveryState == .sent
				}),
			"A terminal superseded replacement blocked a later outbox event."
		)
		let remainingDeliveries = try await repository.sendPendingFeedback(limit: 10)
		try expect(
			remainingDeliveries.isEmpty,
			"Terminal feedback rows remained in the pending outbox."
		)

		let response = try JSONSerialization.data(withJSONObject: [
			"eventID": replacementSubmission.eventID.uuidString.lowercased(),
			"accepted": true,
			"replacement": [
				"jobID": "job_superseded_fixture",
				"kind": "replaceExplanation",
				"canonicalKeyHash": String(repeating: "a", count: 64),
				"state": "failed",
				"candidateAttempts": 0,
				"maximumCandidateAttempts": 2,
				"reviewAttempts": 0,
				"maximumReviewAttempts": 2,
				"createdAt": "2026-08-24T00:00:00Z",
				"updatedAt": "2026-08-24T00:00:00Z",
				"deadlineAt": "2026-08-24T00:03:00Z",
				"failureCode": "baseSuperseded",
			],
		], options: [.sortedKeys])
		let transport = StaticEntryTransport(data: response)
		let client = try EntryServerClient(
			baseURL: try require(URL(string: "https://example.test"), "Invalid test URL."),
			transport: transport,
			now: { now }
		)
		let event = try require(
			server.feedbackEvents.first(where: {
				$0.eventID == replacementSubmission.eventID
			}),
			"The sidecar feedback event was not captured."
		)
		let receipt = try await client.sendFeedback(event, baseEntry: effective)
		try expect(
			receipt.replacementResult == .failed("baseSuperseded"),
			"The wire client rejected a terminal result for a materialized sidecar."
		)

		let crashURL = directory.appendingPathComponent("sidecar-crash-recovery.sqlite")
		let beforeCrash = try EntryOverlayStore(databaseURL: crashURL, now: { now })
		let crashEvent = EntryFeedbackEvent(
			eventID: try require(
				UUID(uuidString: "e3e24449-20cb-4f75-87f6-df2a4367528e"),
				"Invalid crash recovery event UUID."
			),
			entryID: effective.entryID,
			entryUsageID: replacement.entryUsageID,
			explanationID: replacement.explanationID,
			normalizedForm: effective.normalizedForm,
			language: effective.language,
			locale: effective.locale,
			rating: .notHelpful,
			component: .explanation,
			requestReplacement: true,
			contentVersion: effective.contentVersion,
			appVersion: "test",
			baseContentVersion: effective.contentVersion,
			baseEntryRevision: effective.entryRevision,
			schemaVersion: replacement.schemaVersion,
			lessonContractVersion: replacement.lessonContractVersion,
			validatorVersion: replacement.validatorVersion,
			reviewPolicyVersion: replacement.reviewPolicyVersion,
			excludedExplanationIDs: expectedExclusions.sorted(),
			createdAt: now
		)
		_ = try beforeCrash.enqueueFeedback(crashEvent, baseEntry: effective)
		try beforeCrash.markFeedbackSent(eventID: crashEvent.eventID)
		let afterCrash = try EntryOverlayStore(databaseURL: crashURL, now: { now })
		let recoveryServer = ScriptedEntryServer()
		recoveryServer.replacementResult = .failed("baseSuperseded")
		let recoveryRepository = EntryExplanationRepository(
			overlay: afterCrash,
			catalog: CountingEntryCatalog([catalogEntry]),
			server: recoveryServer,
			now: { now },
			clientContentVersion: { "catalog-v1" }
		)
		let recovered = try await recoveryRepository.sendPendingFeedback(limit: 10)
		try expect(
			recovered.count == 1
				&& recovered[0].eventID == crashEvent.eventID
				&& recovered[0].replacementState == .failed("baseSuperseded")
				&& recoveryServer.feedbackCalls == 0
				&& recoveryServer.replacementCalls == 1,
			"A crash after feedback acknowledgement did not resume the standalone durable request."
		)
		let recoveredAgain = try await recoveryRepository.sendPendingFeedback(limit: 10)
		try expect(
			recoveredAgain.isEmpty,
			"Crash-recovered terminal replacement remained in the outbox."
		)
	}

	private static func verifyNonretryableFeedbackDoesNotBlockOutbox(
		directory: URL,
		now: Date,
		catalogEntry: ResolvedWordEntry
	) async throws {
		let databaseURL = directory.appendingPathComponent("nonretryable-outbox.sqlite")
		let overlay = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
		let server = ScriptedEntryServer()
		server.feedbackFailuresRemaining = 2
		let repository = EntryExplanationRepository(
			overlay: overlay,
			catalog: CountingEntryCatalog([catalogEntry]),
			server: server,
			now: { now },
			clientContentVersion: { catalogEntry.contentVersion }
		)
		let resolution = ResolvedEntryResolution(
			surfaceForm: catalogEntry.encounteredSurfaceForm,
			source: .catalog,
			entry: catalogEntry
		)
		let first = try await repository.submitFeedback(
			for: resolution,
			entryUsageID: catalogEntry.usages[0].entryUsageID,
			rating: .helpful
		)
		let second = try await repository.submitFeedback(
			for: resolution,
			entryUsageID: catalogEntry.usages[1].entryUsageID,
			rating: .helpful
		)
		try expect(
			first.deliveryState == .queued && second.deliveryState == .queued,
			"The nonretryable outbox fixture did not first queue both events."
		)

		server.invalidFeedbackReceiptsRemaining = 1
		let delivered = try await repository.sendPendingFeedback(limit: 10)
		try expect(
			delivered.count == 1 && delivered[0].deliveryState == .sent,
			"A nonretryable server-contract failure blocked the later healthy event."
		)
		let raw = try SQLiteWritableDatabase(url: databaseURL)
		let quarantined = try raw.queryOne(
			"SELECT COUNT(*) FROM feedback_outbox_quarantine"
		) { try $0.integer(at: 0) } ?? 0
		let pending = try raw.queryOne(
			"""
			SELECT COUNT(*) FROM entry_feedback_outbox
			 WHERE feedback_sent_at_ms IS NULL
			    OR replacement_completed_at_ms IS NULL
			"""
		) { try $0.integer(at: 0) } ?? 0
		try expect(
			quarantined == 1 && pending == 0 && server.feedbackCalls == 4,
			"The deterministic failure was not quarantined after the batch continued."
		)
		let remaining = try await repository.sendPendingFeedback(limit: 10)
		try expect(
			remaining.isEmpty,
			"A quarantined event re-entered the active feedback queue."
		)
	}

	private static func verifyValidServerEntrySurvivesOverlayCacheFailure(
		directory: URL,
		now: Date,
		entry: ResolvedWordEntry
	) async throws {
		let databaseURL = directory.appendingPathComponent("degraded-overlay-cache.sqlite")
		let overlay = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
		let raw = try SQLiteWritableDatabase(url: databaseURL)
		try raw.execute(
			"""
			INSERT INTO entry_identity (
			    entry_id, language_tag, normalized_form, normalization_version
			) VALUES (?, ?, 'deliberately-wrong-binding', ?)
			""",
			bindings: [
				.text(entry.entryID), .text(entry.language),
				.integer(Int64(entry.normalizationVersion)),
			]
		)
		let server = ScriptedEntryServer(resolveResults: [.resolved(entry)])
		let repository = EntryExplanationRepository(
			overlay: overlay,
			catalog: CountingEntryCatalog([]),
			server: server,
			now: { now }
		)
		let result = try resolved(try await repository.resolve(
			form: entry.encounteredSurfaceForm
		))
		try expect(
			result.source == .server && result.entry == entry && server.resolveCalls == 1,
			"A valid rare server Entry disappeared when only its overlay cache write failed."
		)
	}

    private static func verifyV3ClientRejectsNoncanonicalEntryKeys() async throws {
        func fixture(
            language: String,
            locale: String,
            pronunciationLocale: String = "en-US"
        ) throws -> ResolvedWordEntry {
            try EntryTestFixtures.entry(
                surfaceForm: "canonicaltest",
                entryID: "entry-canonical-test-opaque",
                revision: 1,
                coverageRevision: 1,
                contentVersion: "server-canonical-test-v1",
                baseContentVersion: "catalog-v1",
                trust: .serverReviewed,
                coverage: .serverReviewedComplete,
                language: language,
                locale: locale,
                specs: [EntryTestFixtures.UsageSpec(
                    id: "usage-canonical-test-opaque",
                    label: "wire validation fixture",
                    partOfSpeech: "noun",
                    relation: nil,
                    ipa: "tɛst",
                    pronunciationLocale: pronunciationLocale,
                    explanation: "A fixture used to test canonical wire identity.",
                    example: "The client rejects a noncanonical language or locale.",
                    synonyms: [],
                    core: true
                )]
            )
        }
        let request = EntryResolveRequest(
            requestID: UUID(),
            encounteredSurfaceForm: "canonicaltest",
            language: "en",
            locale: "en",
            context: nil,
            clientContentVersion: "catalog-v1",
            normalizationVersion: EntryContractValidator.normalizationVersion,
            resolverContractVersion: EntryContractValidator.resolverContractVersion,
            lessonSchemaVersion: EntryContractValidator.lessonSchemaVersion,
            lessonContractVersion: EntryContractValidator.lessonContractVersion,
            validatorVersion: EntryContractValidator.validatorVersion,
            minimumReviewPolicyVersion: EntryContractValidator.minimumReviewPolicyVersion,
            minimumUsageSelectionPolicyVersion:
                EntryContractValidator.usageSelectionPolicyVersion,
            confirmedRareSpelling: false
        )
        let cases: [(ResolvedWordEntry, String)] = [
            (try fixture(language: "EN", locale: "en"),
             "v3 client accepted a noncanonical Entry language tag."),
            (try fixture(language: "fr", locale: "en"),
             "v3 client accepted an unsupported Entry language."),
            (try fixture(language: "en", locale: "e--US"),
             "v3 client accepted an empty locale subtag."),
            (try fixture(language: "en", locale: "e-US"),
             "v3 client accepted a one-letter locale language."),
            (try fixture(language: "en", locale: "en-123456789"),
             "v3 client accepted an overlong locale subtag."),
            (try fixture(language: "en", locale: "en_US"),
             "v3 client accepted an underscored Entry locale."),
            (try fixture(language: "en", locale: "é-US"),
             "v3 client accepted a non-ASCII Entry locale."),
            (try fixture(language: "en", locale: "en-us"),
             "v3 client accepted noncanonical Entry locale casing."),
            (try fixture(
                language: "en",
                locale: "en",
                pronunciationLocale: "e--US"
            ), "v3 client accepted an invalid pronunciation locale."),
        ]
        for (entry, message) in cases {
            let client = try EntryServerClient(
                baseURL: try require(
                    URL(string: "https://example.test"),
                    "Invalid test URL."
                ),
                transport: StaticEntryTransport(data: try responseData(for: entry))
            )
            do {
                _ = try await client.resolve(request)
                throw EntryRepositoryHarnessFailure.failed(message)
            } catch ExplanationServerClientError.invalidResponse {
                // Expected: wire payload identity must already be canonical.
            }
        }

        let pronunciationEntry = try fixture(
            language: "en",
            locale: "en",
            pronunciationLocale: "EN-us"
        )
        let pronunciationClient = try EntryServerClient(
            baseURL: try require(
                URL(string: "https://example.test"),
                "Invalid test URL."
            ),
            transport: StaticEntryTransport(
                data: try responseData(for: pronunciationEntry)
            )
        )
        guard case .resolved = try await pronunciationClient.resolve(request) else {
            throw EntryRepositoryHarnessFailure.failed(
                "v3 client rejected a pronunciation locale allowed by server grammar."
            )
        }
    }

    private static func responseData(for entry: ResolvedWordEntry) throws -> Data {
        let encoded = try JSONEncoder().encode(entry)
        var object = try require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            "Encoded Entry is not an object."
        )
        object["result"] = "resolved"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func resolved(
        _ outcome: EntryResolutionOutcome
    ) throws -> ResolvedEntryResolution {
        guard case .resolved(let resolution) = outcome else {
            throw EntryRepositoryHarnessFailure.failed("Expected a resolved Entry outcome.")
        }
        return resolution
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else { throw EntryRepositoryHarnessFailure.failed(message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw EntryRepositoryHarnessFailure.failed(message) }
        return value
    }
}
