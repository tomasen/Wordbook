// Minimal collaborators used only by the standalone watchOS typecheck command.
// This file is not a member of an application target.
import Combine
import Foundation

final class UserPreferences: ObservableObject {
    static let shared = UserPreferences()
    let translationLanguageCode = "en"
}

enum CardRating: Int16 {
    case NOIDEA = 0
    case VAGUE
    case WELLKNOWN
}

@MainActor
final class WordManager {
    static let shared = WordManager()

    func takePreparedStudyWord() -> String? { nil }
    func nextWord() -> String { "" }
    func nextRandomWord() -> String { "example" }
    func answer(_ word: String, _ rate: CardRating) {}
    func replacePreparedStudyWord() -> String { "example" }
    func buryWordCard(_ word: String) {}
    func addWordCard(_ word: String) -> Bool { true }
}

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    func stopPronunciation(for word: String, phonemes: String? = nil) {}

    func preparePronunciation(
        _ word: String,
        phonemes: String? = nil,
        foreground: Bool = false
    ) async -> Bool { true }
}
