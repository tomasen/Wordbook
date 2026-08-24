import Foundation

enum EntryOverlayHarnessFailure: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

@main
struct EntryOverlayStoreHarness {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordbookEntryOverlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("entry-overlay.sqlite")
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

        var store = try EntryOverlayStore(
            databaseURL: databaseURL,
            now: { fixedNow }
        )
        let saw = try EntryTestFixtures.sawEntry()
        try expect(try store.installCompleteEntry(saw), "Initial complete Entry was not activated.")
        try await verifyConcurrentCodecIsolation(store: store, entry: saw)
        let uppercase = try require(
            try store.entry(for: "  SAW\n", language: "en", locale: "en"),
            "Exact normalized overlay lookup missed saw."
        )
        try expect(uppercase.usages.count == 2, "Overlay exposed a partial Entry.")
        try expect(
            uppercase.encounteredSurfaceForm == "  SAW\n",
            "Lookup did not restore the caller's exact encountered spelling."
        )
        try verifyCanonicalEntryKeys(
            store: store,
            directory: directory,
            now: fixedNow
        )
		try verifyReleaseSidecarMaterialization(
			databaseURL: directory.appendingPathComponent("release-sidecar.sqlite"),
			now: fixedNow
		)
		try verifyFeedbackQuarantine(
			databaseURL: directory.appendingPathComponent("feedback-quarantine.sqlite"),
			now: fixedNow
		)
		try verifyForeignKeyIntegrityGate(
			databaseURL: directory.appendingPathComponent("foreign-key-corrupt.sqlite"),
			now: fixedNow
		)

        // The request surface is not immutable snapshot identity.
        let sameRevisionDifferentSurface = try EntryTestFixtures.sawEntry(surfaceForm: "Saw")
        try expect(
            try store.installCompleteEntry(sameRevisionDifferentSurface),
            "The same reviewed snapshot should install idempotently across casing."
        )

        // entryRevision is the identity of the complete immutable snapshot,
        // while coverageRevision changes iff the reviewed Usage selection
        // projection changes. It can never exceed entryRevision.
        let impossibleCoverageRevision = try EntryTestFixtures.sawEntry(
            revision: 1,
            coverageRevision: 2
        )
        try expectInvalidEntry(
            "An Entry accepted coverageRevision greater than entryRevision."
        ) {
            _ = try store.installCompleteEntry(impossibleCoverageRevision)
        }

        try verifyCoverageRevisionContract(
            databaseURL: directory.appendingPathComponent("coverage-overlay.sqlite"),
            now: fixedNow
        )

        let replacement = try EntryTestFixtures.replacement(
            for: saw,
            usageID: "usage-tool-opaque",
            explanation: "A toothed hand or powered tool used to cut solid material.",
            example: "Please pass me the saw so I can shorten this board."
        )
        try store.installReplacement(replacement, against: saw)
        let replaced = try store.applyingSelectedReplacements(to: saw)
        try expect(
            replaced.usages[0].explanationID == saw.usages[0].explanationID,
            "Replacing one Usage changed an unrelated lesson."
        )
        try expect(
            replaced.usages[1].explanationID == replacement.explanationID,
            "Selected full-lesson replacement was not applied."
        )

        let secondReplacement = try EntryTestFixtures.replacement(
            for: replaced,
            usageID: "usage-tool-opaque",
            explanation: "A tool whose toothed blade moves through firm material to cut it.",
            example: "She used the saw to cut the board cleanly."
        )
        try store.installReplacement(secondReplacement, against: replaced)
        let replacedAgain = try store.applyingSelectedReplacements(to: saw)
        try expect(
            replacedAgain.usages[1].explanationID == secondReplacement.explanationID,
            "A replacement based on an earlier replacement was not applied."
        )
        try expect(
            replacedAgain.usages[0].explanationID == saw.usages[0].explanationID,
            "A chained replacement changed an unrelated lesson."
        )

        let sawRevision2 = try EntryTestFixtures.sawEntry(
            revision: 2,
            coverageRevision: 1,
            contentVersion: "server-saw-v2"
        )
        try expect(
            try store.installCompleteEntry(sawRevision2),
            "A non-regressive complete snapshot was not activated."
        )
        let revision2WithSidecars = try store.applyingSelectedReplacements(to: sawRevision2)
        try expect(
            revision2WithSidecars.usages == sawRevision2.usages,
            "A replacement bound to an old Entry revision leaked into a new snapshot."
        )

        let pending = EntryPendingResolution(
            jobID: "job-saw-opaque",
            canonicalKeyHash: String(repeating: "a", count: 64),
            jobKind: "resolveEntry",
            nextCheckAt: fixedNow.addingTimeInterval(30),
            checkCount: 1
        )
        try store.storePending(
            pending,
            normalizedForm: "unlisted",
            language: "en",
            locale: "en",
            eventID: nil
        )
        try expect(
            try store.pending(for: "unlisted", language: "en", locale: "en") == pending,
            "Durable pending job did not round-trip."
        )
        let refreshedPending = EntryPendingResolution(
            jobID: pending.jobID,
            canonicalKeyHash: pending.canonicalKeyHash,
            jobKind: pending.jobKind,
            nextCheckAt: fixedNow.addingTimeInterval(90),
            checkCount: 3
        )
        try store.storePending(
            refreshedPending,
            normalizedForm: "unlisted",
            language: "en",
            locale: "en",
            eventID: nil
        )
        try expect(
            try store.pending(for: "unlisted", language: "en", locale: "en")
                == refreshedPending,
            "An identical pending job did not refresh its schedule monotonically."
        )
        let staleSchedule = EntryPendingResolution(
            jobID: pending.jobID,
            canonicalKeyHash: pending.canonicalKeyHash,
            jobKind: pending.jobKind,
            nextCheckAt: fixedNow.addingTimeInterval(10),
            checkCount: 1
        )
        try store.storePending(
            staleSchedule,
            normalizedForm: "unlisted",
            language: "en",
            locale: "en",
            eventID: nil
        )
        try expect(
            try store.pending(for: "unlisted", language: "en", locale: "en")
                == refreshedPending,
            "A stale pending response moved its schedule or check count backwards."
        )

        let otherEventID = try require(
            UUID(uuidString: "7619923d-d3cd-4c47-a118-b03f5889a46d"),
            "Fixed pending-job UUID is invalid."
        )

        let changedHash = EntryPendingResolution(
            jobID: pending.jobID,
            canonicalKeyHash: String(repeating: "b", count: 64),
            jobKind: pending.jobKind,
            nextCheckAt: refreshedPending.nextCheckAt,
            checkCount: refreshedPending.checkCount
        )
        try expectPendingJobIdentityConflict("A pending job rebound its canonical hash.") {
            try store.storePending(
                changedHash, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: nil
            )
        }
        let changedKind = EntryPendingResolution(
            jobID: pending.jobID,
            canonicalKeyHash: pending.canonicalKeyHash,
            jobKind: "replaceExplanation",
            nextCheckAt: refreshedPending.nextCheckAt,
            checkCount: refreshedPending.checkCount
        )
        try expectPendingJobIdentityConflict("A pending job rebound its operation.") {
            try store.storePending(
                changedKind, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: otherEventID
            )
        }
        try expectPendingJobIdentityConflict("A pending job rebound its normalized form.") {
            try store.storePending(
                refreshedPending, normalizedForm: "another",
                language: "en", locale: "en", eventID: nil
            )
        }
        try expectPendingJobIdentityConflict("A pending job rebound its language.") {
            try store.storePending(
                refreshedPending, normalizedForm: "unlisted",
                language: "fr", locale: "en", eventID: nil
            )
        }
        try expectPendingJobIdentityConflict("A pending job rebound its locale.") {
            try store.storePending(
                refreshedPending, normalizedForm: "unlisted",
                language: "en", locale: "en-GB", eventID: nil
            )
        }
        try expectInvalidStoredRecord("A resolve job was linked to a feedback event.") {
            try store.storePending(
                refreshedPending, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: otherEventID
            )
        }
        try expectInvalidStoredRecord("A replacement job omitted its feedback event.") {
            try store.storePending(
                changedKind, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: nil
            )
        }

        let replacementEventID = try require(
            UUID(uuidString: "2d608f88-ca66-4f64-a531-f25772247239"),
            "Fixed replacement-job UUID is invalid."
        )
        let replacementPending = EntryPendingResolution(
            jobID: "job-replacement-binding-opaque",
            canonicalKeyHash: String(repeating: "f", count: 64),
            jobKind: "replaceExplanation",
            nextCheckAt: fixedNow.addingTimeInterval(45),
            checkCount: 0
        )
        try store.storePending(
            replacementPending,
            normalizedForm: "unlisted",
            language: "en",
            locale: "en",
            eventID: replacementEventID
        )
        try expect(
            try store.pending(eventID: replacementEventID) == replacementPending,
            "A legal replacement job/event binding did not round-trip."
        )
        try expectPendingJobIdentityConflict("A replacement job rebound its feedback event.") {
            try store.storePending(
                replacementPending,
                normalizedForm: "unlisted",
                language: "en",
                locale: "en",
                eventID: otherEventID
            )
        }
        try expect(
            try store.pending(for: "unlisted", language: "en", locale: "en")
                == refreshedPending,
            "Rejected identity rebindings changed the original pending job."
        )
        let invalidHash = EntryPendingResolution(
            jobID: "job-invalid-hash-opaque",
            canonicalKeyHash: "not-a-sha256",
            jobKind: "resolveEntry",
            nextCheckAt: fixedNow.addingTimeInterval(30),
            checkCount: 0
        )
        try expectInvalidStoredRecord("A malformed pending-job hash was accepted.") {
            try store.storePending(
                invalidHash, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: nil
            )
        }
        let invalidKind = EntryPendingResolution(
            jobID: "job-invalid-kind-opaque",
            canonicalKeyHash: String(repeating: "e", count: 64),
            jobKind: "other",
            nextCheckAt: fixedNow.addingTimeInterval(30),
            checkCount: 0
        )
        try expectInvalidStoredRecord("An unknown pending-job operation was accepted.") {
            try store.storePending(
                invalidKind, normalizedForm: "unlisted",
                language: "en", locale: "en", eventID: nil
            )
        }
        try verifySchemaJobKindEventGuard(databaseURL: databaseURL, now: fixedNow)
        try verifyLegacySchemaJobKindEventGuard(
            databaseURL: directory.appendingPathComponent("legacy-job-guard.sqlite"),
            now: fixedNow
        )
        try store.markJobFinished(pending.jobID)
        try store.storePending(
            refreshedPending,
            normalizedForm: "unlisted",
            language: "en",
            locale: "en",
            eventID: nil
        )
        try expect(
            try store.pending(for: "unlisted", language: "en", locale: "en") == nil,
            "A stale pending response resurrected a completed job."
        )
        try verifyClearMissResolveOnly(store: store, now: fixedNow)
        let negative = EntryNegativeResolution(
            reason: "notFound",
            expiresAt: fixedNow.addingTimeInterval(3_600)
        )
        try store.storeNegative(
            negative,
            normalizedForm: "notaword",
            language: "en",
            locale: "en"
        )
        try expect(
            try store.cachedMiss(for: "notaword", language: "en", locale: "en")
                == .negative(negative),
            "Finite negative result did not round-trip."
        )

        let usage = sawRevision2.usages[0]
        let eventID = try require(
            UUID(uuidString: "4d5be27f-f83d-45c8-926b-ed71c720db25"),
            "Fixed UUID is invalid."
        )
        let feedback = EntryFeedbackEvent(
            eventID: eventID,
            entryID: sawRevision2.entryID,
            entryUsageID: usage.entryUsageID,
            explanationID: usage.explanationID,
            normalizedForm: sawRevision2.normalizedForm,
            language: sawRevision2.language,
            locale: sawRevision2.locale,
            rating: .notHelpful,
            component: .example,
            requestReplacement: true,
            contentVersion: sawRevision2.contentVersion,
            baseContentVersion: sawRevision2.contentVersion,
            baseEntryRevision: sawRevision2.entryRevision,
            schemaVersion: usage.schemaVersion,
            lessonContractVersion: usage.lessonContractVersion,
            validatorVersion: usage.validatorVersion,
            reviewPolicyVersion: usage.reviewPolicyVersion,
            excludedExplanationIDs: [usage.explanationID],
            createdAt: fixedNow
        )
        try expect(
            try store.enqueueFeedback(feedback, baseEntry: sawRevision2),
            "Feedback was not queued."
        )
        try expect(
            try !store.enqueueFeedback(feedback, baseEntry: sawRevision2),
            "A byte-identical event replay should be an idempotent no-op."
        )
        let differentDisplayedBase = try EntryTestFixtures.sawEntry(
            surfaceForm: "Saw",
            revision: 2,
            coverageRevision: 1,
            contentVersion: "server-saw-v2"
        )
        try expectFeedbackIdempotencyConflict(
            "The same event UUID was accepted with a different displayed Entry."
        ) {
            _ = try store.enqueueFeedback(feedback, baseEntry: differentDisplayedBase)
        }

        store = try EntryOverlayStore(databaseURL: databaseURL, now: { fixedNow })
        let queued = try store.dequeuePendingFeedback(limit: 5)
        try expect(
            queued.count == 1
                && queued[0].event.attemptCount == 1
                && queued[0].baseEntry == sawRevision2,
            "Feedback outbox was not durable across store instances."
        )
        try store.markFeedbackSent(eventID: eventID)
        try store.markReplacementComplete(eventID: eventID)
        try expect(
            try store.dequeuePendingFeedback(limit: 5).isEmpty,
            "Completed feedback/replacement work remained pending."
        )

        print("EntryOverlayStore harness passed")
    }

    private static func verifyConcurrentCodecIsolation(
        store: EntryOverlayStore,
        entry: ResolvedWordEntry
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    _ = try store.installCompleteEntry(entry)
                    let loaded = try store.entry(
                        for: entry.encounteredSurfaceForm,
                        language: entry.language,
                        locale: entry.locale
                    )
                    try expect(
                        loaded?.entryID == entry.entryID
                            && loaded?.usages.count == entry.usages.count,
                        "A concurrent overlay JSON round trip was incomplete."
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private static func verifyCoverageRevisionContract(
        databaseURL: URL,
        now: Date
    ) throws {
        let store = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
        let base = try EntryTestFixtures.sawEntry()
        try expect(try store.installCompleteEntry(base), "Coverage fixture base was not stored.")

        let unchangedProjectionAdvance = try EntryTestFixtures.sawEntry(
            revision: 2,
            coverageRevision: 2,
            contentVersion: "server-saw-unchanged-coverage-v2"
        )
        try expectInvalidEntry(
            "coverageRevision advanced although the reviewed Usage projection did not change."
        ) {
            _ = try store.installCompleteEntry(unchangedProjectionAdvance)
        }

        func narrowed(
            revision: Int,
            coverageRevision: Int,
            contentVersion: String,
            explanation: String = "Noticed or watched something at an earlier time."
        ) throws -> ResolvedWordEntry {
            try EntryTestFixtures.entry(
                surfaceForm: "saw",
                entryID: "entry-saw-opaque",
                revision: revision,
                coverageRevision: coverageRevision,
                contentVersion: contentVersion,
                baseContentVersion: "catalog-v1",
                trust: .serverReviewed,
                coverage: .serverReviewedComplete,
                specs: [EntryTestFixtures.UsageSpec(
                    id: "usage-seeing-opaque",
                    label: "earlier seeing or meeting",
                    partOfSpeech: "verb",
                    relation: "past form of see",
                    ipa: "sɔ",
                    explanation: explanation,
                    example: "I saw a fox cross the road on my way home.",
                    synonyms: ["noticed", "watched"],
                    core: true
                )]
            )
        }

        let changedWithoutCoverageAdvance = try narrowed(
            revision: 2,
            coverageRevision: 1,
            contentVersion: "server-saw-narrowed-invalid-v2"
        )
        try expectInvalidEntry(
            "A changed reviewed Usage projection reused coverageRevision."
        ) {
            _ = try store.installCompleteEntry(changedWithoutCoverageAdvance)
        }

        let changedWithCoverageAdvance = try narrowed(
            revision: 2,
            coverageRevision: 2,
            contentVersion: "server-saw-narrowed-v2"
        )
        try expect(
            try store.installCompleteEntry(changedWithCoverageAdvance),
            "A changed projection with advancing Entry and coverage revisions was rejected."
        )

        let coverageRegression = try narrowed(
            revision: 3,
            coverageRevision: 1,
            contentVersion: "server-saw-coverage-regression-v3"
        )
        try expectInvalidEntry("A newer Entry regressed coverageRevision.") {
            _ = try store.installCompleteEntry(coverageRegression)
        }

        let coverageOnlyAdvance = try narrowed(
            revision: 3,
            coverageRevision: 3,
            contentVersion: "server-saw-coverage-only-v3"
        )
        try expectInvalidEntry(
            "coverageRevision advanced without a projection change after narrowing."
        ) {
            _ = try store.installCompleteEntry(coverageOnlyAdvance)
        }

        let contentOnlyAdvance = try narrowed(
            revision: 3,
            coverageRevision: 2,
            contentVersion: "server-saw-content-v3",
            explanation: "Noticed, watched, or met someone at an earlier time."
        )
        try expect(
            try store.installCompleteEntry(contentOnlyAdvance),
            "A content-only Entry revision incorrectly required a coverage revision."
        )
    }

    private static func verifyCanonicalEntryKeys(
        store: EntryOverlayStore,
        directory: URL,
        now: Date
    ) throws {
        let noncanonicalLanguage = try EntryTestFixtures.sawEntry(language: "EN")
        try expectInvalidEntry("The overlay stored a noncanonical language tag.") {
            _ = try store.installCompleteEntry(noncanonicalLanguage)
        }
        let unsupportedLanguage = try EntryTestFixtures.sawEntry(language: "fr")
        try expectInvalidEntry("The overlay stored an unsupported language tag.") {
            _ = try store.installCompleteEntry(unsupportedLanguage)
        }

        let invalidSyntax = [
            "e--US", "e-US", "en-123456789", "en_US", "é-US", "abcdefghi",
        ]
        for locale in invalidSyntax {
            try expect(
                !EntryContractValidator.hasValidLocaleSyntax(locale),
                "The shared locale grammar accepted \(locale)."
            )
            let invalid = try EntryTestFixtures.sawEntry(locale: locale)
            try expectInvalidEntry("The overlay stored invalid locale \(locale).") {
                _ = try store.installCompleteEntry(invalid)
            }
            try expect(
                try store.entry(for: "saw", language: "en", locale: locale) == nil,
                "Invalid lookup locale \(locale) fell through to an English Entry."
            )
        }

        let validButNoncanonical = ["EN", "en-us", "zh-HANS-cn"]
        for locale in validButNoncanonical {
            try expect(
                EntryContractValidator.hasValidLocaleSyntax(locale)
                    && !EntryContractValidator.isCanonicalLocale(locale),
                "The canonical-locale check did not reject \(locale)."
            )
            let invalid = try EntryTestFixtures.sawEntry(locale: locale)
            try expectInvalidEntry("The overlay stored noncanonical locale \(locale).") {
                _ = try store.installCompleteEntry(invalid)
            }
        }

        let validCanonical = [
            "en", "en-US", "zh-hans-CN", "de-CH-1901", "abc-12345678",
        ]
        for (index, locale) in validCanonical.enumerated() {
            try expect(
                EntryContractValidator.hasValidLocaleSyntax(locale)
                    && EntryContractValidator.isCanonicalLocale(locale),
                "The shared locale validator rejected allowed tag \(locale)."
            )
            let localeStore = try EntryOverlayStore(
                databaseURL: directory.appendingPathComponent(
                    "valid-locale-\(index).sqlite"
                ),
                now: { now }
            )
            let entry = try EntryTestFixtures.sawEntry(locale: locale)
            try expect(
                try localeStore.installCompleteEntry(entry),
                "The overlay rejected allowed canonical locale \(locale)."
            )
            try expect(
                try localeStore.entry(
                    for: "saw",
                    language: "en",
                    locale: locale
                ) != nil,
                "The overlay could not read allowed locale \(locale)."
            )
        }

        func pronunciationEntry(
            _ pronunciationLocale: String,
            entryID: String
        ) throws -> ResolvedWordEntry {
            try EntryTestFixtures.entry(
                surfaceForm: entryID,
                entryID: entryID,
                revision: 1,
                coverageRevision: 1,
                contentVersion: "server-\(entryID)-v1",
                baseContentVersion: "catalog-v1",
                trust: .serverReviewed,
                coverage: .serverReviewedComplete,
                specs: [EntryTestFixtures.UsageSpec(
                    id: "usage-\(entryID)",
                    label: "pronunciation locale fixture",
                    partOfSpeech: "noun",
                    relation: nil,
                    ipa: "tɛst",
                    pronunciationLocale: pronunciationLocale,
                    explanation: "A fixture for pronunciation locale validation.",
                    example: "The pronunciation carries its own locale tag.",
                    synonyms: [],
                    core: true
                )]
            )
        }
        let invalidPronunciation = try pronunciationEntry(
            "e--US",
            entryID: "pronunciation-invalid"
        )
        try expectInvalidEntry("The overlay accepted an invalid pronunciation locale.") {
            _ = try store.installCompleteEntry(invalidPronunciation)
        }
        let pronunciationStore = try EntryOverlayStore(
            databaseURL: directory.appendingPathComponent(
                "valid-pronunciation-locale.sqlite"
            ),
            now: { now }
        )
        let regexValidPronunciation = try pronunciationEntry(
            "EN-us",
            entryID: "pronunciation-valid"
        )
        try expect(
            try pronunciationStore.installCompleteEntry(regexValidPronunciation),
            "The overlay rejected a pronunciation locale allowed by server grammar."
        )
    }

    private static func verifySchemaJobKindEventGuard(
        databaseURL: URL,
        now: Date
    ) throws {
        let database = try SQLiteWritableDatabase(url: databaseURL)
        let timestamp = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        func insert(kind: String, eventID: String?, suffix: String) throws {
            try database.execute(
                """
                INSERT INTO server_job (
                    job_id, canonical_key_hash, job_kind, language_tag,
                    normalized_form, locale, next_check_at_ms, check_count,
                    event_id, state, updated_at_ms
                ) VALUES (?, ?, ?, 'en', 'schema-guard', 'en', ?, 0, ?, 'pending', ?)
                """,
                bindings: [
                    .text("job-schema-\(suffix)"),
                    .text(String(repeating: "1", count: 64)),
                    .text(kind),
                    .integer(timestamp),
                    eventID.map(SQLiteWritableBinding.text) ?? .null,
                    .integer(timestamp),
                ]
            )
        }
        try expectSQLiteConstraint("SQLite accepted an unknown server-job kind.") {
            try insert(kind: "other", eventID: nil, suffix: "kind")
        }
        try expectSQLiteConstraint("SQLite accepted a resolve job with an event.") {
            try insert(
                kind: "resolveEntry",
                eventID: "7619923d-d3cd-4c47-a118-b03f5889a46d",
                suffix: "resolve-event"
            )
        }
        try expectSQLiteConstraint("SQLite accepted a replacement job without an event.") {
            try insert(kind: "replaceExplanation", eventID: nil, suffix: "replace-no-event")
        }
    }

    private static func verifyLegacySchemaJobKindEventGuard(
        databaseURL: URL,
        now: Date
    ) throws {
        do {
            let legacy = try SQLiteWritableDatabase(url: databaseURL)
            try legacy.execute("PRAGMA application_id = \(EntryOverlayStore.applicationID)")
            try legacy.execute("PRAGMA user_version = \(EntryOverlayStore.schemaVersion)")
            try legacy.executeScript(
                """
                CREATE TABLE server_job (
                    job_id TEXT PRIMARY KEY NOT NULL,
                    canonical_key_hash TEXT NOT NULL,
                    job_kind TEXT NOT NULL,
                    language_tag TEXT NOT NULL,
                    normalized_form TEXT NOT NULL,
                    locale TEXT NOT NULL,
                    next_check_at_ms INTEGER NOT NULL,
                    check_count INTEGER NOT NULL,
                    event_id TEXT,
                    state TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID;
                """
            )
        }

        // Opening a pre-existing schema-v1 cache installs idempotent guards;
        // it does not require rewriting the table or changing user_version.
        _ = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
        let legacy = try SQLiteWritableDatabase(url: databaseURL)
        let timestamp = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        try legacy.execute(
            """
            INSERT INTO server_job (
                job_id, canonical_key_hash, job_kind, language_tag,
                normalized_form, locale, next_check_at_ms, check_count,
                event_id, state, updated_at_ms
            ) VALUES (
                'job-legacy-valid', ?, 'resolveEntry', 'en',
                'legacy-guard', 'en', ?, 0, NULL, 'pending', ?
            )
            """,
            bindings: [
                .text(String(repeating: "4", count: 64)),
                .integer(timestamp),
                .integer(timestamp),
            ]
        )
        try expectSQLiteConstraint(
            "A migrated schema-v1 cache allowed a valid resolve job to gain an event."
        ) {
            try legacy.execute(
                "UPDATE server_job SET event_id = ? WHERE job_id = 'job-legacy-valid'",
                bindings: [.text("7619923d-d3cd-4c47-a118-b03f5889a46d")]
            )
        }
        try expectSQLiteConstraint(
            "A migrated schema-v1 cache accepted an unknown job kind."
        ) {
            try legacy.execute(
                """
                INSERT INTO server_job (
                    job_id, canonical_key_hash, job_kind, language_tag,
                    normalized_form, locale, next_check_at_ms, check_count,
                    event_id, state, updated_at_ms
                ) VALUES (
                    'job-legacy-invalid', ?, 'other', 'en',
                    'legacy-guard', 'en', ?, 0, NULL, 'pending', ?
                )
                """,
                bindings: [
                    .text(String(repeating: "5", count: 64)),
                    .integer(timestamp),
                    .integer(timestamp),
                ]
            )
        }
    }

    private static func verifyClearMissResolveOnly(
        store: EntryOverlayStore,
        now: Date
    ) throws {
        let form = "clearmiss"
        let resolveJob = EntryPendingResolution(
            jobID: "job-clear-resolve-opaque",
            canonicalKeyHash: String(repeating: "2", count: 64),
            jobKind: "resolveEntry",
            nextCheckAt: now.addingTimeInterval(30),
            checkCount: 0
        )
        let replacementJob = EntryPendingResolution(
            jobID: "job-clear-replacement-opaque",
            canonicalKeyHash: String(repeating: "3", count: 64),
            jobKind: "replaceExplanation",
            nextCheckAt: now.addingTimeInterval(30),
            checkCount: 0
        )
        let eventID = try require(
            UUID(uuidString: "1adb6c4d-c38d-4a92-aabe-959397032c74"),
            "Clear-miss event UUID is invalid."
        )
        try store.storeNegative(
            EntryNegativeResolution(
                reason: "notFound",
                expiresAt: now.addingTimeInterval(3_600)
            ),
            normalizedForm: form,
            language: "en",
            locale: "en"
        )
        try store.storePending(
            resolveJob,
            normalizedForm: form,
            language: "en",
            locale: "en",
            eventID: nil
        )
        try store.storePending(
            replacementJob,
            normalizedForm: form,
            language: "en",
            locale: "en",
            eventID: eventID
        )
        let entry = try EntryTestFixtures.entry(
            surfaceForm: form,
            entryID: "entry-clear-miss-opaque",
            revision: 1,
            coverageRevision: 1,
            contentVersion: "server-clear-miss-v1",
            baseContentVersion: "catalog-v1",
            trust: .serverReviewed,
            coverage: .serverReviewedComplete,
            specs: [EntryTestFixtures.UsageSpec(
                id: "usage-clear-miss-opaque",
                label: "cache cleanup fixture",
                partOfSpeech: "noun",
                relation: nil,
                ipa: "klɪr",
                explanation: "A fixture used to verify resolved lookup cleanup.",
                example: "The fixture clears only the completed lookup job.",
                synonyms: [],
                core: true
            )]
        )
        try expect(try store.installCompleteEntry(entry), "Clear-miss Entry was not stored.")
        try expect(
            try store.cachedMiss(for: form, language: "en", locale: "en") == nil,
            "Installing a resolved Entry retained its stale negative result."
        )
        try expect(
            try store.pending(for: form, language: "en", locale: "en") == nil,
            "Installing a resolved Entry retained its resolve job."
        )
        try expect(
            try store.pending(eventID: eventID) == replacementJob,
            "Installing a resolved Entry incorrectly finished an unrelated replacement job."
        )
    }

	private static func verifyReleaseSidecarMaterialization(
		databaseURL: URL,
		now: Date
	) throws {
		let store = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
		let release = try EntryTestFixtures.sawEntry(
			contentVersion: "catalog-v1",
			baseContentVersion: "catalog-v1",
			trust: .releaseReviewed,
			coverage: .releaseReviewedComplete
		)
		let replacement = try EntryTestFixtures.replacement(
			for: release,
			usageID: "usage-tool-opaque",
			explanation: "A toothed hand or powered tool used to cut firm material.",
			example: "She used the saw to trim the board."
		)
		let skippedRevision = EntryLessonReplacement(
			entryID: replacement.entryID,
			entryUsageID: replacement.entryUsageID,
			locale: replacement.locale,
			baseEntryRevision: replacement.baseEntryRevision,
			baseExplanationID: replacement.baseExplanationID,
			baseContentVersion: replacement.baseContentVersion,
			explanationID: replacement.explanationID,
			contentHash: replacement.contentHash,
			schemaVersion: replacement.schemaVersion,
			lessonContractVersion: replacement.lessonContractVersion,
			validatorVersion: replacement.validatorVersion,
			reviewPolicyVersion: replacement.reviewPolicyVersion,
			contentRevision: replacement.contentRevision + 1,
			trustState: replacement.trustState,
			content: replacement.content
		)
		do {
			try store.installReplacement(skippedRevision, against: release)
			throw EntryOverlayHarnessFailure.failed(
				"A replacement skipped its immediate parent content revision."
			)
		} catch let error as EntryOverlayStoreError {
			guard case .invalidReplacement = error else { throw error }
		}
		try store.installReplacement(replacement, against: release)
		let effective = try store.applyingSelectedReplacements(to: release)
		try expect(
			effective.coverageState == .releaseReviewedComplete
				&& effective.usages[0].trustState == .releaseReviewed
				&& effective.usages[1].trustState == .serverReviewed,
			"A reviewed sidecar was not materialized over its release snapshot."
		)
		do {
			try EntryContractValidator.validate(
				effective,
				expectedSurfaceForm: effective.encounteredSurfaceForm
			)
			throw EntryOverlayHarnessFailure.failed(
				"A materialized mixed view became legal as a public Entry."
			)
		} catch is EntryCatalogStoreError {
			// Expected: only the explicit materialized-view boundary accepts it.
		}
		try EntryContractValidator.validateMaterializedView(
			effective,
			expectedSurfaceForm: effective.encounteredSurfaceForm
		)
		let event = EntryFeedbackEvent(
			eventID: UUID(uuidString: "3f06d0d0-e10e-4cc3-9aef-ab0483509edf")!,
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
			excludedExplanationIDs: [replacement.explanationID],
			createdAt: now
		)
		try expect(
			try store.enqueueFeedback(event, baseEntry: effective),
			"Feedback on a displayed release sidecar was not durably queued."
		)
		let queued = try store.dequeuePendingFeedback(limit: 1)
		try expect(
			queued.first?.baseEntry == effective,
			"The exact materialized feedback view did not survive the outbox."
		)
	}

	private static func verifyFeedbackQuarantine(
		databaseURL: URL,
		now: Date
	) throws {
		let store = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
		let entry = try EntryTestFixtures.sawEntry()
		let usage = entry.usages[0]
		let event = EntryFeedbackEvent(
			eventID: UUID(uuidString: "8626d76b-3dcc-4184-a0fc-4c2c5d9fc56a")!,
			entryID: entry.entryID,
			entryUsageID: usage.entryUsageID,
			explanationID: usage.explanationID,
			normalizedForm: entry.normalizedForm,
			language: entry.language,
			locale: entry.locale,
			rating: .helpful,
			component: .wholeLesson,
			requestReplacement: false,
			contentVersion: entry.contentVersion,
			appVersion: "test",
			baseContentVersion: entry.contentVersion,
			baseEntryRevision: entry.entryRevision,
			schemaVersion: usage.schemaVersion,
			lessonContractVersion: usage.lessonContractVersion,
			validatorVersion: usage.validatorVersion,
			reviewPolicyVersion: usage.reviewPolicyVersion,
			excludedExplanationIDs: [],
			createdAt: now
		)
		_ = try store.enqueueFeedback(event, baseEntry: entry)
		let raw = try SQLiteWritableDatabase(url: databaseURL)
		try raw.execute(
			"""
			INSERT INTO entry_feedback_outbox (
			    event_id, payload_json, created_at_ms, attempt_count,
			    feedback_sent_at_ms, replacement_completed_at_ms
			) VALUES ('corrupt-feedback-envelope', '{', 0, 0, NULL, NULL)
			"""
		)
		let pending = try store.dequeuePendingFeedback(limit: 10)
		try expect(
			pending.count == 1 && pending[0].event.eventID == event.eventID,
			"A corrupt feedback envelope blocked a later healthy event."
		)
		let quarantined = try raw.queryOne(
			"SELECT COUNT(*) FROM feedback_outbox_quarantine WHERE event_id = 'corrupt-feedback-envelope'"
		) { try $0.integer(at: 0) } ?? 0
		let stillPending = try raw.queryOne(
			"SELECT COUNT(*) FROM entry_feedback_outbox WHERE event_id = 'corrupt-feedback-envelope'"
		) { try $0.integer(at: 0) } ?? 0
		try expect(
			quarantined == 1 && stillPending == 0,
			"A corrupt feedback envelope was not durably quarantined."
		)
	}

	private static func verifyForeignKeyIntegrityGate(
		databaseURL: URL,
		now: Date
	) throws {
		_ = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
		let raw = try SQLiteWritableDatabase(url: databaseURL)
		try raw.execute("PRAGMA foreign_keys = OFF")
		try raw.execute(
			"""
			INSERT INTO replacement_selection (
			    entry_id, entry_usage_id, locale, explanation_id
			) VALUES ('entry-orphan', 'usage-orphan', 'en', 'exp-orphan')
			"""
		)
		do {
			_ = try EntryOverlayStore(databaseURL: databaseURL, now: { now })
			throw EntryOverlayHarnessFailure.failed(
				"Overlay startup accepted a foreign-key-corrupt cache."
			)
		} catch let error as EntryOverlayStoreError {
			guard case .invalidStoredRecord = error else { throw error }
		}
	}

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else { throw EntryOverlayHarnessFailure.failed(message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw EntryOverlayHarnessFailure.failed(message) }
        return value
    }

    private static func expectImmutableEntryConflict(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as EntryOverlayStoreError {
            if case .immutableEntryConflict = error { return }
            throw EntryOverlayHarnessFailure.failed(
                "\(message) Unexpected error: \(error.localizedDescription)"
            )
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }

    private static func expectInvalidEntry(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as EntryOverlayStoreError {
            if case .invalidEntry = error { return }
            throw EntryOverlayHarnessFailure.failed(
                "\(message) Unexpected error: \(error.localizedDescription)"
            )
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }

    private static func expectFeedbackIdempotencyConflict(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as EntryOverlayStoreError {
            if case .feedbackIdempotencyConflict = error { return }
            throw EntryOverlayHarnessFailure.failed(
                "\(message) Unexpected error: \(error.localizedDescription)"
            )
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }

    private static func expectSQLiteConstraint(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch is SQLiteWritableDatabaseError {
            return
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }

    private static func expectPendingJobIdentityConflict(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as EntryOverlayStoreError {
            if case .pendingJobIdentityConflict = error { return }
            throw EntryOverlayHarnessFailure.failed(
                "\(message) Unexpected error: \(error.localizedDescription)"
            )
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }

    private static func expectInvalidStoredRecord(
        _ message: String,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch let error as EntryOverlayStoreError {
            if case .invalidStoredRecord = error { return }
            throw EntryOverlayHarnessFailure.failed(
                "\(message) Unexpected error: \(error.localizedDescription)"
            )
        }
        throw EntryOverlayHarnessFailure.failed(message)
    }
}
