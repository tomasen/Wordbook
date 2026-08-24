import CryptoKit
import Foundation

struct ExplanationTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol ExplanationServerTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ExplanationTransportResponse
}

final class URLSessionExplanationServerTransport: ExplanationServerTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> ExplanationTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ExplanationTransportResponse(data: data, statusCode: response.statusCode)
    }
}

enum ExplanationServerClientError: LocalizedError {
    case invalidBaseURL(URL)
    case invalidRequest(String)
    case transportFailed(String)
    case httpFailure(statusCode: Int)
    case responseTooLarge(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "The explanation server URL is invalid: \(url.absoluteString)"
        case .invalidRequest(let reason):
            return "The explanation request is invalid: \(reason)"
        case .transportFailed(let reason):
            return "The explanation server could not be reached: \(reason)"
        case .httpFailure(let statusCode):
            return "The explanation server returned HTTP \(statusCode)."
        case .responseTooLarge(let size):
            return "The explanation server response is too large (\(size) bytes)."
        case .invalidResponse(let reason):
            return "The explanation server response is invalid: \(reason)"
        }
    }

    var isRetryableDeliveryFailure: Bool {
        switch self {
        case .transportFailed:
            return true
        case .httpFailure(let statusCode):
            return statusCode == 408
                || statusCode == 425
                || statusCode == 429
                || (500...599).contains(statusCode)
        case .invalidBaseURL,
             .invalidRequest,
             .responseTooLarge,
             .invalidResponse:
            return false
        }
    }
}

enum ExplanationReplacementStatus: String, Equatable, Sendable {
    case notRequested = "not_requested"
    case pending
    case complete
    case failed
}

struct ValidatedServerResolution: Sendable {
    let records: [OfflineVocabularyExplanation]
    let primary: OfflineVocabularyExplanation
}

struct ValidatedServerFeedbackReceipt: Sendable {
    let eventID: UUID
    let replacementStatus: ExplanationReplacementStatus
    let replacement: OfflineVocabularyExplanation?
    let failureCode: String?
}

protocol ExplanationServerServing: Sendable {
    func resolve(form: String) async throws -> ValidatedServerResolution

    func sendFeedback(
        _ event: ExplanationFeedbackEvent,
        surfaceForm: String,
        lexicalContext: OfflineVocabularyExplanation
    ) async throws -> ValidatedServerFeedbackReceipt
}

/// Typed client for the v2 explanation service. Server objects cross this
/// boundary only after their lexical identity and immutable content hashes are
/// checked against the same schema used by the bundled content pack.
final class ExplanationServerClient: ExplanationServerServing, @unchecked Sendable {
    static let supportedExplanationSchemaVersion = 1

    private let baseURL: URL
    private let transport: any ExplanationServerTransport
    private let requestTimeout: TimeInterval

    init(
        baseURL: URL,
        transport: any ExplanationServerTransport = URLSessionExplanationServerTransport(),
        requestTimeout: TimeInterval = 20
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              baseURL.host != nil else {
            throw ExplanationServerClientError.invalidBaseURL(baseURL)
        }
        self.baseURL = baseURL
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    func resolve(form: String) async throws -> ValidatedServerResolution {
        guard WordbookNormalizationV1.normalizeLookupKey(form) != nil else {
            throw ExplanationServerClientError.invalidRequest(
                "form is not a valid resolver surface"
            )
        }
        let response: ResolveResponseDTO = try await post(
            pathComponents: ["v2", "explanations", "resolve"],
            body: ResolveRequestDTO(form: form)
        )
        return try ServerResponseValidator.resolution(response, requestedForm: form)
    }

    func sendFeedback(
        _ event: ExplanationFeedbackEvent,
        surfaceForm: String,
        lexicalContext: OfflineVocabularyExplanation
    ) async throws -> ValidatedServerFeedbackReceipt {
        guard let normalizedSurfaceForm = WordbookNormalizationV1.normalizeLookupKey(
            surfaceForm
        ),
              normalizedSurfaceForm == event.normalizedForm,
              lexicalContext.normalizedForm == event.normalizedForm,
              lexicalContext.senseID == event.senseID else {
            throw ExplanationServerClientError.invalidRequest(
                "feedback form and lexical context do not match the queued event"
            )
        }
        let response: FeedbackResponseDTO = try await post(
            pathComponents: ["v2", "explanations", event.explanationID, "feedback"],
            body: FeedbackRequestDTO(
                eventID: event.eventID.uuidString.lowercased(),
                form: surfaceForm,
                rating: event.rating.rawValue,
                component: event.component.rawValue,
                requestReplacement: event.requestReplacement
            )
        )
        return try ServerResponseValidator.feedback(
            response,
            event: event,
            lexicalContext: lexicalContext
        )
    }

    private func post<Body: Encodable, Response: Decodable>(
        pathComponents: [String],
        body: Body
    ) async throws -> Response {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Wordbook/2.0", forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw ExplanationServerClientError.invalidRequest(error.localizedDescription)
        }

        let transported: ExplanationTransportResponse
        do {
            transported = try await transport.send(request)
        } catch {
            throw ExplanationServerClientError.transportFailed(error.localizedDescription)
        }
        guard (200..<300).contains(transported.statusCode) else {
            throw ExplanationServerClientError.httpFailure(
                statusCode: transported.statusCode
            )
        }
        guard transported.data.count <= 2 * 1_024 * 1_024 else {
            throw ExplanationServerClientError.responseTooLarge(transported.data.count)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: transported.data)
        } catch {
            throw ExplanationServerClientError.invalidResponse(error.localizedDescription)
        }
    }
}

private struct ResolveRequestDTO: Encodable {
    let form: String
}

private struct ResolveResponseDTO: Decodable {
    let form: String
    let normalizedForm: String
    let lemma: String
    let partOfSpeech: String
    let senseID: String
    let forms: [WordFormDTO]
    let explanation: ExplanationDTO
}

private struct WordFormDTO: Decodable {
    let normalizedForm: String
    let displayForm: String
    let morphology: WordFormMorphologyDTO
    let rank: Int
}

/// The current offline/overlay model stores the pack's string and string-array
/// morphology forms. Structured JSON is rejected at the boundary instead of
/// being flattened or silently losing evidence.
private enum WordFormMorphologyDTO: Decodable {
    case single(String)
    case combined([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .single(single)
            return
        }
        if let combined = try? container.decode([String].self) {
            self = .combined(combined)
            return
        }
        throw DecodingError.typeMismatch(
            WordFormMorphologyDTO.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "morphology must be a string or an array of strings"
            )
        )
    }

    var offlineValue: OfflineWordFormMorphology {
        switch self {
        case .single(let value):
            return .single(value)
        case .combined(let values):
            return .combined(values)
        }
    }

    var values: [String] {
        offlineValue.values
    }
}

private struct ExplanationDTO: Decodable {
    let id: String
    let senseID: String
    let schemaVersion: Int
    let contentHash: String
    let content: ExplanationContentDTO
    let source: String
}

private struct ExplanationContentDTO: Decodable {
    let senseID: String
    let partOfSpeech: String
    let meaning: String
    let memoryTechnique: VocabularyMemoryTechnique?
    let memoryAid: [String]
    let example: String
    let synonyms: [String]

    private enum CodingKeys: String, CodingKey {
        case senseID
        case partOfSpeech
        case meaning
        case memoryTechnique
        case memoryAid
        case example
        case synonyms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let requiredKeys: [CodingKeys] = [
            .senseID,
            .partOfSpeech,
            .meaning,
            .memoryTechnique,
            .memoryAid,
            .example,
            .synonyms,
        ]
        for key in requiredKeys where !container.contains(key) {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "missing required explanation field \(key.rawValue)"
                )
            )
        }
        senseID = try container.decode(String.self, forKey: .senseID)
        partOfSpeech = try container.decode(String.self, forKey: .partOfSpeech)
        meaning = try container.decode(String.self, forKey: .meaning)
        memoryTechnique = try container.decodeIfPresent(
            VocabularyMemoryTechnique.self,
            forKey: .memoryTechnique
        )
        memoryAid = try container.decode([String].self, forKey: .memoryAid)
        example = try container.decode(String.self, forKey: .example)
        synonyms = try container.decode([String].self, forKey: .synonyms)
    }
}

private struct FeedbackRequestDTO: Encodable {
    let eventID: String
    let form: String
    let rating: String
    let component: String
    let requestReplacement: Bool
}

private struct FeedbackResponseDTO: Decodable {
    let eventID: String
    let accepted: Bool
    let replacementStatus: String
    let replacement: ExplanationDTO?
    let failureCode: String?
}

private enum ServerResponseValidator {
    private static let allowedPartsOfSpeech: Set<String> = [
        "n", "v", "adj", "adv", "prep", "conj", "pron", "interj",
        "det", "phrase",
    ]

    static func resolution(
        _ response: ResolveResponseDTO,
        requestedForm: String
    ) throws -> ValidatedServerResolution {
        guard let requestedNormalizedForm = WordbookNormalizationV1.normalizeLookupKey(
            requestedForm
        ),
              response.normalizedForm == requestedNormalizedForm,
              WordbookNormalizationV1.normalizeLookupKey(response.normalizedForm)
                == response.normalizedForm else {
            throw invalid("normalized form does not match the requested surface form")
        }
        guard WordbookNormalizationV1.normalizeLookupKey(response.form)
                == response.normalizedForm else {
            throw invalid("surface form does not match normalized form")
        }
        guard validStableID(response.senseID) else {
            throw invalid("sense ID is not a supported stable ID")
        }
        guard WordbookNormalizationV1.normalizeLookupKey(response.lemma) != nil else {
            throw invalid("lemma is empty")
        }
        guard allowedPartsOfSpeech.contains(response.partOfSpeech) else {
            throw invalid("part of speech is unsupported")
        }

        let explanation = try validatedExplanation(
            response.explanation,
            expectedSenseID: response.senseID,
            expectedPartOfSpeech: response.partOfSpeech
        )
        guard !response.forms.isEmpty else {
            throw invalid("forms are empty")
        }

        var seenForms = Set<String>()
        var rankedRecords: [(rank: Int, record: OfflineVocabularyExplanation)] = []
        for form in response.forms {
            guard form.rank >= 0 else {
                throw invalid("form rank is negative")
            }
            guard WordbookNormalizationV1.normalizeLookupKey(form.normalizedForm)
                    == form.normalizedForm,
                  WordbookNormalizationV1.normalizeLookupKey(form.displayForm)
                    == form.normalizedForm else {
                throw invalid("form spelling and normalization disagree")
            }
            guard seenForms.insert(form.normalizedForm).inserted else {
                throw invalid("forms repeat normalized spelling \(form.normalizedForm)")
            }
            guard !form.morphology.values.isEmpty,
                  form.morphology.values.allSatisfy({ !$0.isEmpty }) else {
                throw invalid("morphology for \(form.normalizedForm) is empty")
            }
            rankedRecords.append((
                rank: form.rank,
                record: OfflineVocabularyExplanation(
                    normalizedForm: form.normalizedForm,
                    displayForm: form.displayForm,
                    morphology: form.morphology.offlineValue,
                    senseID: response.senseID,
                    lemma: response.lemma,
                    explanationID: response.explanation.id,
                    contentHash: response.explanation.contentHash,
                    schemaVersion: response.explanation.schemaVersion,
                    explanation: explanation
                )
            ))
        }

        guard let primary = rankedRecords.first(where: {
            $0.record.normalizedForm == response.normalizedForm
        })?.record else {
            throw invalid("requested form has no morphology analysis")
        }
        guard primary.displayForm == response.form else {
            throw invalid("resolved surface form differs from its morphology row")
        }
        let records = rankedRecords.sorted { left, right in
            if left.rank != right.rank {
                return left.rank < right.rank
            }
            if left.record.normalizedForm != right.record.normalizedForm {
                return left.record.normalizedForm < right.record.normalizedForm
            }
            return left.record.displayForm < right.record.displayForm
        }.map(\.record)
        return ValidatedServerResolution(records: records, primary: primary)
    }

    static func feedback(
        _ response: FeedbackResponseDTO,
        event: ExplanationFeedbackEvent,
        lexicalContext: OfflineVocabularyExplanation
    ) throws -> ValidatedServerFeedbackReceipt {
        guard let responseEventID = UUID(uuidString: response.eventID),
              responseEventID == event.eventID else {
            throw invalid("feedback event ID does not match the queued event")
        }
        guard response.accepted else {
            throw invalid("feedback was not accepted")
        }
        guard let status = ExplanationReplacementStatus(
            rawValue: response.replacementStatus
        ) else {
            throw invalid("replacement status is unsupported")
        }

        let replacement: OfflineVocabularyExplanation?
        if let replacementDTO = response.replacement {
            guard event.requestReplacement,
                  status == .complete else {
                throw invalid("an unsolicited replacement was returned")
            }
            let explanation = try validatedExplanation(
                replacementDTO,
                expectedSenseID: event.senseID,
                expectedPartOfSpeech: lexicalContext.explanation.partOfSpeech
            )
            guard replacementDTO.id != event.explanationID else {
                throw invalid("replacement reuses the disliked explanation ID")
            }
            replacement = OfflineVocabularyExplanation(
                normalizedForm: lexicalContext.normalizedForm,
                displayForm: lexicalContext.displayForm,
                morphology: lexicalContext.morphology,
                senseID: lexicalContext.senseID,
                lemma: lexicalContext.lemma,
                explanationID: replacementDTO.id,
                contentHash: replacementDTO.contentHash,
                schemaVersion: replacementDTO.schemaVersion,
                explanation: explanation
            )
        } else {
            replacement = nil
        }

        switch status {
        case .notRequested:
            guard !event.requestReplacement,
                  replacement == nil,
                  response.failureCode == nil else {
                throw invalid("not-requested replacement receipt is inconsistent")
            }
        case .pending:
            guard event.requestReplacement,
                  replacement == nil,
                  response.failureCode == nil else {
                throw invalid("pending replacement receipt is inconsistent")
            }
        case .complete:
            guard event.requestReplacement,
                  replacement != nil,
                  response.failureCode == nil else {
                throw invalid("completed replacement receipt is inconsistent")
            }
        case .failed:
            guard event.requestReplacement,
                  replacement == nil,
                  response.failureCode?.isEmpty == false else {
                throw invalid("failed replacement receipt is inconsistent")
            }
        }

        return ValidatedServerFeedbackReceipt(
            eventID: responseEventID,
            replacementStatus: status,
            replacement: replacement,
            failureCode: response.failureCode
        )
    }

    private static func validatedExplanation(
        _ explanation: ExplanationDTO,
        expectedSenseID: String,
        expectedPartOfSpeech: String
    ) throws -> VocabularyExplanation {
        let content = explanation.content
        guard explanation.schemaVersion
                == ExplanationServerClient.supportedExplanationSchemaVersion else {
            throw invalid("explanation schema version is unsupported")
        }
        guard validStableID(explanation.senseID),
              explanation.senseID == expectedSenseID,
              content.senseID == expectedSenseID else {
            throw invalid("explanation sense identity changed")
        }
        guard explanation.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                == false else {
            throw invalid("explanation provenance is empty")
        }
        guard content.partOfSpeech == expectedPartOfSpeech,
              allowedPartsOfSpeech.contains(content.partOfSpeech) else {
            throw invalid("explanation part of speech changed")
        }
        guard !content.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !content.example.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.memoryAid.count <= 2,
              content.synonyms.count <= 3,
              content.memoryAid.allSatisfy({ !$0.isEmpty }),
              content.synonyms.allSatisfy({ !$0.isEmpty }),
              (content.memoryTechnique == nil) == content.memoryAid.isEmpty else {
            throw invalid("explanation payload is structurally incomplete")
        }

        let contentObject: [String: Any] = [
            "senseID": content.senseID,
            "partOfSpeech": content.partOfSpeech,
            "meaning": content.meaning,
            "memoryTechnique": content.memoryTechnique?.rawValue ?? NSNull(),
            "memoryAid": content.memoryAid,
            "example": content.example,
            "synonyms": content.synonyms,
        ]
        let canonicalContent = try canonicalJSON(contentObject)
        let expectedContentHash = sha256Hex(canonicalContent)
        guard explanation.contentHash == expectedContentHash else {
            throw invalid("content hash does not match the explanation payload")
        }
        let identityObject: [String: Any] = [
            "schemaVersion": explanation.schemaVersion,
            "senseID": explanation.senseID,
            "contentHash": explanation.contentHash,
        ]
        let expectedExplanationID = "exp_" + sha256Hex(try canonicalJSON(identityObject))
        guard explanation.id == expectedExplanationID else {
            throw invalid("explanation ID does not match immutable content identity")
        }

        return VocabularyExplanation(
            partOfSpeech: content.partOfSpeech,
            meaning: content.meaning,
            memoryTechnique: content.memoryTechnique,
            memoryAid: content.memoryAid,
            example: content.example,
            synonyms: content.synonyms
        )
    }

    private static func canonicalJSON(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw invalid("identity payload cannot be represented as JSON")
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw invalid("identity payload is not canonical JSON")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validStableID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...192).contains(scalars.count),
              scalars.first.map(isASCIILetterOrDigit) == true else {
            return false
        }
        return scalars.allSatisfy { scalar in
            isASCIILetterOrDigit(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == ":"
                || scalar == "-"
        }
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    private static func invalid(_ reason: String) -> ExplanationServerClientError {
        .invalidResponse(reason)
    }
}

// MARK: - Entry-first v3 service

struct EntryResolveContext: Codable, Equatable, Sendable {
    let text: String
    let targetStart: Int
    let targetLength: Int
    let offsetEncoding: String

    init(text: String, targetStart: Int, targetLength: Int) {
        self.text = text
        self.targetStart = targetStart
        self.targetLength = targetLength
        self.offsetEncoding = "utf8"
    }
}

struct EntryResolveRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let encounteredSurfaceForm: String
    let language: String
    let locale: String
    let context: EntryResolveContext?
    let clientContentVersion: String
    let normalizationVersion: Int
    let resolverContractVersion: Int
    let lessonSchemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let minimumReviewPolicyVersion: Int
    let minimumUsageSelectionPolicyVersion: Int
    let confirmedRareSpelling: Bool
}

enum EntryServerResult: Equatable, Sendable {
    case resolved(ResolvedWordEntry)
    case correctionRequired(EntryCorrectionResolution)
    case pending(EntryPendingResolution)
    case negative(EntryNegativeResolution)
    case unavailable(EntryUnavailableResolution)
}

struct EntryServerFeedbackReceipt: Equatable, Sendable {
    let eventID: UUID
    let accepted: Bool
    let replacementResult: EntryServerReplacementResult?
}

enum EntryServerReplacementResult: Equatable, Sendable {
    case complete(EntryLessonReplacement)
    case pending(EntryPendingResolution)
    case failed(String)
    case unavailable(EntryUnavailableResolution)
}

protocol EntryServerServing: Sendable {
    func resolve(_ request: EntryResolveRequest) async throws -> EntryServerResult
    func jobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?
    ) async throws -> EntryServerResult
    func sendFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerFeedbackReceipt
    func requestReplacement(
        for event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult
    func replacementJobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult
}

extension EntryServerServing {
    func jobStatus(jobID: String) async throws -> EntryServerResult {
        try await jobStatus(jobID: jobID, expectedCanonicalKeyHash: nil)
    }

    func replacementJobStatus(
        jobID: String,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult {
        try await replacementJobStatus(
            jobID: jobID,
            expectedCanonicalKeyHash: nil,
            baseEntry: baseEntry
        )
    }
}

/// Strict v3 client. It exposes only complete learner-ready Entry records and
/// bounded miss outcomes; no lemma, morphology, source sense or teaching brief
/// crosses this boundary.
final class EntryServerClient: EntryServerServing, @unchecked Sendable {
    private let baseURL: URL
    private let transport: any ExplanationServerTransport
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        baseURL: URL,
        transport: any ExplanationServerTransport = URLSessionExplanationServerTransport(),
        requestTimeout: TimeInterval = 20,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              baseURL.host != nil else {
            throw ExplanationServerClientError.invalidBaseURL(baseURL)
        }
        self.baseURL = baseURL
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.now = now
    }

    func resolve(_ request: EntryResolveRequest) async throws -> EntryServerResult {
        try Self.validate(request)
        let data = try await send(
            method: "POST",
            pathComponents: ["v3", "entries", "resolve"],
            body: request,
            additionalAcceptedStatusCodes: [503]
        )
        return try decodeResult(
            data,
            expectedSurfaceForm: request.encounteredSurfaceForm,
            expectedLanguage: request.language,
            expectedLocale: request.locale
        )
    }

    func jobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?
    ) async throws -> EntryServerResult {
        guard Self.validStableID(jobID) else {
            throw ExplanationServerClientError.invalidRequest("job ID is invalid")
        }
        let data = try await send(
            method: "GET",
            pathComponents: ["v3", "jobs", jobID],
            bodyData: nil
        )
        let result = try decodeJobResult(
            data,
            expectedJobID: jobID,
            expectedCanonicalKeyHash: expectedCanonicalKeyHash
        )
        if case .pending(let pending) = result, pending.jobID != jobID {
            throw ExplanationServerClientError.invalidResponse(
                "job response changed the requested job identity"
            )
        }
        return result
    }

    func sendFeedback(
        _ event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerFeedbackReceipt {
        try Self.validate(event)
        try Self.validate(event, against: baseEntry)
        let data = try await send(
            method: "POST",
            pathComponents: [
                "v3", "entries", event.entryID, "usages", event.entryUsageID,
                "explanations", event.explanationID, "feedback",
            ],
            body: EntryFeedbackRequestDTO(event: event)
        )
        let response: EntryFeedbackResponseDTO = try decode(data)
        guard let eventID = UUID(uuidString: response.eventID),
              eventID == event.eventID,
              response.accepted else {
            throw ExplanationServerClientError.invalidResponse(
                "feedback acknowledgement does not match the queued event"
            )
        }
        let replacementResult: EntryServerReplacementResult?
        if let replacement = response.replacement {
            guard event.requestReplacement else {
                throw ExplanationServerClientError.invalidResponse(
                    "helpful feedback unexpectedly started replacement work"
                )
            }
            replacementResult = try decodeReplacementJob(
                replacement,
                baseEntry: baseEntry,
                expectedEntryUsageID: event.entryUsageID
            )
        } else {
            guard !event.requestReplacement else {
                throw ExplanationServerClientError.invalidResponse(
                    "replacement feedback did not return its durable job"
                )
            }
            replacementResult = nil
        }
        return EntryServerFeedbackReceipt(
            eventID: eventID,
            accepted: true,
            replacementResult: replacementResult
        )
    }

    func requestReplacement(
        for event: EntryFeedbackEvent,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult {
        try Self.validate(event)
        try Self.validate(event, against: baseEntry)
        guard event.requestReplacement, event.rating == .notHelpful else {
            throw ExplanationServerClientError.invalidRequest(
                "replacement request does not match the displayed Entry and Usage"
            )
        }
        let data = try await send(
            method: "POST",
            pathComponents: [
                "v3", "entries", event.entryID, "usages", event.entryUsageID,
                "replacements",
            ],
            body: EntryReplacementRequestDTO(event: event, baseEntry: baseEntry)
        )
        let job: EntryJobDTO = try decode(data)
        return try decodeReplacementJob(
            job,
            baseEntry: baseEntry,
            expectedEntryUsageID: event.entryUsageID
        )
    }

    func replacementJobStatus(
        jobID: String,
        expectedCanonicalKeyHash: String?,
        baseEntry: ResolvedWordEntry
    ) async throws -> EntryServerReplacementResult {
        guard Self.validStableID(jobID) else {
            throw ExplanationServerClientError.invalidRequest("job ID is invalid")
        }
        let data = try await send(
            method: "GET",
            pathComponents: ["v3", "jobs", jobID],
            bodyData: nil
        )
        let job: EntryJobDTO = try decode(data)
        guard job.jobID == jobID,
              expectedCanonicalKeyHash.map({ job.canonicalKeyHash == $0 }) ?? true else {
            throw ExplanationServerClientError.invalidResponse(
                "replacement job response changed its durable work identity"
            )
        }
        let result = try decodeReplacementJob(
            job,
            baseEntry: baseEntry,
            expectedEntryUsageID: nil
        )
        return result
    }

    private func decodeResult(
        _ data: Data,
        expectedSurfaceForm: String?,
        expectedLanguage: String?,
        expectedLocale: String?
    ) throws -> EntryServerResult {
        let discriminator: EntryResultDiscriminatorDTO = try decode(data)
        switch discriminator.result {
        case "resolved":
            let entry: ResolvedWordEntry = try decode(data)
            return .resolved(try validatedEntry(
                entry,
                expectedSurfaceForm: expectedSurfaceForm,
                expectedLanguage: expectedLanguage,
                expectedLocale: expectedLocale
            ))
        case "correctionRequired":
            let response: EntryCorrectionDTO = try decode(data)
            return .correctionRequired(try validatedCorrections(response.corrections))
        case "pending":
            let response: EntryPendingDTO = try decode(data)
            return .pending(try validatedPending(response.job, expectedKind: "resolveEntry"))
        case "negative":
            let response: EntryNegativeDTO = try decode(data)
            return .negative(try validatedNegative(response.negative))
        case "unavailable":
            let response: EntryUnavailableDTO = try decode(data)
            return .unavailable(try validatedUnavailable(response.unavailable))
        default:
            throw ExplanationServerClientError.invalidResponse(
                "Entry result \(discriminator.result) is unsupported"
            )
        }
    }

    private func decodeJobResult(
        _ data: Data,
        expectedJobID: String? = nil,
        expectedCanonicalKeyHash: String? = nil
    ) throws -> EntryServerResult {
        let job: EntryJobDTO = try decode(data)
        guard expectedJobID.map({ job.jobID == $0 }) ?? true,
              expectedCanonicalKeyHash.map({ job.canonicalKeyHash == $0 }) ?? true else {
            throw ExplanationServerClientError.invalidResponse(
                "job response changed its durable work identity"
            )
        }
        try validateJobMetadata(job, expectedKind: "resolveEntry")
        switch job.state {
        case "queued", "running":
            return .pending(try validatedPending(job, expectedKind: "resolveEntry"))
        case "succeeded":
            guard let entry = job.entry, job.replacement == nil,
                  job.corrections.isEmpty, job.negative == nil,
                  job.failureCode == nil else {
                throw ExplanationServerClientError.invalidResponse(
                    "successful resolve job does not contain exactly one complete Entry"
                )
            }
            return .resolved(try validatedEntry(
                entry,
                expectedSurfaceForm: nil,
                expectedLanguage: nil,
                expectedLocale: nil
            ))
        case "negative":
            guard job.entry == nil, job.replacement == nil, job.failureCode == nil else {
                throw ExplanationServerClientError.invalidResponse(
                    "negative resolve job exposes a success or failure arm"
                )
            }
            if let negative = job.negative, job.corrections.isEmpty {
                return .negative(try validatedNegative(negative))
            }
            if job.negative == nil, !job.corrections.isEmpty {
                return .correctionRequired(try validatedCorrections(job.corrections))
            }
            throw ExplanationServerClientError.invalidResponse(
                "negative resolve job does not contain exactly one bounded outcome"
            )
        case "failed":
            guard let failureCode = job.failureCode, !failureCode.isEmpty,
                  job.entry == nil, job.replacement == nil,
                  job.corrections.isEmpty, job.negative == nil else {
                throw ExplanationServerClientError.invalidResponse(
                    "failed resolve job has inconsistent terminal fields"
                )
            }
            return .unavailable(EntryUnavailableResolution(
                reason: failureCode,
                retryAfter: nil
            ))
        default:
            throw ExplanationServerClientError.invalidResponse(
                "job state \(job.state) is unsupported"
            )
        }
    }

    private func decodeReplacementJob(
        _ job: EntryJobDTO,
        baseEntry: ResolvedWordEntry,
        expectedEntryUsageID: String?
    ) throws -> EntryServerReplacementResult {
        try validateJobMetadata(job, expectedKind: "replaceExplanation")
        switch job.state {
        case "queued", "running":
            return .pending(try validatedPending(
                job,
                expectedKind: "replaceExplanation"
            ))
        case "succeeded":
            guard let replacement = job.replacement,
                  job.entry == nil, job.corrections.isEmpty,
                  job.negative == nil, job.failureCode == nil,
                  expectedEntryUsageID.map({
                      replacement.entryUsageID == $0
                  }) ?? true else {
                throw ExplanationServerClientError.invalidResponse(
                    "successful replacement job does not contain its bound lesson sidecar"
                )
            }
            try Self.validate(replacement, against: baseEntry)
            return .complete(replacement)
        case "negative":
            guard job.entry == nil, job.replacement == nil,
                  job.corrections.isEmpty, job.failureCode == nil,
                  let negative = job.negative,
                  !negative.reasonCode.isEmpty else {
                throw ExplanationServerClientError.invalidResponse(
                    "negative replacement job has inconsistent terminal fields"
                )
            }
            return .failed(negative.reasonCode)
        case "failed":
            guard let failureCode = job.failureCode, !failureCode.isEmpty,
                  job.entry == nil, job.replacement == nil,
                  job.corrections.isEmpty, job.negative == nil else {
                throw ExplanationServerClientError.invalidResponse(
                    "failed replacement job has inconsistent terminal fields"
                )
            }
            return .failed(failureCode)
        default:
            throw ExplanationServerClientError.invalidResponse(
                "replacement job state \(job.state) is unsupported"
            )
        }
    }

    private func validatedEntry(
        _ entry: ResolvedWordEntry,
        expectedSurfaceForm: String?,
        expectedLanguage: String?,
        expectedLocale: String?
    ) throws -> ResolvedWordEntry {
        let surface = expectedSurfaceForm ?? entry.encounteredSurfaceForm
        do {
            try EntryContractValidator.validate(entry, expectedSurfaceForm: surface)
        } catch {
            throw ExplanationServerClientError.invalidResponse(
                "resolved Entry failed validation: \(error.localizedDescription)"
            )
        }
        let trustMatchesCoverage = switch entry.coverageState {
        case .releaseReviewedComplete:
            entry.usages.allSatisfy({ $0.trustState == .releaseReviewed })
        case .serverReviewedComplete:
            entry.usages.allSatisfy({ $0.trustState == .serverReviewed })
        }
        guard trustMatchesCoverage,
              expectedSurfaceForm.map({ entry.encounteredSurfaceForm == $0 }) ?? true,
              expectedLanguage.map({ entry.language == $0.lowercased() }) ?? true,
              expectedLocale.map({
                  Self.normalizedLocale(entry.locale) == Self.normalizedLocale($0)
              }) ?? true,
              Self.validStableID(entry.entryID),
              entry.usages.allSatisfy({ Self.validStableID($0.entryUsageID) }),
              !entry.contentVersion.isEmpty,
              !entry.baseContentVersion.isEmpty else {
            throw ExplanationServerClientError.invalidResponse(
                "resolved Entry is not a complete compatible reviewed snapshot"
            )
        }
        return entry
    }

    private func validatedCorrections(
        _ corrections: [EntryCorrectionCandidateDTO]
    ) throws -> EntryCorrectionResolution {
        var seen = Set<String>()
        var previousConfidence = 2.0
        guard !corrections.isEmpty, corrections.count <= 5 else {
            throw ExplanationServerClientError.invalidResponse(
                "correction result must contain one to five candidates"
            )
        }
        for correction in corrections {
            let normalized = WordbookNormalizationV1.normalizeLookupKey(
                correction.surfaceForm
            )
            guard let normalized,
                  normalized == correction.normalizedForm,
                  seen.insert(normalized).inserted,
                  (0...1).contains(correction.confidence),
                  correction.confidence <= previousConfidence else {
                throw ExplanationServerClientError.invalidResponse(
                    "correction candidates are invalid or not ranked"
                )
            }
            previousConfidence = correction.confidence
        }
        // The public correction arm is intentionally evidence-only and has no
        // server cache policy. Keep it finite in the writable client overlay
        // so a future corrected catalog or verifier result can take effect.
        return EntryCorrectionResolution(
            candidates: corrections.map(\.surfaceForm),
            expiresAt: now().addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    private func validatedNegative(
        _ response: EntryNegativePayloadDTO
    ) throws -> EntryNegativeResolution {
        guard !response.reasonCode.isEmpty, response.expiresAt.value > now() else {
            throw ExplanationServerClientError.invalidResponse(
                "negative result is empty or already expired"
            )
        }
        return EntryNegativeResolution(
            reason: response.reasonCode,
            expiresAt: response.expiresAt.value
        )
    }

    private func validatedPending(
        _ job: EntryJobDTO,
        expectedKind: String
    ) throws -> EntryPendingResolution {
        try validateJobMetadata(job, expectedKind: expectedKind)
        guard job.state == "queued" || job.state == "running" else {
            throw ExplanationServerClientError.invalidResponse(
                "pending result contains a terminal job"
            )
        }
        return EntryPendingResolution(
            jobID: job.jobID,
            canonicalKeyHash: job.canonicalKeyHash,
            jobKind: job.kind,
            nextCheckAt: job.nextCheckAt?.value
                ?? now().addingTimeInterval(2),
            checkCount: job.candidateAttempts + job.reviewAttempts
        )
    }

    private func validateJobMetadata(
        _ job: EntryJobDTO,
        expectedKind: String
    ) throws {
        let duration = job.deadlineAt.value.timeIntervalSince(job.createdAt.value)
        guard Self.validStableID(job.jobID),
              Self.validHash(job.canonicalKeyHash),
              job.kind == expectedKind,
              job.maximumCandidateAttempts == 2,
              job.maximumReviewAttempts == 2,
              (0...job.maximumCandidateAttempts).contains(job.candidateAttempts),
              (0...job.maximumReviewAttempts).contains(job.reviewAttempts),
              job.updatedAt.value >= job.createdAt.value,
              duration > 0, duration <= 180.001 else {
            throw ExplanationServerClientError.invalidResponse(
                "job metadata or bounded-attempt policy is invalid"
            )
        }
    }

    private func validatedUnavailable(
        _ response: EntryUnavailablePayloadDTO
    ) throws -> EntryUnavailableResolution {
        guard !response.reasonCode.isEmpty,
              response.retryAfterSeconds.map({ $0 >= 0 }) ?? true else {
            throw ExplanationServerClientError.invalidResponse(
                "unavailable result has no reason"
            )
        }
        return EntryUnavailableResolution(
            reason: response.reasonCode,
            retryAfter: response.retryAfterSeconds.map {
                now().addingTimeInterval(TimeInterval($0))
            }
        )
    }

    private func send<Body: Encodable>(
        method: String,
        pathComponents: [String],
        body: Body,
        additionalAcceptedStatusCodes: Set<Int> = []
    ) async throws -> Data {
        let bodyData: Data
        do {
            bodyData = try Self.makeEncoder().encode(body)
        } catch {
            throw ExplanationServerClientError.invalidRequest(error.localizedDescription)
        }
        return try await send(
            method: method,
            pathComponents: pathComponents,
            bodyData: bodyData,
            additionalAcceptedStatusCodes: additionalAcceptedStatusCodes
        )
    }

    private func send(
        method: String,
        pathComponents: [String],
        bodyData: Data?,
        additionalAcceptedStatusCodes: Set<Int> = []
    ) async throws -> Data {
        var url = baseURL
        pathComponents.forEach { url.appendPathComponent($0) }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Wordbook/3.0", forHTTPHeaderField: "User-Agent")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let transported: ExplanationTransportResponse
        do {
            transported = try await transport.send(request)
        } catch {
            throw ExplanationServerClientError.transportFailed(error.localizedDescription)
        }
        let isSuccess = (200..<300).contains(transported.statusCode)
        guard isSuccess
                || additionalAcceptedStatusCodes.contains(transported.statusCode) else {
            throw ExplanationServerClientError.httpFailure(
                statusCode: transported.statusCode
            )
        }
        guard transported.data.count <= 4 * 1_024 * 1_024 else {
            throw ExplanationServerClientError.responseTooLarge(transported.data.count)
        }
        if !isSuccess {
            guard let discriminator = try? Self.makeDecoder().decode(
                EntryResultDiscriminatorDTO.self,
                from: transported.data
            ), discriminator.result == "unavailable" else {
                throw ExplanationServerClientError.httpFailure(
                    statusCode: transported.statusCode
                )
            }
        }
        return transported.data
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try Self.makeDecoder().decode(Value.self, from: data)
        } catch let error as ExplanationServerClientError {
            throw error
        } catch {
            throw ExplanationServerClientError.invalidResponse(error.localizedDescription)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func validate(_ request: EntryResolveRequest) throws {
        let normalized = WordbookNormalizationV1.normalizeLookupKey(
            request.encounteredSurfaceForm
        )
        guard let normalized,
              request.language == "en",
              EntryContractValidator.isCanonicalLocale(request.locale),
              request.normalizationVersion == EntryContractValidator.normalizationVersion,
              request.resolverContractVersion == EntryContractValidator.resolverContractVersion,
              request.lessonSchemaVersion == EntryContractValidator.lessonSchemaVersion,
              request.lessonContractVersion == EntryContractValidator.lessonContractVersion,
              request.validatorVersion == EntryContractValidator.validatorVersion,
              request.minimumReviewPolicyVersion
                == EntryContractValidator.minimumReviewPolicyVersion,
              request.minimumUsageSelectionPolicyVersion
                == EntryContractValidator.usageSelectionPolicyVersion else {
            throw ExplanationServerClientError.invalidRequest(
                "surface form or contract versions are invalid"
            )
        }
        if let context = request.context {
            guard context.offsetEncoding == "utf8", context.targetStart >= 0,
                  context.targetLength > 0 else {
                throw ExplanationServerClientError.invalidRequest(
                    "context offsets are invalid"
                )
            }
            let bytes = Array(context.text.utf8)
            let end = context.targetStart + context.targetLength
            guard end <= bytes.count,
                  let target = String(
                    data: Data(bytes[context.targetStart..<end]),
                    encoding: .utf8
                  ),
                  WordbookNormalizationV1.normalizeLookupKey(target) == normalized else {
                throw ExplanationServerClientError.invalidRequest(
                    "context target does not match the encountered form"
                )
            }
        }
    }

    private static func validate(_ event: EntryFeedbackEvent) throws {
        guard validStableID(event.entryID), validStableID(event.entryUsageID),
              event.explanationID.hasPrefix("exp_"),
              validHash(String(event.explanationID.dropFirst(4))),
              WordbookNormalizationV1.normalizeLookupKey(event.normalizedForm)
                == event.normalizedForm,
              event.language == "en",
              EntryContractValidator.isCanonicalLocale(event.locale),
              !event.contentVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              !event.baseContentVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              event.baseEntryRevision > 0,
              event.schemaVersion == EntryContractValidator.lessonSchemaVersion,
              event.lessonContractVersion
                == EntryContractValidator.lessonContractVersion,
              event.validatorVersion >= EntryContractValidator.validatorVersion,
              event.reviewPolicyVersion
                >= EntryContractValidator.minimumReviewPolicyVersion,
              event.excludedExplanationIDs.allSatisfy({ value in
                  value.hasPrefix("exp_")
                    && validHash(String(value.dropFirst(4)))
              }),
              event.attemptCount >= 0,
              !event.requestReplacement || event.rating == .notHelpful else {
            throw ExplanationServerClientError.invalidRequest(
                "feedback identity or replacement intent is invalid"
            )
        }
    }

    private static func validate(
        _ event: EntryFeedbackEvent,
        against baseEntry: ResolvedWordEntry
    ) throws {
        do {
			try EntryContractValidator.validateMaterializedView(
				baseEntry,
                expectedSurfaceForm: baseEntry.encounteredSurfaceForm
            )
        } catch {
            throw ExplanationServerClientError.invalidRequest(
                "displayed Entry is invalid: \(error.localizedDescription)"
            )
        }
        guard event.entryID == baseEntry.entryID,
              event.normalizedForm == baseEntry.normalizedForm,
              event.language == baseEntry.language,
              event.locale == baseEntry.locale,
              event.contentVersion == baseEntry.contentVersion,
              event.baseContentVersion == baseEntry.contentVersion,
              event.baseEntryRevision == baseEntry.entryRevision,
              let usage = baseEntry.usages.first(where: {
                  $0.entryUsageID == event.entryUsageID
                    && $0.explanationID == event.explanationID
              }),
              usage.schemaVersion == event.schemaVersion,
              usage.lessonContractVersion == event.lessonContractVersion,
              usage.validatorVersion == event.validatorVersion,
              usage.reviewPolicyVersion == event.reviewPolicyVersion else {
            throw ExplanationServerClientError.invalidRequest(
                "feedback does not match the exact displayed Entry snapshot"
            )
        }
    }

    private static func validate(
        _ replacement: EntryLessonReplacement,
        against entry: ResolvedWordEntry
    ) throws {
        guard replacement.entryID == entry.entryID,
              replacement.locale == entry.locale,
              replacement.baseEntryRevision == entry.entryRevision,
              replacement.baseContentVersion == entry.contentVersion,
              replacement.trustState == .serverReviewed,
              let base = entry.usages.first(where: {
                  $0.entryUsageID == replacement.entryUsageID
              }),
              base.explanationID == replacement.baseExplanationID,
              replacement.explanationID != base.explanationID,
              replacement.schemaVersion == base.schemaVersion,
              replacement.lessonContractVersion == base.lessonContractVersion,
              replacement.validatorVersion == base.validatorVersion,
              replacement.reviewPolicyVersion >= base.reviewPolicyVersion,
              replacement.contentRevision == base.contentRevision + 1 else {
            throw ExplanationServerClientError.invalidResponse(
                "replacement changed its Entry, Usage, or base binding"
            )
        }
        let usage = UsageLesson(
            entryUsageID: base.entryUsageID,
            learnerLabel: base.learnerLabel,
            partOfSpeechLabel: base.partOfSpeechLabel,
            pronunciations: base.pronunciations,
            formRelationLabel: base.formRelationLabel,
            contextVector: base.contextVector,
            displayOrder: base.displayOrder,
            commonnessRank: base.commonnessRank,
            isCore: base.isCore,
            explanationID: replacement.explanationID,
            contentHash: replacement.contentHash,
            schemaVersion: replacement.schemaVersion,
            lessonContractVersion: replacement.lessonContractVersion,
            validatorVersion: replacement.validatorVersion,
            reviewPolicyVersion: replacement.reviewPolicyVersion,
            contentRevision: replacement.contentRevision,
            trustState: replacement.trustState,
            content: replacement.content
        )
        do {
            try EntryContractValidator.validateContentIdentity(
                usage,
                entryID: entry.entryID,
                normalizedForm: entry.normalizedForm,
                language: entry.language,
                locale: entry.locale
            )
        } catch {
            throw ExplanationServerClientError.invalidResponse(
                "replacement immutable identity is invalid: \(error.localizedDescription)"
            )
        }
    }

    private static func validHash(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy({ $0.isHexDigit })
    }

    private static func validStableID(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...192).contains(scalars.count),
              scalars.first.map(isASCIILetterOrDigit) == true else { return false }
        return scalars.allSatisfy { scalar in
            isASCIILetterOrDigit(scalar)
                || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    private static func isASCIILetterOrDigit(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }

    private static func normalizedLocale(_ value: String) -> String {
        EntryContractValidator.canonicalLocale(value)
    }
}

private struct EntryResultDiscriminatorDTO: Decodable {
    let result: String
}

private struct EntryCorrectionDTO: Decodable {
    let corrections: [EntryCorrectionCandidateDTO]
}

private struct EntryPendingDTO: Decodable {
    let job: EntryJobDTO
}

private struct EntryNegativeDTO: Decodable {
    let negative: EntryNegativePayloadDTO
}

private struct EntryUnavailableDTO: Decodable {
    let unavailable: EntryUnavailablePayloadDTO
}

private struct EntryCorrectionCandidateDTO: Decodable {
    let surfaceForm: String
    let normalizedForm: String
    let confidence: Double
}

private struct EntryNegativePayloadDTO: Decodable {
    let reasonCode: String
    let expiresAt: EntryServerDate
    let retryAfterSeconds: Int?
}

private struct EntryUnavailablePayloadDTO: Decodable {
    let reasonCode: String
    let retryAfterSeconds: Int?
}

private struct EntryJobDTO: Decodable {
    let jobID: String
    let kind: String
    let canonicalKeyHash: String
    let state: String
    let candidateAttempts: Int
    let maximumCandidateAttempts: Int
    let reviewAttempts: Int
    let maximumReviewAttempts: Int
    let createdAt: EntryServerDate
    let updatedAt: EntryServerDate
    let deadlineAt: EntryServerDate
    let nextCheckAt: EntryServerDate?
    let entry: ResolvedWordEntry?
    let replacement: EntryLessonReplacement?
    let corrections: [EntryCorrectionCandidateDTO]
    let negative: EntryNegativePayloadDTO?
    let failureCode: String?

    private enum CodingKeys: String, CodingKey {
        case jobID, kind, canonicalKeyHash, state
        case candidateAttempts, maximumCandidateAttempts
        case reviewAttempts, maximumReviewAttempts
        case createdAt, updatedAt, deadlineAt, nextCheckAt
        case entry, replacement, corrections, negative, failureCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        kind = try container.decode(String.self, forKey: .kind)
        canonicalKeyHash = try container.decode(String.self, forKey: .canonicalKeyHash)
        state = try container.decode(String.self, forKey: .state)
        candidateAttempts = try container.decode(Int.self, forKey: .candidateAttempts)
        maximumCandidateAttempts = try container.decode(
            Int.self,
            forKey: .maximumCandidateAttempts
        )
        reviewAttempts = try container.decode(Int.self, forKey: .reviewAttempts)
        maximumReviewAttempts = try container.decode(
            Int.self,
            forKey: .maximumReviewAttempts
        )
        createdAt = try container.decode(EntryServerDate.self, forKey: .createdAt)
        updatedAt = try container.decode(EntryServerDate.self, forKey: .updatedAt)
        deadlineAt = try container.decode(EntryServerDate.self, forKey: .deadlineAt)
        nextCheckAt = try container.decodeIfPresent(
            EntryServerDate.self,
            forKey: .nextCheckAt
        )
        entry = try container.decodeIfPresent(ResolvedWordEntry.self, forKey: .entry)
        replacement = try container.decodeIfPresent(
            EntryLessonReplacement.self,
            forKey: .replacement
        )
        corrections = try container.decodeIfPresent(
            [EntryCorrectionCandidateDTO].self,
            forKey: .corrections
        ) ?? []
        negative = try container.decodeIfPresent(
            EntryNegativePayloadDTO.self,
            forKey: .negative
        )
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
    }
}

private struct EntryFeedbackRequestDTO: Encodable {
    let eventID: String
    let locale: String
    let rating: String
    let component: String
    let contentVersion: String
    let appVersion: String
    let schemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let reviewPolicyVersion: Int
    let requestReplacement: Bool
    let baseEntryRevision: Int
    let baseContentVersion: String
    let excludedExplanationIDs: [String]

    init(event: EntryFeedbackEvent) {
        let recordedAppVersion = event.appVersion?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        eventID = event.eventID.uuidString.lowercased()
        locale = event.locale
        rating = event.rating.rawValue
        component = event.component.rawValue
        contentVersion = event.contentVersion
        appVersion = recordedAppVersion?.isEmpty == false
            ? recordedAppVersion!
            : "unknown"
        schemaVersion = event.schemaVersion
        lessonContractVersion = event.lessonContractVersion
        validatorVersion = event.validatorVersion
        reviewPolicyVersion = event.reviewPolicyVersion
        requestReplacement = event.requestReplacement
        baseEntryRevision = event.baseEntryRevision
        baseContentVersion = event.baseContentVersion
        excludedExplanationIDs = Array(
            Set(event.excludedExplanationIDs + (
                event.requestReplacement ? [event.explanationID] : []
            ))
        ).sorted()
    }
}

private struct EntryFeedbackResponseDTO: Decodable {
    let eventID: String
    let accepted: Bool
    let replacement: EntryJobDTO?
}

private struct EntryReplacementRequestDTO: Encodable {
    let requestID: String
    let locale: String
    let baseExplanationID: String
    let dislikedComponent: String
    let excludedExplanationIDs: [String]
    let baseEntryRevision: Int
    let baseContentVersion: String
    let normalizationVersion: Int
    let resolverContractVersion: Int
    let lessonSchemaVersion: Int
    let lessonContractVersion: Int
    let validatorVersion: Int
    let minimumReviewPolicyVersion: Int

    init(event: EntryFeedbackEvent, baseEntry: ResolvedWordEntry) {
        requestID = event.eventID.uuidString.lowercased() + ".replacement"
        locale = event.locale
        baseExplanationID = event.explanationID
        dislikedComponent = event.component.rawValue
        excludedExplanationIDs = Array(
            Set(event.excludedExplanationIDs + [event.explanationID])
        ).sorted()
        baseEntryRevision = event.baseEntryRevision
        baseContentVersion = event.baseContentVersion
        normalizationVersion = baseEntry.normalizationVersion
        resolverContractVersion = baseEntry.resolverContractVersion
        lessonSchemaVersion = event.schemaVersion
        lessonContractVersion = event.lessonContractVersion
        validatorVersion = event.validatorVersion
        minimumReviewPolicyVersion = event.reviewPolicyVersion
    }
}

private struct EntryServerDate: Decodable {
    let value: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Double.self) {
            value = Date(timeIntervalSince1970: milliseconds / 1_000)
            return
        }
        let string = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) {
            value = parsed
            return
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let parsed = basic.date(from: string) {
            value = parsed
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "expected an ISO-8601 date or epoch milliseconds"
        )
    }
}
