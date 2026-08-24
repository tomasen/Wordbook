import Foundation

// Run from the repository root:
// swiftc Shared/CompactLexicalIndex.swift \
//   scripts/LocalTutorValidationHarness.swift \
//   -o /tmp/local-tutor-validation-harness

@main
struct LocalTutorValidationHarness {
    static func main() throws {
        let index = try CompactLexicalIndex(
            contentsOf: URL(fileURLWithPath: "Shared/lexical-index.wbli"),
            validateChecksum: true
        )
        require(
            index.canonicalWord(for: "puissance") == "puissance",
            "puissance is present in the spelling index"
        )
        require(
            LexicalTextMatcher.containsExactSpelling(
                "puissance",
                in: "The nation displayed great puissance during the crisis."
            ),
            "accepts an exact target at word boundaries"
        )
        require(
            LexicalTextMatcher.containsExactSpelling(
                "puissance",
                in: "Puissance can also name a show-jumping competition."
            ),
            "matching is case-insensitive"
        )
        require(
            !LexicalTextMatcher.containsExactSpelling(
                "puissance",
                in: "The car has a large age and can move quickly."
            ),
            "rejects the reported unrelated example"
        )
        require(
            !LexicalTextMatcher.containsExactSpelling(
                "puissance",
                in: "The puissances were compared."
            ),
            "rejects an inflected form when the exact target is absent"
        )
        require(
            !LexicalTextMatcher.containsExactSpelling(
                "puissance",
                in: "Impuissance is a different word."
            ),
            "rejects a target embedded inside another word"
        )
        require(
            !LexicalTextMatcher.containsExactSpelling(
                "apple",
                in: "The applet rendered a small interface."
            ),
            "rejects a longer unrelated word sharing the target prefix"
        )
        print("PASS: local tutor exact-target validation")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("FAIL: \(message)")
        }
    }
}
