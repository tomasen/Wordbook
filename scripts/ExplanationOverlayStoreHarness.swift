import Foundation

enum OverlayHarnessFailure: LocalizedError {
    case failedAssertion(String)
    case sqliteToolFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .failedAssertion(let message):
            return message
        case .sqliteToolFailed(let status, let output):
            return "sqlite3 failed with status \(status): \(output)"
        }
    }
}

@main
struct ExplanationOverlayStoreHarness {
    static func main() throws {
        let fixtureURL = try fixtureURLFromArguments()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordbookOverlayStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseURL = temporaryDirectory.appendingPathComponent("base.sqlite")
        let overlayURL = temporaryDirectory
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("wordbook-overlay.sqlite")
        try materializeDatabase(from: fixtureURL, at: baseURL)

        let baseBytesBefore = try Data(contentsOf: baseURL)
        let baseStore = try OfflineExplanationStore(databaseURL: baseURL)
        let baseWent = try require(
            try baseStore.explanation(for: "went"),
            "The immutable base fixture should contain went."
        )

        var rejectedBaseAsOverlay = false
        do {
            _ = try ExplanationOverlayStore(databaseURL: baseURL)
        } catch ExplanationOverlayStoreError.unsupportedApplicationID {
            rejectedBaseAsOverlay = true
        }
        try expect(
            rejectedBaseAsOverlay,
            "The writable overlay must reject the immutable base database URL."
        )
        try expect(
            try Data(contentsOf: baseURL) == baseBytesBefore,
            "Rejecting a base database URL must happen before any writable SQLite pragma."
        )

        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000.125)
        var overlay = try ExplanationOverlayStore(
            databaseURL: overlayURL,
            now: { fixedDate }
        )

        let firstVariant = explanationRecord(
            explanationID: "server:went:v1",
            contentHash: "hash-went-v1",
            meaning: "moved or traveled from one place to another in the past",
            memoryAid: ["Went is the past form you use after the journey is over."],
            morphology: .combined(["past", "irregular"])
        )
        try overlay.storeValidatedServerExplanation(firstVariant)

        let firstResult = try require(
            try overlay.explanation(for: "  WENT\n"),
            "The selected overlay explanation should resolve by normalized form."
        )
        try expect(firstResult.explanationID == firstVariant.explanationID, "The first variant was not selected.")
        try expect(
            firstResult.morphology == .combined(["past", "irregular"]),
            "Exact morphology metadata did not survive the overlay boundary."
        )
        try expect(
            firstResult.explanation == firstVariant.explanation,
            "The learner-facing explanation did not survive persistence."
        )

        let secondVariant = explanationRecord(
            explanationID: "server:went:v2",
            contentHash: "hash-went-v2",
            meaning: "the past form of go, used when someone or something already moved away",
            memoryAid: ["Think: go now, but went when the trip has already happened."],
            morphology: .combined(["past", "irregular"])
        )
        try overlay.storeValidatedServerExplanation(
            secondVariant,
            selectForForm: false
        )
        try expect(
            try overlay.explanation(for: "went")?.explanationID == firstVariant.explanationID,
            "Saving an alternative must not silently change the selected variant."
        )

        try overlay.selectVariant(
            explanationID: secondVariant.explanationID,
            forForm: "went",
            senseID: secondVariant.senseID
        )
        try expect(
            try overlay.explanation(for: "went")?.explanationID == secondVariant.explanationID,
            "Explicit selection did not switch to the replacement variant."
        )

        // Reopening runs the migration path again and proves state is durable.
        overlay = try ExplanationOverlayStore(databaseURL: overlayURL, now: { fixedDate })
        try expect(
            try overlay.explanation(for: "went")?.explanationID == secondVariant.explanationID,
            "The selected variant did not persist across store instances."
        )

        let database = try SQLiteWritableDatabase(url: overlayURL)
        let schemaVersion = try database.queryOne("PRAGMA user_version") { row in
            try row.integer(at: 0)
        }
        try expect(
            schemaVersion == ExplanationOverlayStore.schemaVersion,
            "The overlay migration did not set user_version."
        )

        let eventID = try require(
            UUID(uuidString: "4d5be27f-f83d-45c8-926b-ed71c720db25"),
            "The fixed harness UUID is invalid."
        )
        let feedback = ExplanationFeedbackEvent(
            eventID: eventID,
            explanationID: secondVariant.explanationID,
            normalizedForm: "WENT",
            senseID: secondVariant.senseID,
            rating: .dislike,
            component: .memoryAid,
            requestReplacement: true,
            createdAt: fixedDate
        )
        try expect(try overlay.enqueueFeedback(feedback), "The first feedback enqueue should insert a row.")
        let samePayloadWithNewLocalTimestamp = ExplanationFeedbackEvent(
            eventID: eventID,
            explanationID: secondVariant.explanationID,
            normalizedForm: "went",
            senseID: secondVariant.senseID,
            rating: .dislike,
            component: .memoryAid,
            requestReplacement: true,
            createdAt: fixedDate.addingTimeInterval(30)
        )
        try expect(
            try !overlay.enqueueFeedback(samePayloadWithNewLocalTimestamp),
            "Repeating the same event UUID and payload should be an idempotent no-op."
        )

        var sawIdempotencyConflict = false
        do {
            let conflictingFeedback = ExplanationFeedbackEvent(
                eventID: eventID,
                explanationID: secondVariant.explanationID,
                normalizedForm: "went",
                senseID: secondVariant.senseID,
                rating: .like,
                createdAt: fixedDate
            )
            _ = try overlay.enqueueFeedback(conflictingFeedback)
        } catch ExplanationOverlayStoreError.feedbackIdempotencyConflict(let conflictingID) {
            sawIdempotencyConflict = conflictingID == eventID
        }
        try expect(
            sawIdempotencyConflict,
            "Reusing an event UUID for a different payload should be rejected."
        )

        let firstDelivery = try overlay.dequeuePendingFeedback(limit: 10)
        try expect(firstDelivery.count == 1, "The pending feedback event was not dequeued.")
        try expect(firstDelivery[0].eventID == eventID, "The wrong feedback event was dequeued.")
        try expect(firstDelivery[0].attemptCount == 1, "The first delivery attempt was not recorded.")
        try expect(
            firstDelivery[0].normalizedForm == "went",
            "Feedback should preserve the canonical normalized form."
        )

        let retryDelivery = try overlay.dequeuePendingFeedback(limit: 10)
        try expect(
            retryDelivery.first?.attemptCount == 2,
            "An unacknowledged event should remain pending for a later retry."
        )
        try expect(
            try overlay.markFeedbackSent(eventID: eventID, sentAt: fixedDate),
            "The first delivery acknowledgement should mark the event sent."
        )
        try expect(
            try !overlay.markFeedbackSent(eventID: eventID, sentAt: fixedDate),
            "Acknowledging an already-sent event should be an idempotent no-op."
        )
        try expect(
            try overlay.dequeuePendingFeedback(limit: 10).isEmpty,
            "A sent event should no longer be returned by the outbox."
        )

        let baseBytesAfter = try Data(contentsOf: baseURL)
        let baseWentAfter = try require(
            try baseStore.explanation(for: "went"),
            "The immutable base explanation disappeared."
        )
        try expect(baseBytesAfter == baseBytesBefore, "Overlay operations mutated the base database file.")
        try expect(
            baseWentAfter == baseWent,
            "Overlay selection leaked into the immutable base content store."
        )
        try expect(
            baseWentAfter.explanationID != secondVariant.explanationID,
            "The base store unexpectedly returned an overlay revision."
        )

        print("ExplanationOverlayStore harness passed")
    }

    private static func explanationRecord(
        explanationID: String,
        contentHash: String,
        meaning: String,
        memoryAid: [String],
        morphology: OfflineWordFormMorphology
    ) -> OfflineVocabularyExplanation {
        OfflineVocabularyExplanation(
            normalizedForm: "went",
            displayForm: "went",
            morphology: morphology,
            senseID: "wn:go:v:1",
            lemma: "go",
            explanationID: explanationID,
            contentHash: contentHash,
            schemaVersion: 1,
            explanation: VocabularyExplanation(
                partOfSpeech: "v",
                meaning: meaning,
                memoryTechnique: .contrast,
                memoryAid: memoryAid,
                example: "She went home before sunset.",
                synonyms: ["traveled", "moved"]
            )
        )
    }

    private static func fixtureURLFromArguments() throws -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1])
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/Fixtures/OfflineExplanationStoreFixture.sql")
    }

    private static func materializeDatabase(from fixtureURL: URL, at databaseURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path]
        process.standardInput = try FileHandle(forReadingFrom: fixtureURL)

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? "No diagnostic output."
            throw OverlayHarnessFailure.sqliteToolFailed(process.terminationStatus, output)
        }
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw OverlayHarnessFailure.failedAssertion(message)
        }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw OverlayHarnessFailure.failedAssertion(message)
        }
        return value
    }
}
