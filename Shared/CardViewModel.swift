//
//  CardViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 11/25/21.
//

import Foundation
import Combine

struct WikipediaSummary: Identifiable, Equatable, Sendable {
    let title: String
    let extract: String
    let url: URL

    var id: String { url.absoluteString }
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
    @Published var word = ""
    @Published private(set) var alsoKnownAs: String?
    @Published private(set) var explanationState: ExplanationLoadState = .idle
    @Published private(set) var wikipediaSummary: WikipediaSummary?
    @Published var perf = UserPreferences.shared

    private var explanationTask: Task<Void, Never>?
    private var explanationRequest = UUID()
    private var wikipediaTask: Task<Void, Never>?
    private var wikipediaRequest = UUID()

    init(_ word: String = "") {
        self.word = word
    }

    var translationLanguageCode: String {
        perf.translationLanguageCode
    }

    var explanation: VocabularyExplanation? {
        guard case .ready(let explanation) = explanationState else { return nil }
        return explanation
    }

    var isExplanationSettled: Bool {
        switch explanationState {
        case .ready, .unavailable:
            return true
        case .idle, .loading:
            return false
        }
    }

    var summaryExplain: String {
        switch explanationState {
        case .ready(let explanation):
            return explanation.meaning
        case .loading, .idle:
            return ""
        case .unavailable(let message):
            return message
        }
    }

    /// Loads a versioned cached explanation first. The iPhone app generates a
    /// missing explanation locally; companion targets only consume the cache.
    func fetchExplain() {
        explanationTask?.cancel()
        explanationTask = nil
        let request = UUID()
        explanationRequest = request

        wikipediaTask?.cancel()
        wikipediaTask = nil
        wikipediaRequest = UUID()
        wikipediaSummary = nil

        let enteredWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enteredWord.isEmpty else {
            alsoKnownAs = nil
            explanationState = .unavailable("Enter a word to explain.")
            return
        }

        let canonicalWord = CompactLexicalIndex.shared.canonicalWord(for: enteredWord)
            ?? enteredWord
        alsoKnownAs = canonicalWord.caseInsensitiveCompare(enteredWord) == .orderedSame
            ? nil
            : canonicalWord
        fetchWikipedia(for: canonicalWord)

        if let cached = WordManager.shared.getCachedExplanation(word: canonicalWord) {
            explanationState = .ready(cached)
            return
        }

        #if WORDBOOK_LOCAL_LLM
        explanationState = .loading
        explanationTask = Task { [weak self] in
            defer {
                if let self, self.explanationRequest == request {
                    self.explanationTask = nil
                }
            }
            do {
                let explanation = try await LocalTutorManager.shared.explanation(
                    for: canonicalWord
                )
                try Task.checkCancellation()
                guard let self, self.explanationRequest == request else { return }
                self.explanationState = .ready(explanation)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.explanationRequest == request else { return }
                self.explanationState = .unavailable(error.localizedDescription)
            }
        }
        #else
        #if os(watchOS)
        explanationState = .unavailable("Open this word on your iPhone to prepare its explanation.")
        #else
        explanationState = .unavailable("Open this word on your iPhone to prepare its explanation.")
        #endif
        #endif
    }

    func retryExplanation() {
        LocalTutorManager.shared.invalidateExplanation(for: alsoKnownAs ?? word)
        fetchExplain()
    }

    func reset() {
        explanationTask?.cancel()
        wikipediaTask?.cancel()
        explanationRequest = UUID()
        wikipediaRequest = UUID()
        alsoKnownAs = nil
        explanationState = .idle
        wikipediaSummary = nil
    }

    func cancelExplanation() {
        explanationTask?.cancel()
        explanationTask = nil
        explanationRequest = UUID()
        wikipediaTask?.cancel()
        wikipediaTask = nil
        wikipediaRequest = UUID()
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
        WordManager.shared.answer(word, rate)
        // A broad Core Data notification may have speculatively reserved a
        // word before this answer changed the schedule. Select again now that
        // the answer is committed so the reservation and prefetch stay exact.
        let nextWord = WordManager.shared.replacePreparedStudyWord()
        LocalTutorManager.shared.prefetchExplanation(for: nextWord)
    }

    func bury() {
        WordManager.shared.buryWordCard(word)
    }
}
