import Foundation

enum ExplanationRepositoryHarnessFailure: LocalizedError {
    case failedAssertion(String)
    case sqliteToolFailed(Int32, String)
    case scriptedTransportExhausted
    case scriptedTransportFailure(String)

    var errorDescription: String? {
        switch self {
        case .failedAssertion(let message):
            return message
        case .sqliteToolFailed(let status, let output):
            return "sqlite3 failed with status \(status): \(output)"
        case .scriptedTransportExhausted:
            return "The repository made an unexpected extra server request."
        case .scriptedTransportFailure(let message):
            return message
        }
    }
}

private enum ScriptedTransportStep {
    case response(Data, statusCode: Int)
    case failure(String)
}

private final class ScriptedExplanationTransport: ExplanationServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ScriptedTransportStep]
    private var requests: [URLRequest] = []

    init(steps: [ScriptedTransportStep]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> ExplanationTransportResponse {
        try nextResponse(for: request)
    }

    func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func nextResponse(for request: URLRequest) throws -> ExplanationTransportResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !steps.isEmpty else {
            throw ExplanationRepositoryHarnessFailure.scriptedTransportExhausted
        }
        switch steps.removeFirst() {
        case .response(let data, let statusCode):
            return ExplanationTransportResponse(data: data, statusCode: statusCode)
        case .failure(let message):
            throw ExplanationRepositoryHarnessFailure.scriptedTransportFailure(message)
        }
    }
}

private final class CountingBundledStore: ExplanationLookupStore, @unchecked Sendable {
    private let store: OfflineExplanationStore
    private let lock = NSLock()
    private var lookupCountStorage = 0

    init(_ store: OfflineExplanationStore) {
        self.store = store
    }

    func explanation(for form: String) throws -> OfflineVocabularyExplanation? {
        lock.lock()
        lookupCountStorage += 1
        lock.unlock()
        return try store.explanation(for: form)
    }

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lookupCountStorage
    }
}

private struct OverlayStoreCall: Sendable {
    let record: OfflineVocabularyExplanation
    let selected: Bool
    let madeDefault: Bool
}

private final class CountingOverlayStore: ExplanationOverlayRepositoryStore, @unchecked Sendable {
    private let store: ExplanationOverlayStore
    private let lock = NSLock()
    private var lookupCountStorage = 0
    private var storeCallsStorage: [OverlayStoreCall] = []

    init(_ store: ExplanationOverlayStore) {
        self.store = store
    }

    func explanation(for form: String) throws -> OfflineVocabularyExplanation? {
        lock.lock()
        lookupCountStorage += 1
        lock.unlock()
        return try store.explanation(for: form)
    }

    func explanation(
        for form: String,
        senseID: String
    ) throws -> OfflineVocabularyExplanation? {
        try store.explanation(for: form, senseID: senseID)
    }

    func storeValidatedServerExplanation(
        _ record: OfflineVocabularyExplanation,
        selectForForm: Bool,
        makeDefaultForForm: Bool
    ) throws {
        try store.storeValidatedServerExplanation(
            record,
            selectForForm: selectForForm,
            makeDefaultForForm: makeDefaultForForm
        )
        lock.lock()
        storeCallsStorage.append(OverlayStoreCall(
            record: record,
            selected: selectForForm,
            madeDefault: makeDefaultForForm
        ))
        lock.unlock()
    }

    @discardableResult
    func enqueueFeedback(_ event: ExplanationFeedbackEvent) throws -> Bool {
        try store.enqueueFeedback(event)
    }

    func dequeuePendingFeedback(limit: Int) throws -> [ExplanationFeedbackEvent] {
        try store.dequeuePendingFeedback(limit: limit)
    }

    @discardableResult
    func markFeedbackSent(eventID: UUID, sentAt: Date?) throws -> Bool {
        try store.markFeedbackSent(eventID: eventID, sentAt: sentAt)
    }

    var lookupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lookupCountStorage
    }

    var storeCalls: [OverlayStoreCall] {
        lock.lock()
        defer { lock.unlock() }
        return storeCallsStorage
    }
}

private final class FixedUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty, "The harness exhausted its fixed UUIDs.")
        return values.removeFirst()
    }
}

@main
struct ExplanationRepositoryHarness {
    static func main() async throws {
        let fixtureDirectory = fixtureDirectoryFromArguments()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordbookExplanationRepository-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseURL = temporaryDirectory.appendingPathComponent("base.sqlite")
        try materializeDatabase(
            from: fixtureDirectory.appendingPathComponent("OfflineExplanationStoreFixture.sql"),
            at: baseURL
        )
        let bundledBytesBefore = try Data(contentsOf: baseURL)
        let bundled = CountingBundledStore(try OfflineExplanationStore(databaseURL: baseURL))
        let overlayDatabaseURL = temporaryDirectory.appendingPathComponent("overlay.sqlite")
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000.125)
        let overlayBacking = try ExplanationOverlayStore(
            databaseURL: overlayDatabaseURL,
            now: { fixedDate }
        )
        let overlay = CountingOverlayStore(overlayBacking)

        let replacementEventID = try fixedUUID(
            "4d5be27f-f83d-45c8-926b-ed71c720db25"
        )
        let likeEventID = try fixedUUID("855183ad-a618-4602-af48-d683b916f564")
        let dislikeEventID = try fixedUUID("e289e342-5f61-4d65-85b9-7a22bb5ce1de")
        let retryEventID = try fixedUUID("4ec88ced-9d7f-4da4-bb48-92b28794a993")
        let invalidReplacementEventID = try fixedUUID(
            "62828822-8a1b-47d7-b806-0939762a78a3"
        )
        let uuidSequence = FixedUUIDSequence([
            replacementEventID,
            likeEventID,
            dislikeEventID,
            retryEventID,
            invalidReplacementEventID,
        ])

        let resolveData = try Data(
            contentsOf: fixtureDirectory.appendingPathComponent("ServerResolveResponse.json")
        )
        let replacementData = try Data(
            contentsOf: fixtureDirectory.appendingPathComponent("ServerReplacementResponse.json")
        )
        let transport = ScriptedExplanationTransport(steps: [
            .response(resolveData, statusCode: 200),
            .response(replacementData, statusCode: 200),
            .response(feedbackAcknowledgement(eventID: likeEventID), statusCode: 200),
            .response(feedbackAcknowledgement(eventID: dislikeEventID), statusCode: 200),
            .failure("fixture network is offline"),
            .response(feedbackAcknowledgement(eventID: retryEventID), statusCode: 200),
            .response(
                invalidReplacement(
                    replacementData,
                    eventID: invalidReplacementEventID
                ),
                statusCode: 200
            ),
        ])
        let client = try ExplanationServerClient(
            baseURL: try require(
                URL(string: "https://example.test/api"),
                "The fixture base URL is invalid."
            ),
            transport: transport
        )
        let repository = ExplanationRepository(
            overlay: overlay,
            bundled: bundled,
            server: client,
            makeEventID: { uuidSequence.next() },
            now: { fixedDate }
        )

        let bundledResult = try await repository.resolve(form: "  WENT\n")
        try expect(bundledResult.source == .bundled, "Bundled content did not resolve before the server.")
        try expect(
            bundledResult.surfaceForm == "  WENT\n",
            "Resolution discarded the caller's raw surface form."
        )
        try expect(transport.capturedRequests().isEmpty, "A bundled hit unexpectedly called the server.")

        try overlayBacking.storeValidatedServerExplanation(bundledResult.record)
        let bundledLookupsBeforeOverlayHit = bundled.lookupCount
        let overlayResult = try await repository.resolve(form: "WENT")
        try expect(overlayResult.source == .overlay, "The overlay did not take precedence over bundled content.")
        try expect(
            bundled.lookupCount == bundledLookupsBeforeOverlayHit,
            "An overlay hit still queried the bundled store."
        )

        let serverResult = try await repository.resolve(form: " RAN ")
        try expect(serverResult.source == .server, "A complete miss did not use the v2 server.")
        try expect(serverResult.surfaceForm == " RAN ", "The server path lost the raw request spelling.")
        try expect(
            serverResult.record.morphology == .combined(["past", "pastParticiple"]),
            "Combined server morphology was flattened or changed."
        )
        try expect(
            overlay.storeCalls.count == 3,
            "The server result did not persist all declared form analyses."
        )
        try expect(
            overlay.storeCalls.filter({ $0.selected && $0.madeDefault }).count == 1,
            "The repository selected more than the requested surface form."
        )
        let resolveRequest = try require(
            transport.capturedRequests().first,
            "The resolve request was not captured."
        )
        try expect(
            resolveRequest.url?.path == "/api/v2/explanations/resolve",
            "The resolve request used the wrong endpoint."
        )
        let resolveBody = try jsonObject(resolveRequest.httpBody)
        try expect(
            resolveBody["form"] as? String == " RAN ",
            "The client normalized the surface form before sending it."
        )

        let requestCountBeforeCacheHit = transport.capturedRequests().count
        let cachedServerResult = try await repository.resolve(form: "ran")
        try expect(cachedServerResult.source == .overlay, "A server result was not cached in the overlay.")
        try expect(
            transport.capturedRequests().count == requestCountBeforeCacheHit,
            "Resolving the cached server form made a second request."
        )

        try await verifyInvalidResolveResponses(
            resolveData,
            baseURL: baseURL,
            directory: temporaryDirectory
        )

        let replacementSubmission = try await repository.submitFeedback(
            for: serverResult,
            rating: .dislike,
            component: .memoryAid,
            requestReplacement: true
        )
        try expect(replacementSubmission.deliveryState == .sent, "Replacement feedback was not sent.")
        try expect(
            replacementSubmission.replacementStatus == .complete,
            "The completed replacement status was lost."
        )
        let replacement = try require(
            replacementSubmission.replacement,
            "The replacement explanation was not returned."
        )
        try expect(
            replacement.morphology == serverResult.record.morphology,
            "Replacement persistence changed the exact morphology."
        )
        try expect(
            try overlayBacking.explanation(for: "ran")?.explanationID
                == replacement.explanationID,
            "The validated replacement was not selected in the overlay."
        )
        try expect(
            transport.capturedRequests().count == requestCountBeforeCacheHit + 1,
            "One explicit replacement tap made more than one server request."
        )
        let replacementRequest = transport.capturedRequests()[1]
        let replacementRequestBody = try jsonObject(replacementRequest.httpBody)
        try expect(
            replacementRequest.url?.path
                == "/api/v2/explanations/\(serverResult.record.explanationID)/feedback",
            "Replacement feedback targeted the wrong explanation revision."
        )
        try expect(
            replacementRequestBody["form"] as? String == " RAN "
                && replacementRequestBody["eventID"] as? String
                    == replacementEventID.uuidString.lowercased()
                && replacementRequestBody["rating"] as? String == "dislike"
                && replacementRequestBody["requestReplacement"] as? Bool == true,
            "Replacement feedback changed the explicit tap payload."
        )

        let currentResolution = ExplanationResolution(
            surfaceForm: "ran",
            source: .overlay,
            record: replacement
        )
        let likeSubmission = try await repository.submitFeedback(
            for: currentResolution,
            rating: .like
        )
        try expect(
            likeSubmission.deliveryState == .sent
                && likeSubmission.replacementStatus == .notRequested,
            "Like feedback was not delivered without generation."
        )
        let dislikeSubmission = try await repository.submitFeedback(
            for: currentResolution,
            rating: .dislike,
            component: .meaning
        )
        try expect(
            dislikeSubmission.deliveryState == .sent
                && dislikeSubmission.replacementStatus == .notRequested,
            "Non-replacement dislike feedback was not delivered."
        )
        let likeBody = try jsonObject(transport.capturedRequests()[2].httpBody)
        let dislikeBody = try jsonObject(transport.capturedRequests()[3].httpBody)
        try expect(
            likeBody["rating"] as? String == "like"
                && likeBody["requestReplacement"] as? Bool == false,
            "Like feedback unexpectedly requested generation."
        )
        try expect(
            dislikeBody["rating"] as? String == "dislike"
                && dislikeBody["requestReplacement"] as? Bool == false,
            "A plain dislike unexpectedly requested generation."
        )

        let queuedSubmission = try await repository.submitFeedback(
            for: currentResolution,
            rating: .like
        )
        try expect(queuedSubmission.deliveryState == .queued, "A transport failure lost queued feedback.")
        let requestsAfterQueuedAttempt = transport.capturedRequests().count
        let retrySubmissions = try await repository.sendPendingFeedback(limit: 10)
        try expect(
            retrySubmissions.count == 1
                && retrySubmissions[0].eventID == retryEventID
                && retrySubmissions[0].deliveryState == .sent,
            "The pending UUID was not delivered exactly once on retry."
        )
        try expect(
            transport.capturedRequests().count == requestsAfterQueuedAttempt + 1,
            "One outbox retry made an unexpected number of requests."
        )
        let queuedBody = try jsonObject(
            transport.capturedRequests()[requestsAfterQueuedAttempt - 1].httpBody
        )
        let retryBody = try jsonObject(
            transport.capturedRequests()[requestsAfterQueuedAttempt].httpBody
        )
        try expect(
            queuedBody["eventID"] as? String == retryEventID.uuidString.lowercased()
                && retryBody["eventID"] as? String
                    == retryEventID.uuidString.lowercased(),
            "The retry did not reuse the idempotent feedback UUID."
        )
        let requestsBeforeEmptyDrain = transport.capturedRequests().count
        let emptyDrain = try await repository.sendPendingFeedback(limit: 10)
        try expect(
            emptyDrain.isEmpty,
            "An acknowledged event remained in the feedback outbox."
        )
        try expect(
            transport.capturedRequests().count == requestsBeforeEmptyDrain,
            "Draining an empty outbox called the server."
        )

        let explanationBeforeInvalidReplacement = try overlayBacking.explanation(for: "ran")
        let requestCountBeforeInvalidReplacement = transport.capturedRequests().count
        var rejectedInvalidReplacement = false
        do {
            _ = try await repository.submitFeedback(
                for: currentResolution,
                rating: .dislike,
                requestReplacement: true
            )
        } catch ExplanationServerClientError.invalidResponse {
            rejectedInvalidReplacement = true
        }
        try expect(rejectedInvalidReplacement, "A cross-sense replacement was accepted.")
        try expect(
            try overlayBacking.explanation(for: "ran") == explanationBeforeInvalidReplacement,
            "An invalid replacement changed the selected overlay variant."
        )
        try expect(
            transport.capturedRequests().count == requestCountBeforeInvalidReplacement + 1,
            "A rejected replacement response triggered another request."
        )
        let pendingInvalidReplacement = try overlayBacking.dequeuePendingFeedback(limit: 10)
        try expect(
            pendingInvalidReplacement.map(\.eventID) == [invalidReplacementEventID],
            "Invalid replacement feedback was acknowledged instead of remaining queued."
        )

        try expect(
            try Data(contentsOf: baseURL) == bundledBytesBefore,
            "Repository resolution or feedback mutated the bundled database."
        )
        print("ExplanationRepository harness passed")
    }

    private static func verifyInvalidResolveResponses(
        _ validData: Data,
        baseURL: URL,
        directory: URL
    ) async throws {
        let invalidPayloads: [(String, Data)] = [
            ("schema", try modifiedJSON(validData) { root in
                var explanation = try dictionary(root["explanation"], "explanation")
                explanation["schemaVersion"] = 2
                root["explanation"] = explanation
            }),
            ("sense", try modifiedJSON(validData) { root in
                root["senseID"] = "source:other-sense"
            }),
            ("identity", try modifiedJSON(validData) { root in
                var explanation = try dictionary(root["explanation"], "explanation")
                explanation["id"] = "exp_0000000000000000000000000000000000000000000000000000000000000000"
                root["explanation"] = explanation
            }),
            ("content-hash", try modifiedJSON(validData) { root in
                var explanation = try dictionary(root["explanation"], "explanation")
                explanation["contentHash"] = String(repeating: "0", count: 64)
                root["explanation"] = explanation
            }),
            ("morphology", try modifiedJSON(validData) { root in
                guard var forms = root["forms"] as? [[String: Any]],
                      let requestedIndex = forms.firstIndex(where: {
                          $0["normalizedForm"] as? String == "ran"
                      }) else {
                    throw ExplanationRepositoryHarnessFailure.failedAssertion(
                        "The resolve fixture has no requested form."
                    )
                }
                forms[requestedIndex]["morphology"] = ["tense": "past"]
                root["forms"] = forms
            }),
        ]

        for (name, payload) in invalidPayloads {
            let overlayURL = directory.appendingPathComponent("invalid-\(name).sqlite")
            let overlay = try ExplanationOverlayStore(databaseURL: overlayURL)
            let transport = ScriptedExplanationTransport(steps: [
                .response(payload, statusCode: 200),
            ])
            let client = try ExplanationServerClient(
                baseURL: try require(
                    URL(string: "https://example.test"),
                    "The invalid-response test URL is malformed."
                ),
                transport: transport
            )
            let repository = ExplanationRepository(
                overlay: overlay,
                bundled: try OfflineExplanationStore(databaseURL: baseURL),
                server: client
            )
            var rejected = false
            do {
                _ = try await repository.resolve(form: "ran")
            } catch ExplanationServerClientError.invalidResponse {
                rejected = true
            }
            try expect(rejected, "The \(name) mismatch was accepted.")
            try expect(
                try overlay.explanation(for: "ran") == nil,
                "The \(name) mismatch was persisted before validation."
            )
        }
    }

    private static func feedbackAcknowledgement(eventID: UUID) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "eventID": eventID.uuidString.lowercased(),
            "accepted": true,
            "replacementStatus": "not_requested",
        ], options: [.sortedKeys])
    }

    private static func invalidReplacement(_ data: Data, eventID: UUID) -> Data {
        try! modifiedJSON(data) { root in
            root["eventID"] = eventID.uuidString.lowercased()
            var replacement = try dictionary(root["replacement"], "replacement")
            replacement["senseID"] = "source:other-sense"
            root["replacement"] = replacement
        }
    }

    private static func modifiedJSON(
        _ data: Data,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var object = try dictionary(
            JSONSerialization.jsonObject(with: data),
            "root"
        )
        try mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func dictionary(
        _ value: Any?,
        _ field: String
    ) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw ExplanationRepositoryHarnessFailure.failedAssertion(
                "Fixture field \(field) is not an object."
            )
        }
        return dictionary
    }

    private static func jsonObject(_ data: Data?) throws -> [String: Any] {
        guard let data else {
            throw ExplanationRepositoryHarnessFailure.failedAssertion(
                "The captured request has no JSON body."
            )
        }
        return try dictionary(JSONSerialization.jsonObject(with: data), "request")
    }

    private static func fixtureDirectoryFromArguments() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/Fixtures", isDirectory: true)
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
            throw ExplanationRepositoryHarnessFailure.sqliteToolFailed(
                process.terminationStatus,
                output
            )
        }
    }

    private static func fixedUUID(_ value: String) throws -> UUID {
        try require(UUID(uuidString: value), "Fixture UUID \(value) is invalid.")
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw ExplanationRepositoryHarnessFailure.failedAssertion(message)
        }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw ExplanationRepositoryHarnessFailure.failedAssertion(message)
        }
        return value
    }
}
