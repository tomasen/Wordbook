import Foundation

/// Deterministic lexical checks shared by local-tutor validation. Prompt text
/// requests the exact spelling, and this boundary-aware check enforces it before
/// generated content reaches the learner.
enum LexicalTextMatcher {
    static func containsExactSpelling(_ spelling: String, in text: String) -> Bool {
        let target = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !text.isEmpty else { return false }

        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let pattern = #"(?<![A-Za-z0-9])\#(escapedTarget)(?![A-Za-z0-9])"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, options: [], range: range) != nil
    }
}

/// A read-only, memory-mapped index of English spellings, aliases, and
/// vocabulary-book membership. It deliberately contains no definitions,
/// pronunciation audio, or other dictionary content.
///
/// `lexical-index.wbli` is ordered by ASCII-case-folded spelling, so common
/// prefix and exact lookups use binary search without decoding the whole file.
/// Only returned spellings are materialized as Swift strings.
final class CompactLexicalIndex {
    enum IndexError: LocalizedError {
        case resourceMissing(name: String)
        case invalidHeader
        case unsupportedVersion(UInt32)
        case invalidLayout
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .resourceMissing(let name):
                return "The bundled lexical index \(name).wbli is missing."
            case .invalidHeader:
                return "The bundled lexical index has an invalid header."
            case .unsupportedVersion(let version):
                return "The bundled lexical index uses unsupported version \(version)."
            case .invalidLayout:
                return "The bundled lexical index has an invalid layout."
            case .checksumMismatch:
                return "The bundled lexical index failed its integrity check."
            }
        }
    }

    static let resourceName = "lexical-index"
    static let resourceExtension = "wbli"

    /// Loading is lazy. The resource stays memory mapped rather than becoming a
    /// large graph of Swift strings and dictionaries.
    static let shared: CompactLexicalIndex = {
        do {
            return try CompactLexicalIndex()
        } catch {
            fatalError("Unable to load the bundled lexical index: \(error.localizedDescription)")
        }
    }()

    let wordCount: Int
    let aliasCount: Int
    let aliasMappingCount: Int
    let storageSize: Int

    private static let magic: [UInt8] = Array("WBLXIDX\0".utf8)
    private static let supportedVersion: UInt32 = 1
    private static let expectedHeaderSize = 88

    private let storage: NSData
    private let bytes: UnsafeRawPointer
    private let payloadChecksum: UInt32

    private let wordOffsetsOffset: Int
    private let wordBytesOffset: Int
    private let phraseBitsOffset: Int
    private let aliasStringOffsetsOffset: Int
    private let aliasBytesOffset: Int
    private let aliasTargetOffsetsOffset: Int
    private let aliasTargetsOffset: Int
    private let bookRecordsOffset: Int
    private let bookIndicesOffset: Int
    private let metadataStringsOffset: Int
    private let metadataStringsSize: Int
    private let bookCount: Int
    private let bookIndexCount: Int

    convenience init(
        bundle: Bundle = .main,
        resourceName: String = CompactLexicalIndex.resourceName,
        validateChecksum: Bool = false
    ) throws {
        guard let url = bundle.url(
            forResource: resourceName,
            withExtension: CompactLexicalIndex.resourceExtension
        ) else {
            throw IndexError.resourceMissing(name: resourceName)
        }
        try self.init(contentsOf: url, validateChecksum: validateChecksum)
    }

    convenience init(contentsOf url: URL, validateChecksum: Bool = false) throws {
        let mappedData = try NSData(contentsOf: url, options: [.mappedIfSafe])
        try self.init(storage: mappedData, validateChecksum: validateChecksum)
    }

    private init(storage: NSData, validateChecksum: Bool) throws {
        guard storage.length >= Self.expectedHeaderSize else {
            throw IndexError.invalidHeader
        }

        self.storage = storage
        bytes = storage.bytes

        let magicBytes = bytes.assumingMemoryBound(to: UInt8.self)
        for index in Self.magic.indices where magicBytes[index] != Self.magic[index] {
            throw IndexError.invalidHeader
        }

        let version = Self.readUInt32(bytes, at: 8)
        guard version == Self.supportedVersion else {
            throw IndexError.unsupportedVersion(version)
        }

        let headerSize = Int(Self.readUInt32(bytes, at: 12))
        let declaredFileSize = Int(Self.readUInt32(bytes, at: 16))
        guard headerSize == Self.expectedHeaderSize,
              declaredFileSize == storage.length else {
            throw IndexError.invalidHeader
        }

        wordCount = Int(Self.readUInt32(bytes, at: 20))
        aliasCount = Int(Self.readUInt32(bytes, at: 24))
        aliasMappingCount = Int(Self.readUInt32(bytes, at: 28))
        bookCount = Int(Self.readUInt32(bytes, at: 32))
        wordOffsetsOffset = Int(Self.readUInt32(bytes, at: 36))
        wordBytesOffset = Int(Self.readUInt32(bytes, at: 40))
        phraseBitsOffset = Int(Self.readUInt32(bytes, at: 44))
        aliasStringOffsetsOffset = Int(Self.readUInt32(bytes, at: 48))
        aliasBytesOffset = Int(Self.readUInt32(bytes, at: 52))
        aliasTargetOffsetsOffset = Int(Self.readUInt32(bytes, at: 56))
        aliasTargetsOffset = Int(Self.readUInt32(bytes, at: 60))
        bookRecordsOffset = Int(Self.readUInt32(bytes, at: 64))
        bookIndicesOffset = Int(Self.readUInt32(bytes, at: 68))
        metadataStringsOffset = Int(Self.readUInt32(bytes, at: 72))
        metadataStringsSize = Int(Self.readUInt32(bytes, at: 76))
        payloadChecksum = Self.readUInt32(bytes, at: 80)
        storageSize = storage.length

        let wordOffsetsEnd = wordOffsetsOffset + Self.checkedByteCount(wordCount + 1, stride: 4)
        let phraseBitsEnd = phraseBitsOffset + ((wordCount + 7) / 8)
        let aliasStringOffsetsEnd = aliasStringOffsetsOffset + Self.checkedByteCount(aliasCount + 1, stride: 4)
        let aliasTargetOffsetsEnd = aliasTargetOffsetsOffset + Self.checkedByteCount(aliasCount + 1, stride: 4)
        let aliasTargetsEnd = aliasTargetsOffset + Self.checkedByteCount(aliasMappingCount, stride: 4)
        let bookRecordsEnd = bookRecordsOffset + Self.checkedByteCount(bookCount, stride: 16)
        let metadataStringsEnd = metadataStringsOffset + metadataStringsSize
        bookIndexCount = max(0, (metadataStringsOffset - bookIndicesOffset) / 4)

        guard headerSize <= wordOffsetsOffset,
              wordOffsetsEnd <= wordBytesOffset,
              wordBytesOffset <= phraseBitsOffset,
              phraseBitsEnd <= aliasStringOffsetsOffset,
              aliasStringOffsetsEnd <= aliasBytesOffset,
              aliasBytesOffset <= aliasTargetOffsetsOffset,
              aliasTargetOffsetsEnd <= aliasTargetsOffset,
              aliasTargetsEnd <= bookRecordsOffset,
              bookRecordsEnd <= bookIndicesOffset,
              bookIndicesOffset <= metadataStringsOffset,
              metadataStringsEnd <= storage.length,
              (metadataStringsOffset - bookIndicesOffset).isMultiple(of: 4),
              readOffset(from: wordOffsetsOffset, index: 0) == 0,
              readOffset(from: aliasStringOffsetsOffset, index: 0) == 0,
              readOffset(from: aliasTargetOffsetsOffset, index: 0) == 0,
              readOffset(from: wordOffsetsOffset, index: wordCount) <= phraseBitsOffset - wordBytesOffset,
              readOffset(from: aliasStringOffsetsOffset, index: aliasCount) <= aliasTargetOffsetsOffset - aliasBytesOffset,
              readOffset(from: aliasTargetOffsetsOffset, index: aliasCount) == aliasMappingCount else {
            throw IndexError.invalidLayout
        }

        guard validateBookRecords() else {
            throw IndexError.invalidLayout
        }
        if validateChecksum && !hasValidChecksum() {
            throw IndexError.checksumMismatch
        }
    }

    /// Canonicalizes exact spellings first, then case-insensitive spellings,
    /// then aliases. This mirrors the old lookup behavior without loading a SQL
    /// database or carrying dictionary definitions.
    func canonicalWord(for spellingOrAlias: String) -> String? {
        let key = Self.foldedBytes(spellingOrAlias)
        guard !key.isEmpty else { return nil }

        let start = lowerBoundWord(for: key)
        var index = start
        var foldedMatch: Int?
        while index < wordCount && compareWord(at: index, to: key) == 0 {
            if foldedMatch == nil {
                foldedMatch = index
            }
            if word(at: index) == spellingOrAlias {
                return word(at: index)
            }
            index += 1
        }
        if let foldedMatch = foldedMatch {
            return word(at: foldedMatch)
        }
        return canonicalWords(forAlias: spellingOrAlias).first
    }

    /// Compatibility spelling for call sites that previously queried whether a
    /// word existed and expected the normalized spelling back.
    func exist(_ spellingOrAlias: String) -> String? {
        canonicalWord(for: spellingOrAlias)
    }

    /// Returns every canonical target retained for an exact alias, in the old
    /// database's stable row order. Most call sites should use `canonicalWord`.
    func canonicalWords(forAlias alias: String) -> [String] {
        let key = Self.foldedBytes(alias)
        guard !key.isEmpty else { return [] }
        let aliasIndex = lowerBoundAlias(for: key)
        guard aliasIndex < aliasCount,
              compareAlias(at: aliasIndex, to: key) == 0 else {
            return []
        }
        return aliasWordIndices(at: aliasIndex).map(word(at:))
    }

    /// Search suggestions ranked as exact spelling, exact alias, ordinary-word
    /// prefix, alias prefix, then phrase prefix. `?` and `*` retain the old
    /// single-character and multi-character wildcard behavior.
    func searchHints(_ input: String, limit: Int = 30) -> [String]? {
        guard input.count >= 2 else { return nil }
        guard limit > 0 else { return [] }

        if input.contains("?") || input.contains("*") {
            return wildcardSearchHints(input, limit: limit)
        }

        let key = Self.foldedBytes(input)
        guard !key.isEmpty else { return [] }

        var results: [String] = []
        var selectedWordIndices = Set<Int>()

        // Only a byte-for-byte spelling receives the highest rank. Other case
        // variants remain available in the normal prefix results.
        var wordIndex = lowerBoundWord(for: key)
        while wordIndex < wordCount && compareWord(at: wordIndex, to: key) == 0 {
            if word(at: wordIndex) == input {
                appendWord(wordIndex, to: &results, selected: &selectedWordIndices, limit: limit)
                break
            }
            wordIndex += 1
        }

        let exactAliasIndex = lowerBoundAlias(for: key)
        if exactAliasIndex < aliasCount,
           compareAlias(at: exactAliasIndex, to: key) == 0,
           let target = aliasWordIndices(at: exactAliasIndex).first {
            appendWord(target, to: &results, selected: &selectedWordIndices, limit: limit)
        }

        var deferredPhrases: [Int] = []
        wordIndex = lowerBoundWord(for: key)
        while wordIndex < wordCount && wordHasPrefix(at: wordIndex, prefix: key) {
            if isPhrase(at: wordIndex) {
                if deferredPhrases.count < limit {
                    deferredPhrases.append(wordIndex)
                }
            } else {
                appendWord(wordIndex, to: &results, selected: &selectedWordIndices, limit: limit)
                if results.count == limit { return results }
            }
            wordIndex += 1
        }

        var aliasIndex = lowerBoundAlias(for: key)
        while aliasIndex < aliasCount && aliasHasPrefix(at: aliasIndex, prefix: key) {
            for target in aliasWordIndices(at: aliasIndex) {
                appendWord(target, to: &results, selected: &selectedWordIndices, limit: limit)
                if results.count == limit { return results }
            }
            aliasIndex += 1
        }

        for phrase in deferredPhrases {
            appendWord(phrase, to: &results, selected: &selectedWordIndices, limit: limit)
            if results.count == limit { break }
        }
        return results
    }

    var bookTags: [String] {
        (0..<bookCount).map(bookTag(at:))
    }

    func words(inBookTagPrefix tagPrefix: String) -> [String] {
        candidateWordIndices(inBookTagPrefix: tagPrefix).map(word(at:))
    }

    func randomWords(book tagPrefix: String, num: Int) -> [String] {
        var generator = SystemRandomNumberGenerator()
        return randomWords(bookTagPrefix: tagPrefix, count: num, using: &generator)
    }

    func randomWords<T: RandomNumberGenerator>(
        bookTagPrefix tagPrefix: String,
        count requestedCount: Int,
        using generator: inout T
    ) -> [String] {
        var candidates = candidateWordIndices(inBookTagPrefix: tagPrefix)
        let resultCount = min(max(0, requestedCount), candidates.count)
        guard resultCount > 0 else { return [] }

        // A partial Fisher-Yates shuffle avoids shuffling or decoding the full
        // vocabulary book when only one word is requested.
        for index in 0..<resultCount {
            let selectedIndex = Int.random(in: index..<candidates.count, using: &generator)
            candidates.swapAt(index, selectedIndex)
        }
        return candidates.prefix(resultCount).map(word(at:))
    }

    func randomWord() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomWord(using: &generator)
    }

    func randomWord<T: RandomNumberGenerator>(using generator: inout T) -> String {
        guard wordCount > 0 else { return "" }

        // About 57% of the bundled spellings are single words, so rejection is
        // both unbiased and normally succeeds in fewer than two samples.
        for _ in 0..<64 {
            let index = Int.random(in: 0..<wordCount, using: &generator)
            if !isPhrase(at: index) {
                return word(at: index)
            }
        }
        for index in 0..<wordCount where !isPhrase(at: index) {
            return word(at: index)
        }
        return ""
    }

    /// Optional full-file validation for build/tests. Normal app loading only
    /// validates section bounds because the resource is protected by app code
    /// signing and reading all 4.8 MB would defeat some mmap startup savings.
    func hasValidChecksum() -> Bool {
        var crc = UInt32.max
        let start = Self.expectedHeaderSize
        let pointer = bytes.assumingMemoryBound(to: UInt8.self)
        for index in start..<storage.length {
            let tableIndex = Int((crc ^ UInt32(pointer[index])) & 0xff)
            crc = Self.crc32Table[tableIndex] ^ (crc >> 8)
        }
        return (crc ^ UInt32.max) == payloadChecksum
    }

    private func wildcardSearchHints(_ input: String, limit: Int) -> [String] {
        let pattern = Self.foldedBytes(input)
        let literalPrefix = Array(pattern.prefix { $0 != 42 && $0 != 63 }) // * and ?
        var results: [String] = []
        var selectedWordIndices = Set<Int>()
        var deferredPhrases: [Int] = []

        var wordIndex = literalPrefix.isEmpty ? 0 : lowerBoundWord(for: literalPrefix)
        while wordIndex < wordCount {
            if !literalPrefix.isEmpty && !wordHasPrefix(at: wordIndex, prefix: literalPrefix) {
                break
            }
            if wildcardMatchesWord(at: wordIndex, pattern: pattern) {
                if isPhrase(at: wordIndex) {
                    if deferredPhrases.count < limit {
                        deferredPhrases.append(wordIndex)
                    }
                } else {
                    appendWord(wordIndex, to: &results, selected: &selectedWordIndices, limit: limit)
                    if results.count == limit { return results }
                }
            }
            wordIndex += 1
        }

        var aliasIndex = literalPrefix.isEmpty ? 0 : lowerBoundAlias(for: literalPrefix)
        while aliasIndex < aliasCount {
            if !literalPrefix.isEmpty && !aliasHasPrefix(at: aliasIndex, prefix: literalPrefix) {
                break
            }
            if wildcardMatchesAlias(at: aliasIndex, pattern: pattern) {
                for target in aliasWordIndices(at: aliasIndex) {
                    appendWord(target, to: &results, selected: &selectedWordIndices, limit: limit)
                    if results.count == limit { return results }
                }
            }
            aliasIndex += 1
        }

        for phrase in deferredPhrases {
            appendWord(phrase, to: &results, selected: &selectedWordIndices, limit: limit)
            if results.count == limit { break }
        }
        return results
    }

    private func candidateWordIndices(inBookTagPrefix tagPrefix: String) -> [Int] {
        let foldedPrefix = Self.foldedBytes(tagPrefix)
        var result: [Int] = []
        var selected = Set<Int>()

        for bookIndex in 0..<bookCount {
            let tag = Self.foldedBytes(bookTag(at: bookIndex))
            guard tag.starts(with: foldedPrefix) else { continue }
            let recordOffset = bookRecordsOffset + (bookIndex * 16)
            let start = Int(readUInt32(at: recordOffset + 8))
            let count = Int(readUInt32(at: recordOffset + 12))
            for index in start..<(start + count) {
                let wordIndex = Int(readUInt32(at: bookIndicesOffset + (index * 4)))
                if selected.insert(wordIndex).inserted {
                    result.append(wordIndex)
                }
            }
        }
        return result
    }

    private func validateBookRecords() -> Bool {
        for index in 0..<bookCount {
            let offset = bookRecordsOffset + (index * 16)
            let tagStart = Int(readUInt32(at: offset))
            let tagLength = Int(readUInt32(at: offset + 4))
            let indexStart = Int(readUInt32(at: offset + 8))
            let indexCount = Int(readUInt32(at: offset + 12))
            guard tagStart <= metadataStringsSize,
                  tagLength <= metadataStringsSize - tagStart,
                  indexStart <= bookIndexCount,
                  indexCount <= bookIndexCount - indexStart else {
                return false
            }
        }
        return true
    }

    private func bookTag(at index: Int) -> String {
        let recordOffset = bookRecordsOffset + (index * 16)
        let start = Int(readUInt32(at: recordOffset))
        let length = Int(readUInt32(at: recordOffset + 4))
        return string(at: metadataStringsOffset + start, length: length)
    }

    private func lowerBoundWord(for key: [UInt8]) -> Int {
        var lower = 0
        var upper = wordCount
        while lower < upper {
            let middle = lower + ((upper - lower) / 2)
            if compareWord(at: middle, to: key) < 0 {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func lowerBoundAlias(for key: [UInt8]) -> Int {
        var lower = 0
        var upper = aliasCount
        while lower < upper {
            let middle = lower + ((upper - lower) / 2)
            if compareAlias(at: middle, to: key) < 0 {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func compareWord(at index: Int, to key: [UInt8]) -> Int {
        let bounds = wordByteBounds(at: index)
        return compareFoldedBytes(at: wordBytesOffset + bounds.start, length: bounds.length, to: key)
    }

    private func compareAlias(at index: Int, to key: [UInt8]) -> Int {
        let bounds = aliasByteBounds(at: index)
        return compareFoldedBytes(at: aliasBytesOffset + bounds.start, length: bounds.length, to: key)
    }

    private func compareFoldedBytes(at offset: Int, length: Int, to key: [UInt8]) -> Int {
        let pointer = bytes.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        let commonLength = min(length, key.count)
        for index in 0..<commonLength {
            let lhs = Self.foldASCII(pointer[index])
            let rhs = key[index]
            if lhs < rhs { return -1 }
            if lhs > rhs { return 1 }
        }
        if length < key.count { return -1 }
        if length > key.count { return 1 }
        return 0
    }

    private func wordHasPrefix(at index: Int, prefix: [UInt8]) -> Bool {
        let bounds = wordByteBounds(at: index)
        return hasFoldedPrefix(at: wordBytesOffset + bounds.start, length: bounds.length, prefix: prefix)
    }

    private func aliasHasPrefix(at index: Int, prefix: [UInt8]) -> Bool {
        let bounds = aliasByteBounds(at: index)
        return hasFoldedPrefix(at: aliasBytesOffset + bounds.start, length: bounds.length, prefix: prefix)
    }

    private func hasFoldedPrefix(at offset: Int, length: Int, prefix: [UInt8]) -> Bool {
        guard length >= prefix.count else { return false }
        let pointer = bytes.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        for index in prefix.indices where Self.foldASCII(pointer[index]) != prefix[index] {
            return false
        }
        return true
    }

    private func wildcardMatchesWord(at index: Int, pattern: [UInt8]) -> Bool {
        let bounds = wordByteBounds(at: index)
        return wildcardMatches(at: wordBytesOffset + bounds.start, length: bounds.length, pattern: pattern)
    }

    private func wildcardMatchesAlias(at index: Int, pattern: [UInt8]) -> Bool {
        let bounds = aliasByteBounds(at: index)
        return wildcardMatches(at: aliasBytesOffset + bounds.start, length: bounds.length, pattern: pattern)
    }

    private func wildcardMatches(at offset: Int, length: Int, pattern: [UInt8]) -> Bool {
        let pointer = bytes.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        var valueIndex = 0
        var patternIndex = 0
        var starIndex: Int?
        var retryValueIndex = 0

        while valueIndex < length {
            if patternIndex < pattern.count,
               pattern[patternIndex] != 42,
               (pattern[patternIndex] == 63 || pattern[patternIndex] == Self.foldASCII(pointer[valueIndex])) {
                valueIndex += 1
                patternIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == 42 {
                starIndex = patternIndex
                patternIndex += 1
                retryValueIndex = valueIndex
            } else if let starIndex = starIndex {
                patternIndex = starIndex + 1
                retryValueIndex += 1
                valueIndex = retryValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count && pattern[patternIndex] == 42 {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }

    private func appendWord(
        _ index: Int,
        to results: inout [String],
        selected: inout Set<Int>,
        limit: Int
    ) {
        guard results.count < limit, selected.insert(index).inserted else { return }
        results.append(word(at: index))
    }

    private func word(at index: Int) -> String {
        let bounds = wordByteBounds(at: index)
        return string(at: wordBytesOffset + bounds.start, length: bounds.length)
    }

    private func aliasWordIndices(at aliasIndex: Int) -> [Int] {
        let start = readOffset(from: aliasTargetOffsetsOffset, index: aliasIndex)
        let end = readOffset(from: aliasTargetOffsetsOffset, index: aliasIndex + 1)
        guard end >= start else { return [] }
        return (start..<end).map { Int(readUInt32(at: aliasTargetsOffset + ($0 * 4))) }
    }

    private func isPhrase(at wordIndex: Int) -> Bool {
        let byte = bytes.assumingMemoryBound(to: UInt8.self)[phraseBitsOffset + (wordIndex >> 3)]
        return (byte & (1 << UInt8(wordIndex & 7))) != 0
    }

    private func wordByteBounds(at index: Int) -> (start: Int, length: Int) {
        byteBounds(offsetTable: wordOffsetsOffset, index: index)
    }

    private func aliasByteBounds(at index: Int) -> (start: Int, length: Int) {
        byteBounds(offsetTable: aliasStringOffsetsOffset, index: index)
    }

    private func byteBounds(offsetTable: Int, index: Int) -> (start: Int, length: Int) {
        let start = readOffset(from: offsetTable, index: index)
        let end = readOffset(from: offsetTable, index: index + 1)
        return (start, max(0, end - start))
    }

    private func readOffset(from tableOffset: Int, index: Int) -> Int {
        Int(readUInt32(at: tableOffset + (index * 4)))
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        Self.readUInt32(bytes, at: offset)
    }

    private static func readUInt32(_ bytes: UnsafeRawPointer, at offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.load(fromByteOffset: offset, as: UInt32.self))
    }

    private func string(at offset: Int, length: Int) -> String {
        let pointer = bytes.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private static func foldedBytes(_ value: String) -> [UInt8] {
        value.utf8.map(foldASCII)
    }

    private static func foldASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func checkedByteCount(_ count: Int, stride: Int) -> Int {
        let (result, overflow) = count.multipliedReportingOverflow(by: stride)
        return overflow ? Int.max : result
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
            return crc
        }
    }()
}
