import Foundation

private struct Fixture: Decodable {
    let contractSHA256: String
    let unicodeVersion: String
    let normalizationCases: [Case]
    let unsupportedNormalizationCases: [UnsupportedCase]
    let resolverCases: [Case]
    let invalidResolverCases: [UnsupportedCase]

    struct Case: Decodable {
        let id: String
        let input: String
        let normalized: String
    }

    struct UnsupportedCase: Decodable {
        let id: String
        let input: String
    }
}

@main
struct NormalizationV1Harness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw HarnessError("expected the conformance fixture path")
        }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        guard fixture.contractSHA256 == WordbookNormalizationV1.contractSHA256,
              fixture.unicodeVersion == WordbookNormalizationV1.unicodeVersion else {
            throw HarnessError("fixture and compiled contract identities differ")
        }
        for testCase in fixture.normalizationCases {
            let actual = WordbookNormalizationV1.normalize(testCase.input)
            guard actual == testCase.normalized else {
                throw HarnessError(
                    "\(testCase.id): got \(String(describing: actual)), expected \(testCase.normalized)"
                )
            }
        }
        for testCase in fixture.unsupportedNormalizationCases {
            guard WordbookNormalizationV1.normalize(testCase.input) == nil else {
                throw HarnessError("\(testCase.id): unsupported input was accepted")
            }
        }
        for testCase in fixture.resolverCases {
            guard WordbookNormalizationV1.normalizeLookupKey(testCase.input)
                    == testCase.normalized,
                  WordbookNormalizationV1.isValidResolverSurface(testCase.input) else {
                throw HarnessError("\(testCase.id): resolver parity failed")
            }
        }
        for testCase in fixture.invalidResolverCases {
            guard WordbookNormalizationV1.normalizeLookupKey(testCase.input) == nil,
                  !WordbookNormalizationV1.isValidResolverSurface(testCase.input) else {
                throw HarnessError("\(testCase.id): invalid resolver input was accepted")
            }
        }
        print("Normalization-v1 harness passed \(fixture.normalizationCases.count) normalization and \(fixture.resolverCases.count) resolver cases.")
    }
}

private struct HarnessError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
