//
//  CardViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation
import Combine
#if os(iOS) || os(watchOS)
import WatchConnectivity
#endif

struct WikipediaSummary: Identifiable, Equatable, Sendable {
    let title: String
    let extract: String
    let url: URL

    var id: String { url.absoluteString }
}

enum ExplanationFeedbackControlState: Equatable {
    case available
    case sending
    case accepted
    case queued
    case replacementPending
    case replacementUnavailable
    case uncertain

    var isLocked: Bool {
        self != .available
    }

    var isSelected: Bool {
        switch self {
        case .accepted, .queued, .replacementPending, .replacementUnavailable:
            return true
        case .available, .sending, .uncertain:
            return false
        }
    }

    var accessibilityValue: String {
        switch self {
        case .available:
            return "Available"
        case .sending:
            return "In progress"
        case .accepted:
            return "Submitted"
        case .queued:
            return "Queued for delivery"
        case .replacementPending:
            return "Replacement pending"
        case .replacementUnavailable:
            return "No replacement available"
        case .uncertain:
            return "Request status unavailable"
        }
    }
}

private enum WikipediaClient {
    private struct SearchResponse: Decodable {
        let query: Query?

        struct Query: Decodable {
            let pages: [Page]
        }

        struct Page: Decodable {
            let index: Int?
            let namespace: Int
            let title: String
            let extract: String?
            let fullURL: String?
            let pageProperties: [String: String]?

            enum CodingKeys: String, CodingKey {
                case index
                case namespace = "ns"
                case title
                case extract
                case fullURL = "fullurl"
                case pageProperties = "pageprops"
            }
        }
    }

    static func summary(for word: String) async throws -> WikipediaSummary? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: word),
            URLQueryItem(name: "gsrlimit", value: "5"),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "prop", value: "extracts|info|pageprops"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 15
        )
        request.setValue(
            "Wordbook/1.0 (https://wordbook.cool)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            return nil
        }

        let pages = try JSONDecoder().decode(SearchResponse.self, from: data)
            .query?.pages ?? []
        let page = pages
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
            .first { page in
                guard page.namespace == 0,
                      page.pageProperties?["disambiguation"] == nil,
                      let extract = page.extract else { return false }
                let normalized = extract.lowercased()
                return !normalized.contains("may refer to")
                    && !normalized.contains("can refer to")
            }
        guard let page,
              let rawExtract = page.extract,
              let rawURL = page.fullURL,
              let articleURL = URL(string: rawURL) else {
            return nil
        }

        let extract = rawExtract
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !extract.isEmpty else { return nil }
        return WikipediaSummary(title: page.title, extract: extract, url: articleURL)
    }
}

@MainActor
final class CardViewModel: ObservableObject {
    #if !os(watchOS)
    private static let pendingPollWindow: TimeInterval = 210
    #endif

    @Published var word = ""
    @Published private(set) var alsoKnownAs: String?
    @Published private(set) var explanationState: ExplanationLoadState = .idle
    @Published private(set) var wordEntryState: WordEntryLoadState = .idle
    @Published private(set) var showsAllEntryUsages = false
    @Published private(set) var wikipediaSummary: WikipediaSummary?
    @Published private(set) var explanationFeedbackMessage: String?
    @Published private(set) var explanationFeedbackInFlight = false
    @Published private(set) var likeFeedbackState: ExplanationFeedbackControlState = .available
    @Published private(set) var meaningFeedbackState: ExplanationFeedbackControlState = .available
    @Published private(set) var memoryAidFeedbackState: ExplanationFeedbackControlState = .available
    @Published var perf = UserPreferences.shared

    private var explanationTask: Task<Void, Never>?
    private var explanationRequest = UUID()
    private var rareSpellingConfirmationAttempted = false
    private var wikipediaTask: Task<Void, Never>?
    private var wikipediaRequest = UUID()
    #if os(watchOS)
    private var watchSnapshotCancellable: AnyCancellable?
    #endif
    #if !os(watchOS)
    private var resolvedEntryResolution: ResolvedEntryResolution?
    @Published private var entryFeedbackStates: [String: ExplanationFeedbackControlState] = [:]
    @Published private var entryFeedbackMessages: [String: String] = [:]

    private enum FeedbackAction {
        case like
        case meaningReplacement
        case memoryAidReplacement
    }

    private var curatedResolution: ExplanationResolution?
    private var feedbackTask: Task<Void, Never>?
    private var feedbackExplanationID: String?
    private var feedbackActionInFlight: FeedbackAction?
    #endif

    init(_ word: String = "") {
        self.word = word
        #if os(iOS) || os(watchOS)
        WatchEntrySnapshotBridge.shared.activate()
        #endif
        #if os(watchOS)
        watchSnapshotCancellable = NotificationCenter.default.publisher(
            for: .watchEntrySnapshotDidChange
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adoptWatchSnapshotIfAvailable()
            }
        }
        #endif
    }

    var translationLanguageCode: String {
        perf.translationLanguageCode
    }

    var explanation: VocabularyExplanation? {
        guard case .ready(let explanation) = explanationState else { return nil }
        return explanation
    }

    var resolvedEntry: ResolvedWordEntry? {
        guard case .ready(let entry) = wordEntryState else { return nil }
        return entry
    }

    var preferredPronunciationPhonemes: String? {
        resolvedEntry?.preferredPronunciationPhonemes
    }

    var visibleEntryUsages: [UsageLesson] {
        guard let entry = resolvedEntry else { return [] }
        if showsAllEntryUsages { return entry.usages }
        return Array(entry.initiallyVisibleUsages)
    }

    var canRevealMoreUsages: Bool {
        guard let entry = resolvedEntry else { return false }
        return !showsAllEntryUsages && entry.hasMoreUsages
    }

    func revealAllEntryUsages() {
        showsAllEntryUsages = true
    }

    var summaryExplain: String {
        switch wordEntryState {
        case .ready(let entry):
            return entry.usages.first?.content.directExplanation ?? ""
        case .correctionRequired(let candidates):
            return candidates.first.map { "Check spelling: \($0)" } ?? ""
        case .pending, .loading:
            return ""
        case .unavailable(let message):
            return message
        case .idle:
            break
        }
        switch explanationState {
        case .ready(let explanation):
            return explanation.meaning
        case .loading, .idle:
            return ""
        case .unavailable(let message):
            return message
        }
    }

    var canSendExplanationFeedback: Bool {
        #if os(watchOS)
        return false
        #else
        return curatedResolution != nil
        #endif
    }

    var explanationWasLiked: Bool {
        likeFeedbackState.isSelected
    }

    /// Resolves one exact spelling to one complete Entry. Normal study never
    /// invokes the phone language model: a local miss follows the bounded v3
    /// correction/job path and remains an honest non-success state.
    func fetchExplain() {
        rareSpellingConfirmationAttempted = false
        fetchExplain(confirmedRareSpelling: false)
    }

    private func fetchExplain(confirmedRareSpelling: Bool) {
        explanationTask?.cancel()
        explanationTask = nil
        let request = UUID()
        explanationRequest = request

        wikipediaTask?.cancel()
        wikipediaTask = nil
        wikipediaRequest = UUID()
        wikipediaSummary = nil
        explanationFeedbackMessage = nil
        explanationFeedbackInFlight = false
        #if !os(watchOS)
        markInFlightFeedbackUncertain()
        feedbackTask?.cancel()
        feedbackTask = nil
        curatedResolution = nil
        resolvedEntryResolution = nil
        entryFeedbackStates.removeAll()
        entryFeedbackMessages.removeAll()
        feedbackActionInFlight = nil
        #endif

        let enteredWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredWord.isEmpty else {
            alsoKnownAs = nil
            explanationState = .unavailable("Enter a word to explain.")
            wordEntryState = .unavailable("Enter a word to explain.")
            return
        }

        alsoKnownAs = nil
        fetchWikipedia(for: enteredWord)
        explanationState = .loading
        wordEntryState = .loading
        showsAllEntryUsages = false
        explanationTask = Task { [weak self] in
            defer {
                if let self, self.explanationRequest == request {
                    self.explanationTask = nil
                }
            }
            #if os(watchOS)
            let entry: ResolvedWordEntry?
            if let cached = WatchEntrySnapshotBridge.shared.entry(
                for: enteredWord
            ) {
                entry = cached
            } else {
                entry = await WatchEntrySnapshotBridge.shared.requestEntry(
                    for: enteredWord
                )
            }
            guard let self, self.explanationRequest == request else { return }
            if let entry {
                self.wordEntryState = .ready(entry)
                self.explanationState = .idle
            } else {
                self.wordEntryState = .unavailable(
                    "Open this word on your iPhone once to make its reviewed lesson available offline."
                )
                self.explanationState = .idle
            }
            #else
            do {
                let deadline = Date().addingTimeInterval(Self.pendingPollWindow)
                var statusBudget = EntryForegroundStatusCheckBudget()
                var allowPendingStatusCheck = false
                while true {
                    guard let outcome = try await EntryExplanationRuntime.shared.resolve(
                        form: enteredWord,
                        confirmedRareSpelling: confirmedRareSpelling,
                        allowPendingStatusCheck: allowPendingStatusCheck
                    ) else {
                        guard let self, self.explanationRequest == request else { return }
                        self.wordEntryState = .unavailable(
                            EntryExplanationRuntime.shared.initializationError
                                ?? "The reviewed explanation library is unavailable."
                        )
                        return
                    }
                    try Task.checkCancellation()
                    guard let self, self.explanationRequest == request else { return }
                    switch outcome {
                    case .resolved(let resolution):
                        self.adoptResolvedEntry(resolution)
                        EntryExplanationRuntime.shared.deliverPendingFeedbackOnce()
                        return
                    case .correctionRequired(let correction):
                        self.wordEntryState = .correctionRequired(correction.candidates)
                        return
                    case .pending(let pending):
                        self.wordEntryState = .pending
                        guard statusBudget.claimStatusCheck(),
                              try await Self.waitForPendingJob(
                                pending,
                                until: deadline
                              ) else {
                            self.wordEntryState = .unavailable(
                                "This explanation is still being reviewed. Try again later."
                            )
                            return
                        }
                        allowPendingStatusCheck = true
                    case .negative:
                        self.wordEntryState = .unavailable(
                            "No reliable explanation is available for this spelling. Check it and try again."
                        )
                        return
                    case .unavailable:
                        self.wordEntryState = .unavailable(
                            "Explanations are temporarily unavailable. Please try again."
                        )
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.explanationRequest == request else { return }
                self.wordEntryState = .unavailable(
                    "The explanation could not be opened. Please try again."
                )
            }
            #endif
        }
    }

    func retryExplanation() {
        fetchExplain()
    }

    func useSuggestedSpelling(_ spelling: String) {
        word = spelling
        fetchExplain()
    }

    var canConfirmRareSpelling: Bool {
        !rareSpellingConfirmationAttempted
    }

    /// Retries this exact correction candidate once with an explicit learner
    /// confirmation. The repository bypasses only this spelling's cached
    /// correction outcome; durable negatives and other lookup keys still win.
    func confirmRareSpelling() {
        guard case .correctionRequired = wordEntryState,
              !rareSpellingConfirmationAttempted else { return }
        rareSpellingConfirmationAttempted = true
        fetchExplain(confirmedRareSpelling: true)
    }

    #if !os(watchOS)
    func entryFeedbackState(
        for entryUsageID: String,
        component: EntryFeedbackComponent
    ) -> ExplanationFeedbackControlState {
        entryFeedbackStates[entryFeedbackKey(entryUsageID, component)] ?? .available
    }

    func entryFeedbackMessage(for entryUsageID: String) -> String? {
        entryFeedbackMessages[entryUsageID]
    }

    func likeExplanation(entryUsageID: String) {
        submitEntryFeedback(
            entryUsageID: entryUsageID,
            rating: .helpful,
            component: .wholeLesson,
            requestReplacement: false
        )
    }

    func requestBetterExplanation(
        entryUsageID: String,
        component: EntryFeedbackComponent
    ) {
        submitEntryFeedback(
            entryUsageID: entryUsageID,
            rating: .notHelpful,
            component: component,
            requestReplacement: true
        )
    }

    private func submitEntryFeedback(
        entryUsageID: String,
        rating: EntryFeedbackRating,
        component: EntryFeedbackComponent,
        requestReplacement: Bool
    ) {
        let key = entryFeedbackKey(entryUsageID, component)
        guard !explanationFeedbackInFlight,
              entryFeedbackState(for: entryUsageID, component: component) == .available,
              let repository = EntryExplanationRuntime.shared.repository,
              let resolution = resolvedEntryResolution else { return }

        feedbackTask?.cancel()
        explanationFeedbackInFlight = true
        entryFeedbackStates[key] = .sending
        entryFeedbackMessages[entryUsageID] = requestReplacement
            ? "Requesting another reviewed lesson… The current lesson will stay here."
            : "Sending your feedback…"
        let request = explanationRequest
        feedbackTask = Task { [weak self] in
            defer {
                if let self, self.explanationRequest == request {
                    self.explanationFeedbackInFlight = false
                    self.feedbackTask = nil
                }
            }
            do {
                var submission = try await repository.submitFeedback(
                    for: resolution,
                    entryUsageID: entryUsageID,
                    rating: rating,
                    component: component,
                    requestReplacement: requestReplacement
                )
                try Task.checkCancellation()
                guard let self, self.explanationRequest == request else { return }
                let deadline = Date().addingTimeInterval(Self.pendingPollWindow)
                var statusBudget = EntryForegroundStatusCheckBudget()
                while true {
                    if submission.deliveryState == .queued {
                        self.entryFeedbackStates[key] = .queued
                        self.entryFeedbackMessages[entryUsageID] = requestReplacement
                            ? "Your request is queued. The current lesson will stay here."
                            : "Your feedback is queued for delivery."
                        return
                    }
                    switch submission.replacementState {
                    case .notRequested:
                        self.entryFeedbackStates[key] = .accepted
                        self.entryFeedbackMessages[entryUsageID] = "Thanks for the feedback."
                        return
                    case .complete:
                        self.resetEntryFeedbackControls(for: entryUsageID)
                        self.entryFeedbackMessages[entryUsageID] = "A new reviewed lesson is ready."
                        if let outcome = try await EntryExplanationRuntime.shared.resolve(
                            form: resolution.surfaceForm
                        ), case .resolved(let refreshed) = outcome,
                           self.explanationRequest == request {
                            self.adoptResolvedEntry(refreshed)
                        }
                        return
                    case .pending(let pending):
                        self.entryFeedbackStates[key] = .replacementPending
                        self.entryFeedbackMessages[entryUsageID] =
                            "Another reviewed lesson is being prepared. The current lesson will stay here."
                        guard statusBudget.claimStatusCheck(),
                              try await Self.waitForPendingJob(
                                pending,
                                until: deadline
                              ) else { return }
                        guard let resumed = try await repository.resumeFeedback(
                            eventID: submission.eventID
                        ) else {
                            // Another bounded outbox pass completed this event.
                            // Re-read the local selection and make the new lesson
                            // assessable instead of leaving stale button state.
                            if let outcome = try await EntryExplanationRuntime.shared.resolve(
                                form: resolution.surfaceForm
                            ), case .resolved(let refreshed) = outcome,
                               self.explanationRequest == request {
                                let previousExplanationID = resolution.entry.usages
                                    .first(where: { $0.entryUsageID == entryUsageID })?
                                    .explanationID
                                let currentExplanationID = refreshed.entry.usages
                                    .first(where: { $0.entryUsageID == entryUsageID })?
                                    .explanationID
                                self.adoptResolvedEntry(refreshed)
                                self.resetEntryFeedbackControls(for: entryUsageID)
                                self.entryFeedbackMessages[entryUsageID] =
                                    currentExplanationID != previousExplanationID
                                    ? "A new reviewed lesson is ready."
                                    : "No better reviewed lesson is available right now."
                            }
                            return
                        }
                        submission = resumed
                    case .failed:
                        self.entryFeedbackStates[key] = .replacementUnavailable
                        self.entryFeedbackMessages[entryUsageID] =
                            "No better reviewed lesson is available right now."
                        return
                    case .queued:
                        self.entryFeedbackStates[key] = .queued
                        self.entryFeedbackMessages[entryUsageID] =
                            "Your request is queued. The current lesson will stay here."
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.explanationRequest == request else { return }
                self.entryFeedbackStates[key] = .uncertain
                self.entryFeedbackMessages[entryUsageID] =
                    "We couldn't confirm that request. The current lesson is unchanged."
            }
        }
    }

    private func entryFeedbackKey(
        _ entryUsageID: String,
        _ component: EntryFeedbackComponent
    ) -> String {
        "\(entryUsageID)|\(component.rawValue)"
    }

    private func resetEntryFeedbackControls(for entryUsageID: String) {
        let prefix = "\(entryUsageID)|"
        entryFeedbackStates = entryFeedbackStates.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    private func adoptResolvedEntry(_ resolution: ResolvedEntryResolution) {
        resolvedEntryResolution = resolution
        wordEntryState = .ready(resolution.entry)
        #if os(iOS)
        WatchEntrySnapshotBridge.shared.publish(resolution.entry)
        #endif
    }

    func likeExplanation() {
        submitExplanationFeedback(
            rating: .like,
            component: .whole,
            requestReplacement: false
        )
    }

    func requestBetterExplanation(
        for component: ExplanationFeedbackComponent
    ) {
        submitExplanationFeedback(
            rating: .dislike,
            component: component,
            requestReplacement: true
        )
    }

    private func submitExplanationFeedback(
        rating: ExplanationFeedbackRating,
        component: ExplanationFeedbackComponent,
        requestReplacement: Bool
    ) {
        let action: FeedbackAction
        switch (rating, component, requestReplacement) {
        case (.like, .whole, false):
            action = .like
        case (.dislike, .meaning, true):
            action = .meaningReplacement
        case (.dislike, .memoryAid, true):
            action = .memoryAidReplacement
        default:
            return
        }

        guard !explanationFeedbackInFlight,
              feedbackState(for: action) == .available,
              let repository = ExplanationRuntime.shared.repository,
              let resolution = curatedResolution else { return }

        feedbackTask?.cancel()
        explanationFeedbackInFlight = true
        feedbackActionInFlight = action
        setFeedbackState(.sending, for: action)
        explanationFeedbackMessage = inFlightMessage(for: action)
        let request = explanationRequest
        let explanationID = resolution.record.explanationID
        feedbackTask = Task { [weak self] in
            defer {
                if let self,
                   self.explanationRequest == request {
                    self.explanationFeedbackInFlight = false
                    self.feedbackActionInFlight = nil
                    self.feedbackTask = nil
                }
            }
            do {
                let submission = try await repository.submitFeedback(
                    for: resolution,
                    rating: rating,
                    component: component,
                    requestReplacement: requestReplacement
                )
                try Task.checkCancellation()
                guard let self,
                      self.explanationRequest == request,
                      self.curatedResolution?.record.explanationID
                        == explanationID else { return }

                if rating == .like {
                    self.setFeedbackState(
                        submission.deliveryState == .queued ? .queued : .accepted,
                        for: action
                    )
                }
                if let replacement = submission.replacement {
                    let replacementResolution = ExplanationResolution(
                        surfaceForm: resolution.surfaceForm,
                        source: .overlay,
                        record: replacement
                    )
                    self.adoptCuratedResolution(replacementResolution)
                    self.alsoKnownAs = replacement.grammaticalFormDescription
                    self.explanationState = .ready(replacement.explanation)
                    self.explanationFeedbackMessage = "A new explanation is ready."
                } else if submission.deliveryState == .queued {
                    self.setFeedbackState(.queued, for: action)
                    self.explanationFeedbackMessage = requestReplacement
                        ? "Your request is queued. This explanation will stay here for now."
                        : "Your feedback is queued for delivery."
                } else if requestReplacement,
                          submission.replacementStatus == .failed {
                    self.setFeedbackState(.replacementUnavailable, for: action)
                    self.explanationFeedbackMessage =
                        "No better version is available right now."
                } else if requestReplacement,
                          submission.replacementStatus == .pending {
                    self.setFeedbackState(.replacementPending, for: action)
                    self.explanationFeedbackMessage =
                        "A better version is being prepared. This explanation will stay here for now."
                } else {
                    self.setFeedbackState(.accepted, for: action)
                    self.explanationFeedbackMessage = "Thanks for the feedback."
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.explanationRequest == request else { return }
                // The repository queues before delivery, so an arbitrary error
                // does not prove either that the local write succeeded or that
                // it failed. Keep this action locked to avoid a duplicate event,
                // but never tell the learner that it was saved without proof.
                self.setFeedbackState(.uncertain, for: action)
                self.explanationFeedbackMessage =
                    "We couldn't confirm that request. This explanation is unchanged."
            }
        }
    }

    private func adoptCuratedResolution(_ resolution: ExplanationResolution) {
        let explanationID = resolution.record.explanationID
        if feedbackExplanationID != explanationID {
            resetFeedbackControls(for: explanationID)
        }
        curatedResolution = resolution
    }

    private func resetFeedbackControls(for explanationID: String?) {
        feedbackExplanationID = explanationID
        explanationFeedbackMessage = nil
        explanationFeedbackInFlight = false
        feedbackActionInFlight = nil
        likeFeedbackState = .available
        meaningFeedbackState = .available
        memoryAidFeedbackState = .available
    }

    private func feedbackState(
        for action: FeedbackAction
    ) -> ExplanationFeedbackControlState {
        switch action {
        case .like:
            return likeFeedbackState
        case .meaningReplacement:
            return meaningFeedbackState
        case .memoryAidReplacement:
            return memoryAidFeedbackState
        }
    }

    private func setFeedbackState(
        _ state: ExplanationFeedbackControlState,
        for action: FeedbackAction
    ) {
        switch action {
        case .like:
            likeFeedbackState = state
        case .meaningReplacement:
            meaningFeedbackState = state
        case .memoryAidReplacement:
            memoryAidFeedbackState = state
        }
    }

    private func markInFlightFeedbackUncertain() {
        guard let feedbackActionInFlight,
              feedbackState(for: feedbackActionInFlight) == .sending else { return }
        setFeedbackState(.uncertain, for: feedbackActionInFlight)
    }

    private func inFlightMessage(for action: FeedbackAction) -> String {
        switch action {
        case .like:
            return "Sending your feedback…"
        case .meaningReplacement:
            return "Requesting a better meaning… This explanation will stay here for now."
        case .memoryAidReplacement:
            return "Requesting a better memory tip… This explanation will stay here for now."
        }
    }
    #endif

    #if os(watchOS)
    private func adoptWatchSnapshotIfAvailable() {
        guard !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entry = WatchEntrySnapshotBridge.shared.entry(for: word) else {
            return
        }
        wordEntryState = .ready(entry)
        explanationState = .idle
    }
    #endif

    #if !os(watchOS)
    /// Waits for a server-provided durable-job checkpoint without recursion.
    /// A malicious or stale future date cannot hold the card forever because
    /// every wait is capped by the view's fixed polling window.
    private static func waitForPendingJob(
        _ pending: EntryPendingResolution,
        until deadline: Date
    ) async throws -> Bool {
        let now = Date()
        guard now < deadline else { return false }
        let wakeAt = min(max(pending.nextCheckAt, now.addingTimeInterval(0.25)), deadline)
        let delay = max(wakeAt.timeIntervalSince(now), 0)
        if delay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64((delay * 1_000_000_000).rounded())
            )
        }
        try Task.checkCancellation()
        return Date() < deadline
    }
    #endif

    func reset() {
        explanationTask?.cancel()
        wikipediaTask?.cancel()
        #if !os(watchOS)
        markInFlightFeedbackUncertain()
        feedbackTask?.cancel()
        feedbackTask = nil
        curatedResolution = nil
        resolvedEntryResolution = nil
        entryFeedbackStates.removeAll()
        entryFeedbackMessages.removeAll()
        resetFeedbackControls(for: nil)
        #endif
        explanationRequest = UUID()
        wikipediaRequest = UUID()
        rareSpellingConfirmationAttempted = false
        alsoKnownAs = nil
        explanationState = .idle
        wordEntryState = .idle
        showsAllEntryUsages = false
        wikipediaSummary = nil
        explanationFeedbackMessage = nil
        explanationFeedbackInFlight = false
    }

    func cancelExplanation() {
        explanationTask?.cancel()
        explanationTask = nil
        explanationRequest = UUID()
        wikipediaTask?.cancel()
        wikipediaTask = nil
        wikipediaRequest = UUID()
        #if !os(watchOS)
        markInFlightFeedbackUncertain()
        feedbackTask?.cancel()
        feedbackTask = nil
        explanationFeedbackInFlight = false
        feedbackActionInFlight = nil
        #endif
    }

    private func fetchWikipedia(for word: String) {
        #if os(iOS)
        wikipediaTask?.cancel()
        wikipediaSummary = nil
        let request = UUID()
        wikipediaRequest = request
        wikipediaTask = Task { [weak self] in
            do {
                let summary = try await WikipediaClient.summary(for: word)
                try Task.checkCancellation()
                guard let self, self.wikipediaRequest == request else { return }
                self.wikipediaSummary = summary
            } catch is CancellationError {
                return
            } catch {
                // Wikipedia is optional discovery content; a network failure
                // must not interfere with the local explanation.
            }
            if let self, self.wikipediaRequest == request {
                self.wikipediaTask = nil
            }
        }
        #endif
    }

    /// Sets the next study word if this model was created without one.
    func validate() {
        if word.isEmpty {
            word = WordManager.shared.takePreparedStudyWord()
                ?? WordManager.shared.nextWord()
            if word.isEmpty {
                word = WordManager.shared.nextRandomWord()
            }
        }
    }

    func answer(_ rate: CardRating) {
        SoundManager.shared.stopPronunciation(
            for: word,
            phonemes: preferredPronunciationPhonemes
        )
        WordManager.shared.answer(word, rate)
        // A broad Core Data notification may have speculatively reserved a
        // word before this answer changed the schedule. Select again now that
        // the answer is committed so the reservation and prefetch stay exact.
        let nextWord = WordManager.shared.replacePreparedStudyWord()
        #if !os(watchOS)
        EntryExplanationRuntime.shared.prefetchEntry(for: nextWord)
        #endif
        Task { @MainActor in
            #if !os(watchOS)
            let phonemes = await EntryExplanationRuntime.shared
                .preferredLocalPronunciationPhonemes(for: nextWord)
            guard !Task.isCancelled else { return }
            #else
            let phonemes: String? = nil
            #endif
            _ = await SoundManager.shared.preparePronunciation(
                nextWord,
                phonemes: phonemes
            )
        }
    }

    func bury() {
        WordManager.shared.buryWordCard(word)
    }
}

#if os(iOS) || os(watchOS)
extension Notification.Name {
    static let watchEntrySnapshotDidChange = Notification.Name(
        "Wordbook.watchEntrySnapshotDidChange"
    )
}

/// One paired-device transport for reviewed Entry snapshots. The iPhone owns
/// resolution and publication; the Watch only validates, persists, and reads
/// complete snapshots. `updateApplicationContext` keeps background delivery
/// bounded to the latest state, while a reachable Watch can request an Entry
/// and receive the same strict payload immediately.
final class WatchEntrySnapshotBridge: NSObject, WCSessionDelegate,
    @unchecked Sendable {
    static let shared = WatchEntrySnapshotBridge()

    private enum Wire {
        static let snapshot = "wordbook.entry-snapshot.v1"
        static let archive = "wordbook.entry-archive.v1"
        static let request = "wordbook.entry-request.v1"
        static let result = "wordbook.entry-result.v1"
        static let available = "available"
        static let unavailable = "unavailable"
    }

    private final class RequestContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ResolvedWordEntry?, Never>?

        init(_ continuation: CheckedContinuation<ResolvedWordEntry?, Never>) {
            self.continuation = continuation
        }

        func resume(returning entry: ResolvedWordEntry?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: entry)
        }
    }

    private static let cacheDefaultsKey = "watchEntrySnapshotCache.v1"
    private static let maximumRequestBytes = 512

    private let stateLock = NSLock()
    private let defaults: UserDefaults
    private let connectivitySession: WCSession?
    private var cache: WatchEntrySnapshotCache
    private var lastCapturedAtMilliseconds: Int64
    private var activationRequested = false

    private override init() {
        defaults = .standard
        connectivitySession = WCSession.isSupported() ? .default : nil
        #if os(watchOS)
        if let data = defaults.data(forKey: Self.cacheDefaultsKey),
           let restored = try? WatchEntrySnapshotCache.decodeArchive(data) {
            cache = restored
        } else {
            cache = WatchEntrySnapshotCache()
            defaults.removeObject(forKey: Self.cacheDefaultsKey)
        }
        #else
        // The iPhone's signed catalog/overlay remains authoritative. Its
        // bridge cache is process-local transport state, not a competing
        // persistent learner-content cache.
        cache = WatchEntrySnapshotCache()
        #endif
        lastCapturedAtMilliseconds = cache.snapshots
            .map(\.capturedAtMilliseconds)
            .max() ?? 0
        super.init()
    }

    func activate() {
        guard let connectivitySession else { return }
        stateLock.lock()
        let shouldActivate = !activationRequested
        activationRequested = true
        stateLock.unlock()
        guard shouldActivate else { return }
        connectivitySession.delegate = self
        connectivitySession.activate()
    }

    func entry(for surfaceForm: String) -> ResolvedWordEntry? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.entry(for: surfaceForm)
    }

    #if os(iOS)
    func publish(_ entry: ResolvedWordEntry) {
        do {
            let snapshot: WatchEntrySnapshot
            if let current = cachedSnapshot(
                for: entry.encounteredSurfaceForm
            ), current.entry == entry {
                snapshot = current
            } else {
                snapshot = try makeSnapshot(entry)
            }
            let data = try snapshot.encoded()
            distribute(data)
        } catch {
            print("Watch Entry snapshot was not published: \(error.localizedDescription)")
        }
    }

    /// Prepares a bounded offline set for the words already synchronized to
    /// the Watch. Reads are catalog/overlay-only and happen away from the main
    /// actor; one final application-context update carries the whole archive.
    func publishLocallyAvailableEntries(for surfaceForms: [String]) {
        var seen = Set<String>()
        let bounded = surfaceForms.compactMap { form -> String? in
            let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = WatchEntrySnapshotContract.normalizeLookupForm(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
        .prefix(WatchEntrySnapshotContract.maximumCachedEntries)

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var latestPayload: Data?
            // Cache insertion is newest-first. Resolve lower-priority rows
            // first so the first visible row from each interleaved Watch list
            // survives if the byte cap is reached before the Entry cap.
            for form in bounded.reversed() {
                guard let resolution = try? EntryExplanationRuntime.shared
                    .resolveLocally(form: form),
                      self.cachedSnapshot(for: form)?.entry
                        != resolution.entry else { continue }
                do {
                    let snapshot = try self.makeSnapshot(resolution.entry)
                    latestPayload = try snapshot.encoded()
                } catch {
                    continue
                }
            }
            if let latestPayload {
                self.distribute(latestPayload)
            }
        }
    }
    #endif

    #if os(watchOS)
    func requestEntry(for surfaceForm: String) async -> ResolvedWordEntry? {
        if let entry = entry(for: surfaceForm) { return entry }
        let request = surfaceForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty,
              request.utf8.count <= Self.maximumRequestBytes,
              let connectivitySession else { return nil }
        activate()
        guard connectivitySession.activationState == .activated,
              connectivitySession.isReachable else { return nil }

        return await withCheckedContinuation { continuation in
            let replyGate = RequestContinuation(continuation)
            connectivitySession.sendMessage(
                [Wire.request: request],
                replyHandler: { [weak self] payload in
                    guard let self,
                          payload[Wire.result] as? String == Wire.available,
                          let data = payload[Wire.snapshot] as? Data,
                          self.install(data) else {
                        replyGate.resume(returning: nil)
                        return
                    }
                    replyGate.resume(returning: self.entry(for: request))
                },
                errorHandler: { _ in
                    replyGate.resume(returning: nil)
                }
            )
        }
    }
    #endif

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated else { return }
        #if os(watchOS)
        installApplicationContext(session.receivedApplicationContext)
        #else
        publishLatestApplicationContext()
        #endif
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        #if os(watchOS)
        installApplicationContext(applicationContext)
        #endif
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        #if os(watchOS)
        installApplicationContext(message)
        #endif
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(watchOS)
        if let data = message[Wire.snapshot] as? Data {
            let installed = install(data)
            replyHandler([Wire.result: installed ? Wire.available : Wire.unavailable])
            return
        }
        replyHandler([Wire.result: Wire.unavailable])
        #else
        // Publication is intentionally one-way. The iPhone never accepts
        // learner content from its companion; it only answers bounded lookup
        // requests from its own reviewed overlay/catalog.
        guard let requestedForm = message[Wire.request] as? String,
              !requestedForm.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              requestedForm.utf8.count <= Self.maximumRequestBytes else {
            replyHandler([Wire.result: Wire.unavailable])
            return
        }
        replyToEntryRequest(requestedForm, replyHandler: replyHandler)
        #endif
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        publishLatestApplicationContext()
    }

    private func replyToEntryRequest(
        _ surfaceForm: String,
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if let snapshot = cachedSnapshot(for: surfaceForm),
           let data = try? snapshot.encoded() {
            replyHandler([Wire.result: Wire.available, Wire.snapshot: data])
            return
        }

        // Only the phone owns this lookup, and a Watch request is deliberately
        // overlay/catalog-only. A cold miss must be opened on iPhone before it
        // may reach v3; the Watch itself never starts network/model work.
        guard let resolution = try? EntryExplanationRuntime.shared.resolveLocally(
            form: surfaceForm
        ) else {
            replyHandler([Wire.result: Wire.unavailable])
            return
        }
        do {
            let snapshot = try makeSnapshot(resolution.entry)
            let data = try snapshot.encoded()
            distribute(data)
            replyHandler([Wire.result: Wire.available, Wire.snapshot: data])
        } catch {
            replyHandler([Wire.result: Wire.unavailable])
        }
    }

    private func makeSnapshot(
        _ entry: ResolvedWordEntry
    ) throws -> WatchEntrySnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wallClock = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let capturedAt = max(wallClock, lastCapturedAtMilliseconds + 1)
        let snapshot = try WatchEntrySnapshot(
            entry: entry,
            capturedAtMilliseconds: capturedAt
        )
        var updated = cache
        _ = try updated.install(snapshot)
        let archive = try updated.encodedArchive()
        cache = updated
        lastCapturedAtMilliseconds = capturedAt
        // `archive` proves the cache remains bounded. The iPhone does not
        // persist this transport copy; only the Watch needs offline storage.
        _ = archive
        return snapshot
    }

    private func distribute(_ data: Data) {
        guard let connectivitySession,
              connectivitySession.activationState == .activated,
              connectivitySession.isPaired,
              connectivitySession.isWatchAppInstalled else { return }
        // The archive already contains the latest snapshot. Send one bounded
        // value instead of duplicating that snapshot in the same property-list
        // payload and risking WCError.payloadTooLarge.
        let context: [String: Any]
        if let archive = currentArchive() {
            context = [Wire.archive: archive]
        } else {
            context = [Wire.snapshot: data]
        }
        do {
            try connectivitySession.updateApplicationContext(context)
        } catch {
            print("Watch Entry context was not updated: \(error.localizedDescription)")
        }
        if connectivitySession.isReachable {
            connectivitySession.sendMessage(
                context,
                replyHandler: nil,
                errorHandler: nil
            )
        }
    }

    private func publishLatestApplicationContext() {
        guard let snapshot = latestSnapshot(),
              let data = try? snapshot.encoded() else { return }
        distribute(data)
    }
    #endif

    private func cachedSnapshot(for surfaceForm: String) -> WatchEntrySnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.snapshot(for: surfaceForm)
    }

    private func latestSnapshot() -> WatchEntrySnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache.snapshots.first
    }

    private func currentArchive() -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try? cache.encodedArchive()
    }

    private func installApplicationContext(_ context: [String: Any]) {
        if let archive = context[Wire.archive] as? Data,
           installArchive(archive) {
            return
        }
        if let data = context[Wire.snapshot] as? Data {
            _ = install(data)
        }
    }

    @discardableResult
    private func installArchive(_ data: Data) -> Bool {
        guard let received = try? WatchEntrySnapshotCache.decodeArchive(data) else {
            return false
        }
        var accepted = false
        // Install oldest first so the sender's newest-first order and capture
        // monotonicity are preserved in the receiving cache.
        for snapshot in received.snapshots.reversed() {
            guard let payload = try? snapshot.encoded() else { continue }
            accepted = install(payload) || accepted
        }
        return accepted
    }

    @discardableResult
    private func install(_ data: Data) -> Bool {
        let snapshot: WatchEntrySnapshot
        do {
            snapshot = try WatchEntrySnapshot.decode(data)
        } catch {
            return false
        }

        let changed: Bool
        do {
            stateLock.lock()
            defer { stateLock.unlock() }
            var updated = cache
            changed = try updated.install(snapshot)
            if changed {
                let archive = try updated.encodedArchive()
                cache = updated
                lastCapturedAtMilliseconds = max(
                    lastCapturedAtMilliseconds,
                    snapshot.capturedAtMilliseconds
                )
                #if os(watchOS)
                defaults.set(archive, forKey: Self.cacheDefaultsKey)
                #else
                _ = archive
                #endif
            }
        } catch {
            return false
        }

        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .watchEntrySnapshotDidChange,
                    object: snapshot.entry.normalizedForm
                )
            }
        }
        // A valid duplicate is still an available payload.
        return changed || entry(
            for: snapshot.entry.encounteredSurfaceForm
        ) == snapshot.entry
    }
}
#endif
