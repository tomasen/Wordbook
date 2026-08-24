import Foundation

enum HarnessFailure: LocalizedError {
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
struct OfflineExplanationStoreHarness {
    static func main() throws {
        let fixtureURL = try fixtureURLFromArguments()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WordbookOfflineStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let databaseURL = temporaryDirectory.appendingPathComponent("fixture.sqlite")
        try materializeDatabase(from: fixtureURL, at: databaseURL)

        let store = try OfflineExplanationStore(databaseURL: databaseURL)

        let went = try require(
            try store.explanation(for: "  WENT\n"),
            "Expected the inflected form 'went' to resolve."
        )
        try expect(went.normalizedForm == "went", "The normalized form should be 'went'.")
        try expect(went.displayForm == "went", "The display form should preserve 'went'.")
        try expect(went.lemma == "go", "The inflected form 'went' should resolve to lemma 'go'.")
        try expect(
            went.morphology == .single("past"),
            "The exact form should retain its past-tense relationship."
        )
        try expect(
            went.grammaticalFormDescription == "past tense of go",
            "The exact form should expose a learner-facing grammatical relationship."
        )
        try expect(went.senseID == "wn:go:v:1", "The resolved sense identity changed.")
        try expect(went.explanationID == "exp:go:v:1", "The explanation identity changed.")
        try expect(went.explanation.partOfSpeech == "v", "The part of speech should be a verb.")
        try expect(
            went.explanation.memoryTechnique == .contrast,
            "The memory technique was not decoded."
        )
        try expect(
            went.explanation.synonyms == ["travel", "move"],
            "The synonym JSON was not decoded in order."
        )

        let saw = try require(
            try store.explanation(for: "saw"),
            "Expected the ambiguous form 'saw' to resolve."
        )
        try expect(
            saw.senseID == "wn:saw:v:1",
            "The form_default mapping, not row or alphabetical order, must choose the sense."
        )
        try expect(
            saw.morphology == .single("past"),
            "The chosen sense must carry the morphology for the exact ambiguous spelling."
        )

        let left = try require(
            try store.explanation(for: "left"),
            "Expected the ambiguous form 'left' to resolve."
        )
        try expect(left.lemma == "leave", "The exact form 'left' should resolve to 'leave'.")
        try expect(
            left.morphology == .combined(["past", "pastParticiple"]),
            "Merged morphology labels should survive the SQLite store boundary."
        )
        try expect(
            left.grammaticalFormDescription
                == "past tense and past participle of leave",
            "Combined morphology should remain understandable to the learner."
        )

        let unknown = try store.explanation(for: "not-in-the-pack")
        try expect(
            unknown == nil,
            "An unknown form should return nil without generating or guessing."
        )
        try expect(
            OfflineExplanationStore.normalizeForm("  WON’T\u{00A0}GO—YET ") == "won't go-yet",
            "Client normalization no longer matches the content-pack punctuation rules."
        )

        print("OfflineExplanationStore harness passed")
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
            throw HarnessFailure.sqliteToolFailed(process.terminationStatus, output)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw HarnessFailure.failedAssertion(message)
        }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw HarnessFailure.failedAssertion(message)
        }
        return value
    }
}
