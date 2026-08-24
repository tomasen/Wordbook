import Foundation

enum HarnessFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.message(message) }
}

@main
struct EntryCatalogStoreHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw HarnessFailure.message(
                "usage: EntryCatalogStoreHarness /path/to/wordbook-content.sqlite"
            )
        }
        let store = try EntryCatalogStore(
            databaseURL: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        try require(
            store.contentVersion == "entry-golden-2026-08-23",
            "catalog content version was not read from metadata"
        )
        let expectedCounts = [
            "saw": 2,
            "went": 3,
            "read": 3,
            "children": 2,
            "gynecologist": 1,
            "gynecologists": 1,
            "meek": 1,
        ]
        for (form, expectedCount) in expectedCounts {
            let entry = try store.entry(for: form)
            try require(entry != nil, "missing Entry for \(form)")
            try require(
                entry?.usages.count == expectedCount,
                "\(form) returned \(entry?.usages.count ?? 0) usages; expected \(expectedCount)"
            )
            try require(
                entry?.normalizedForm == form,
                "\(form) did not resolve by exact normalized spelling"
            )
        }

        let saw = try store.entry(for: "SAW")
        try require(saw?.encounteredSurfaceForm == "SAW", "surface spelling was rewritten")
        try require(
            saw?.usages.map(\.partOfSpeechLabel) == ["verb", "noun"],
            "saw usage order or membership changed"
        )

        let read = try store.entry(for: "read")
        try require(
            read?.usages.compactMap { $0.pronunciations.first?.ipa } == [
                "riːd", "rɛd", "riːd",
            ],
            "read pronunciation usages are incomplete"
        )

        let gynecologist = try store.entry(for: "gynecologist")
        try require(
            gynecologist?.preferredPronunciationPhonemes
                == "ˌɡaɪnəˈkɑːlədʒɪst",
            "gynecologist did not expose its reviewed pronunciation"
        )
        try require(
            gynecologist?.usages.first?.contentHash
                == "a98400a1f0aa133ee5285692ff11ff2d0bfd438adda9a57ac81b948d4ec95847",
            "gynecologist canonical content hash changed"
        )

		let tamperedURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("WordbookCatalogVersion-\(UUID().uuidString).sqlite")
		defer { try? FileManager.default.removeItem(at: tamperedURL) }
		try FileManager.default.copyItem(
			at: URL(fileURLWithPath: CommandLine.arguments[1]),
			to: tamperedURL
		)
		let tampered = try SQLiteWritableDatabase(url: tamperedURL)
		try tampered.execute(
			"UPDATE entry_coverage SET content_version = 'mismatched-catalog'"
		)
		do {
			_ = try EntryCatalogStore(databaseURL: tamperedURL)
			throw HarnessFailure.message(
				"catalog runtime accepted entry coverage from another content version"
			)
		} catch is EntryCatalogStoreError {
			// Expected.
		}
        print("EntryCatalogStore contract passed")
    }
}
