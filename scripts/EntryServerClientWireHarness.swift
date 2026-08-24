import Foundation

private enum WireHarnessFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class QueuedWireTransport: ExplanationServerTransport,
    @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ExplanationTransportResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [ExplanationTransportResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> ExplanationTransportResponse {
        try nextResponse(for: request)
    }

    private func nextResponse(
        for request: URLRequest
    ) throws -> ExplanationTransportResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !responses.isEmpty else {
            throw WireHarnessFailure.failed("The fixture transport has no response.")
        }
        return responses.removeFirst()
    }
}

@main
private struct EntryServerClientWireHarness {
    private static let fixedNow = Date(timeIntervalSince1970: 1_777_809_600)

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw WireHarnessFailure.failed(
                "Usage: EntryServerClientWireHarness <server-contract-fixture-directory>"
            )
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resolvedData = try Data(contentsOf: directory.appendingPathComponent(
            "gynecologist-resolved.json"
        ))
        let outcomesData = try Data(contentsOf: directory.appendingPathComponent(
            "resolver-outcomes.json"
        ))
        let outcomes = try object(outcomesData)
        let requestFixtures = try object(Data(contentsOf: directory.appendingPathComponent(
            "swift-wire-requests.json"
        )))
        let replacementJobData = try Data(contentsOf: directory.appendingPathComponent(
            "replacement-job-succeeded.json"
        ))
        let baseEntry = try JSONDecoder().decode(ResolvedWordEntry.self, from: resolvedData)

        try await verifyResolveArms(
            resolvedData: resolvedData,
            outcomes: outcomes,
            requestFixture: requestFixtures["resolve"]
        )
        try await verifyConcurrentCodecIsolation(resolvedData: resolvedData)
        try await verifyCanonicalRequestIdentity()
        try await verifyRawJob(outcomes: outcomes)
        try await verifyFeedback(
            baseEntry: baseEntry,
            requestFixture: requestFixtures["feedback"]
        )
        try await verifyReplacement(
            baseEntry: baseEntry,
            outcomes: outcomes,
            requestFixture: requestFixtures["replacement"]
        )
        try await verifyTerminalReplacement(
            baseEntry: baseEntry,
            jobData: replacementJobData
        )
        print("EntryServerClient wire harness passed")
    }

    private static func verifyConcurrentCodecIsolation(
        resolvedData: Data
    ) async throws {
        let requestCount = 64
        let response = ExplanationTransportResponse(
            data: resolvedData,
            statusCode: 200
        )
        let transport = QueuedWireTransport(
            Array(repeating: response, count: requestCount)
        )
        let client = try makeClient(transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<requestCount {
                group.addTask {
                    guard case .resolved(let entry) = try await client.resolve(
                        resolveRequest()
                    ), entry.normalizedForm == "gynecologist" else {
                        throw WireHarnessFailure.failed(
                            "A concurrent response did not decode to the expected Entry."
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
        try expect(
            transport.requests.count == requestCount,
            "Concurrent requests were lost while encoding or decoding."
        )
    }

    private static func verifyResolveArms(
        resolvedData: Data,
        outcomes: [String: Any],
        requestFixture: Any?
    ) async throws {
        let fixtures: [(status: Int, data: Data, check: (EntryServerResult) throws -> Void)] = [
            (200, resolvedData, { result in
                guard case .resolved(let entry) = result,
                      entry.entryID == "ent_7c289b912dd44cd1a53b" else {
                    throw WireHarnessFailure.failed("The Go resolved fixture did not decode.")
                }
            }),
            (200, try data(outcomes["correctionRequired"]), { result in
                guard case .correctionRequired(let correction) = result,
                      correction.candidates == ["gynecologist"] else {
                    throw WireHarnessFailure.failed("The Go correction arm did not decode.")
                }
            }),
            (202, try data(outcomes["pending"]), { result in
                guard case .pending(let pending) = result,
                      pending.jobKind == "resolveEntry",
                      pending.jobID == "job_contract_fixture" else {
                    throw WireHarnessFailure.failed("The Go pending arm did not decode.")
                }
            }),
            (200, try data(outcomes["negative"]), { result in
                guard case .negative(let negative) = result,
                      negative.reason == "notFound" else {
                    throw WireHarnessFailure.failed("The Go negative arm did not decode.")
                }
            }),
            (503, try data(outcomes["unavailable"]), { result in
                guard case .unavailable(let unavailable) = result,
                      unavailable.reason == "repository_unavailable",
                      unavailable.retryAfter == fixedNow.addingTimeInterval(30) else {
                    throw WireHarnessFailure.failed("The Go 503 unavailable arm did not decode.")
                }
            }),
        ]

        for fixture in fixtures {
            let transport = QueuedWireTransport([
                ExplanationTransportResponse(
                    data: fixture.data,
                    statusCode: fixture.status
                ),
            ])
            let client = try makeClient(transport: transport)
            let result = try await client.resolve(resolveRequest())
            try fixture.check(result)
            let request = try require(transport.requests.first, "No resolve request was sent.")
            try expect(
                request.url?.path == "/v3/entries/resolve",
                "Resolve used the wrong route."
            )
            try expect(
                try keys(request) == Set([
                    "requestID", "encounteredSurfaceForm", "language", "locale",
                    "clientContentVersion", "normalizationVersion",
                    "resolverContractVersion", "lessonSchemaVersion",
                    "lessonContractVersion", "validatorVersion",
                    "minimumReviewPolicyVersion",
                    "minimumUsageSelectionPolicyVersion", "confirmedRareSpelling",
                ]),
                "Resolve request keys drifted from V3ResolveEntryRequest."
            )
            try verifyRequest(request, fixture: requestFixture)
        }
    }

    private static func verifyRawJob(outcomes: [String: Any]) async throws {
        let pending = try require(
            outcomes["pending"] as? [String: Any],
            "Pending fixture is not an object."
        )
        let job = try data(pending["job"])
        let transport = QueuedWireTransport([
            ExplanationTransportResponse(data: job, statusCode: 202),
        ])
        let client = try makeClient(transport: transport)
        let result = try await client.jobStatus(
            jobID: "job_contract_fixture",
            expectedCanonicalKeyHash: String(repeating: "a", count: 64)
        )
        guard case .pending(let pendingResult) = result,
              pendingResult.jobKind == "resolveEntry" else {
            throw WireHarnessFailure.failed("Raw Go job status did not decode.")
        }

        let mismatchedClient = try makeClient(transport: QueuedWireTransport([
            ExplanationTransportResponse(data: job, statusCode: 202),
        ]))
        do {
            _ = try await mismatchedClient.jobStatus(
                jobID: "job_contract_fixture",
                expectedCanonicalKeyHash: String(repeating: "b", count: 64)
            )
            throw WireHarnessFailure.failed(
                "Resolve polling accepted a changed canonical work identity."
            )
        } catch ExplanationServerClientError.invalidResponse {
            // Expected: a durable job ID and canonical key are one identity.
        }
    }

    private static func verifyFeedback(
        baseEntry: ResolvedWordEntry,
        requestFixture: Any?
    ) async throws {
        let usage = try require(baseEntry.usages.first, "Base fixture has no Usage.")
        let eventID = try require(
            UUID(uuidString: "1fb8a57c-2798-4a51-b622-a2890c461b56"),
            "Feedback UUID fixture is invalid."
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "eventID": eventID.uuidString.lowercased(),
            "accepted": true,
        ], options: [.sortedKeys])
        let transport = QueuedWireTransport([
            ExplanationTransportResponse(data: response, statusCode: 200),
        ])
        let client = try makeClient(transport: transport)
        let event = feedbackEvent(
            eventID: eventID,
            baseEntry: baseEntry,
            usage: usage,
            rating: .helpful,
            requestReplacement: false
        )
        let receipt = try await client.sendFeedback(event, baseEntry: baseEntry)
        try expect(receipt.accepted && receipt.replacementResult == nil,
                   "Helpful feedback receipt is invalid.")
        let request = try require(transport.requests.first, "No feedback request was sent.")
        try expect(
            request.url?.path == "/v3/entries/\(baseEntry.entryID)/usages/\(usage.entryUsageID)/explanations/\(usage.explanationID)/feedback",
            "Feedback used the wrong exact-lesson route."
        )
        try expect(
	            try keys(request) == Set([
	                "eventID", "locale", "rating", "component", "contentVersion",
	                "appVersion", "schemaVersion", "lessonContractVersion", "validatorVersion",
                "reviewPolicyVersion", "requestReplacement", "baseEntryRevision",
                "baseContentVersion", "excludedExplanationIDs",
            ]),
            "Feedback request keys drifted from V3FeedbackRequest."
        )
        try verifyRequest(request, fixture: requestFixture)

        let mismatchedTransport = QueuedWireTransport([])
        let mismatchedClient = try makeClient(transport: mismatchedTransport)
        let mismatchedEvent = feedbackEvent(
            eventID: UUID(),
            baseEntry: baseEntry,
            usage: usage,
            rating: .helpful,
            requestReplacement: false,
            contentVersion: "different-content-version"
        )
        do {
            _ = try await mismatchedClient.sendFeedback(
                mismatchedEvent,
                baseEntry: baseEntry
            )
            throw WireHarnessFailure.failed(
                "Feedback accepted an event bound to a different displayed Entry version."
            )
        } catch ExplanationServerClientError.invalidRequest {
            try expect(
                mismatchedTransport.requests.isEmpty,
                "Invalid exact-base feedback reached the transport."
            )
        }

        let invalidFeedbackLocales = [
            "e--US", "e-US", "en-123456789", "en_US", "é-US",
            "en-us", "zh-HANS-cn",
        ]
        for locale in invalidFeedbackLocales {
            let invalidTransport = QueuedWireTransport([])
            let invalidClient = try makeClient(transport: invalidTransport)
            let invalidEvent = feedbackEvent(
                eventID: UUID(),
                baseEntry: baseEntry,
                usage: usage,
                rating: .helpful,
                requestReplacement: false,
                locale: locale
            )
            do {
                _ = try await invalidClient.sendFeedback(
                    invalidEvent,
                    baseEntry: baseEntry
                )
                throw WireHarnessFailure.failed(
                    "Feedback accepted invalid or noncanonical locale \(locale)."
                )
            } catch ExplanationServerClientError.invalidRequest {
                try expect(
                    invalidTransport.requests.isEmpty,
                    "Invalid feedback locale \(locale) reached the transport."
                )
            }
        }
    }

    private static func verifyReplacement(
        baseEntry: ResolvedWordEntry,
        outcomes: [String: Any],
        requestFixture: Any?
    ) async throws {
        let usage = try require(baseEntry.usages.first, "Base fixture has no Usage.")
        let pendingEnvelope = try require(
            outcomes["pending"] as? [String: Any],
            "Pending fixture is not an object."
        )
        var job = try require(
            pendingEnvelope["job"] as? [String: Any],
            "Pending fixture has no job."
        )
        job["kind"] = "replaceExplanation"
        let jobData = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
        let transport = QueuedWireTransport([
            ExplanationTransportResponse(data: jobData, statusCode: 202),
        ])
        let client = try makeClient(transport: transport)
        let event = feedbackEvent(
            eventID: try require(
                UUID(uuidString: "fa6ab412-c109-49f1-bc4c-6554a92e21a9"),
                "Replacement UUID fixture is invalid."
            ),
            baseEntry: baseEntry,
            usage: usage,
            rating: .notHelpful,
            requestReplacement: true
        )
        let result = try await client.requestReplacement(
            for: event,
            baseEntry: baseEntry
        )
        guard case .pending(let pending) = result,
              pending.jobKind == "replaceExplanation" else {
            throw WireHarnessFailure.failed("Raw Go replacement job did not decode.")
        }
        let request = try require(transport.requests.first, "No replacement request was sent.")
        try expect(
            request.url?.path == "/v3/entries/\(baseEntry.entryID)/usages/\(usage.entryUsageID)/replacements",
            "Replacement used the wrong route."
        )
        try expect(
            try keys(request) == Set([
                "requestID", "locale", "baseExplanationID", "dislikedComponent",
                "excludedExplanationIDs", "baseEntryRevision", "baseContentVersion",
                "normalizationVersion", "resolverContractVersion",
                "lessonSchemaVersion", "lessonContractVersion", "validatorVersion",
                "minimumReviewPolicyVersion",
            ]),
            "Replacement request keys drifted from V3ReplacementRequest."
        )
        try verifyRequest(request, fixture: requestFixture)
    }

    private static func verifyTerminalReplacement(
        baseEntry: ResolvedWordEntry,
        jobData: Data
    ) async throws {
        let transport = QueuedWireTransport([
            ExplanationTransportResponse(data: jobData, statusCode: 200),
        ])
        let client = try makeClient(transport: transport)
        let result = try await client.replacementJobStatus(
            jobID: "job_replacement_fixture",
            expectedCanonicalKeyHash: String(repeating: "b", count: 64),
            baseEntry: baseEntry
        )
        guard case .complete(let replacement) = result,
              replacement.entryID == baseEntry.entryID,
              replacement.entryUsageID == baseEntry.usages.first?.entryUsageID,
              replacement.baseExplanationID == baseEntry.usages.first?.explanationID,
              replacement.contentHash
                == "c3d4d6d2fde5f475cfef3501078acdb5ea5b5111984f83503d824245e789b1de" else {
            throw WireHarnessFailure.failed(
                "Raw Go terminal replacement did not decode and bind to its base lesson."
            )
        }
    }

    private static func verifyCanonicalRequestIdentity() async throws {
        let invalidCases: [(String, String, String)] = [
            ("EN", "en", "noncanonical language"),
            ("fr", "en", "unsupported language"),
            ("en", "e--US", "empty locale subtag"),
            ("en", "e-US", "one-letter locale language"),
            ("en", "en-123456789", "overlong locale subtag"),
            ("en", "en_US", "noncanonical locale"),
            ("en", "é-US", "non-ASCII locale"),
            ("en", "en-us", "noncanonical locale casing"),
            ("en", "zh-HANS-cn", "noncanonical multi-subtag casing"),
        ]
        for (language, locale, label) in invalidCases {
            let transport = QueuedWireTransport([])
            let client = try makeClient(transport: transport)
            do {
                _ = try await client.resolve(resolveRequest(
                    language: language,
                    locale: locale
                ))
                throw WireHarnessFailure.failed(
                    "Resolve accepted a \(label) request key."
                )
            } catch ExplanationServerClientError.invalidRequest {
                try expect(
                    transport.requests.isEmpty,
                    "A \(label) request reached the transport."
                )
            }
        }

        let invalidSurfaces = [
            "", ".22", "word()", "word//book", "a..m.",
            "one two three four five", String(repeating: "a", count: 101),
        ]
        for surface in invalidSurfaces {
            let transport = QueuedWireTransport([])
            let client = try makeClient(transport: transport)
            do {
                _ = try await client.resolve(resolveRequest(surfaceForm: surface))
                throw WireHarnessFailure.failed(
                    "Resolve accepted invalid resolver surface \(surface.debugDescription)."
                )
            } catch ExplanationServerClientError.invalidRequest {
                try expect(
                    transport.requests.isEmpty,
                    "Invalid resolver surface reached the transport."
                )
            }
        }

        let unavailableData = try JSONSerialization.data(
            withJSONObject: [
                "result": "unavailable",
                "unavailable": [
                    "reasonCode": "fixture_unavailable",
                    "retryAfterSeconds": 0,
                ],
            ],
            options: [.sortedKeys]
        )
        let validLocales = [
            "en", "en-US", "zh-hans-CN", "de-CH-1901", "abc-12345678",
        ]
        for locale in validLocales {
            let transport = QueuedWireTransport([
                ExplanationTransportResponse(data: unavailableData, statusCode: 200),
            ])
            let client = try makeClient(transport: transport)
            guard case .unavailable = try await client.resolve(resolveRequest(
                locale: locale
            )) else {
                throw WireHarnessFailure.failed(
                    "Resolve did not accept allowed canonical locale \(locale)."
                )
            }
            try expect(
                transport.requests.count == 1,
                "Allowed locale \(locale) did not reach the transport."
            )
        }
        let validSurfaces = [
            "etc.", "A.M.", "Achilles' heel", "'hood", "rock 'n' roll",
            "jack-o'-lantern", "read/write", "24/7",
        ]
        for surface in validSurfaces {
            let transport = QueuedWireTransport([
                ExplanationTransportResponse(data: unavailableData, statusCode: 200),
            ])
            let client = try makeClient(transport: transport)
            guard case .unavailable = try await client.resolve(resolveRequest(
                surfaceForm: surface
            )) else {
                throw WireHarnessFailure.failed(
                    "Resolve did not accept resolver surface \(surface)."
                )
            }
            try expect(
                transport.requests.count == 1,
                "Allowed resolver surface \(surface) did not reach the transport."
            )
        }
    }

    private static func resolveRequest(
        surfaceForm: String = "gynecologist",
        language: String = "en",
        locale: String = "en"
    ) -> EntryResolveRequest {
        EntryResolveRequest(
            requestID: UUID(uuidString: "e328e36a-6871-4dc5-9f92-bfd5a3029f3d")!,
            encounteredSurfaceForm: surfaceForm,
            language: language,
            locale: locale,
            context: nil,
            clientContentVersion: "content-2026-08",
            normalizationVersion: 1,
            resolverContractVersion: 1,
            lessonSchemaVersion: 2,
            lessonContractVersion: 2,
            validatorVersion: 2,
            minimumReviewPolicyVersion: 5,
            minimumUsageSelectionPolicyVersion: 1,
            confirmedRareSpelling: false
        )
    }

    private static func feedbackEvent(
        eventID: UUID,
        baseEntry: ResolvedWordEntry,
        usage: UsageLesson,
        rating: EntryFeedbackRating,
        requestReplacement: Bool,
        contentVersion: String? = nil,
        locale: String? = nil
    ) -> EntryFeedbackEvent {
        EntryFeedbackEvent(
            eventID: eventID,
            entryID: baseEntry.entryID,
            entryUsageID: usage.entryUsageID,
            explanationID: usage.explanationID,
            normalizedForm: baseEntry.normalizedForm,
            language: baseEntry.language,
            locale: locale ?? baseEntry.locale,
            rating: rating,
            component: requestReplacement ? .example : .wholeLesson,
            requestReplacement: requestReplacement,
            contentVersion: contentVersion ?? baseEntry.contentVersion,
            appVersion: "3.0",
            baseContentVersion: baseEntry.contentVersion,
            baseEntryRevision: baseEntry.entryRevision,
            schemaVersion: usage.schemaVersion,
            lessonContractVersion: usage.lessonContractVersion,
            validatorVersion: usage.validatorVersion,
            reviewPolicyVersion: usage.reviewPolicyVersion,
            excludedExplanationIDs: requestReplacement ? [usage.explanationID] : [],
            createdAt: fixedNow
        )
    }

    private static func makeClient(
        transport: any ExplanationServerTransport
    ) throws -> EntryServerClient {
        try EntryServerClient(
            baseURL: require(URL(string: "https://example.test"), "Bad URL."),
            transport: transport,
            now: { fixedNow }
        )
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Fixture is not a JSON object."
        )
    }

    private static func data(_ value: Any?) throws -> Data {
        let value = try require(value, "Fixture value is absent.")
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func keys(_ request: URLRequest) throws -> Set<String> {
        let body = try require(request.httpBody, "Request has no JSON body.")
        return Set(try object(body).keys)
    }

    private static func verifyRequest(
        _ request: URLRequest,
        fixture: Any?
    ) throws {
        let fixture = try require(
            fixture as? [String: Any],
            "Swift request fixture is not an object."
        )
        let expectedMethod = try require(
            fixture["method"] as? String,
            "Swift request fixture has no method."
        )
        let expectedPath = try require(
            fixture["path"] as? String,
            "Swift request fixture has no path."
        )
        let expectedBody = try require(
            fixture["body"] as? [String: Any],
            "Swift request fixture has no body."
        )
        let actualBody = try object(try require(
            request.httpBody,
            "Request has no JSON body."
        ))
        try expect(request.httpMethod == expectedMethod, "HTTP method differs from fixture.")
        try expect(request.url?.path == expectedPath, "HTTP path differs from fixture.")
        try expect(
            NSDictionary(dictionary: actualBody).isEqual(to: expectedBody),
            "JSON request body differs from the shared Swift/Go fixture."
        )
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else { throw WireHarnessFailure.failed(message) }
    }

    private static func require<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else { throw WireHarnessFailure.failed(message) }
        return value
    }
}
