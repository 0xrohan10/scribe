import Foundation

/// A name or term the user wants spelled their way.
public struct VocabularyEntry: Sendable, Identifiable, Hashable, Codable {
    public var id: UUID
    public var term: String
    /// What the transcriber writes instead, e.g. "Rowan" for "Rohan". When set, finished text has it rewritten to `term`.
    public var heardAs: String?

    public init(id: UUID = UUID(), term: String, heardAs: String? = nil) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
    }
}

public enum VocabularyError: Error, LocalizedError, Equatable {
    case empty
    case tooLong
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a word or phrase."
        case .tooLong: "Keep it under \(Vocabulary.maxLength) characters."
        case .duplicate(let term): "“\(term)” is already in your vocabulary."
        }
    }
}

/// The user's custom vocabulary. Terms bias recognition (and the LLM's spelling); corrections rewrite finished text.
public struct Vocabulary: Sendable, Equatable, Codable {
    public var entries: [VocabularyEntry]

    public static let maxLength = 60

    public init(entries: [VocabularyEntry] = []) {
        self.entries = entries
    }

    /// Every term, deduplicated case-insensitively, for recognition hints and prompts.
    public var terms: [String] {
        var seen = Set<String>()
        return entries.map(\.term).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Trims and checks an entry before it's saved. Returns it cleaned up; a `heardAs` identical to the term is dropped.
    public func validated(_ entry: VocabularyEntry) throws -> VocabularyEntry {
        var entry = entry
        entry.term = try Self.clean(entry.term)
        entry.heardAs = try entry.heardAs.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try Self.clean($0) }
        if entry.heardAs == entry.term { entry.heardAs = nil }
        if entries.contains(where: { $0.id != entry.id && $0.term.lowercased() == entry.term.lowercased() }) {
            throw VocabularyError.duplicate(entry.term)
        }
        return entry
    }

    private static func clean(_ text: String) throws -> String {
        let text = text.trimmingCharacters(in: .whitespaces).replacing(/\s+/, with: " ")
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { throw VocabularyError.empty }
        guard text.count <= maxLength else { throw VocabularyError.tooLong }
        return text
    }

    /// Applies the corrections: whole words, any case, longest phrase first. Possessives follow ("Rowan's" → "Rohan's");
    /// contractions don't ("don't" is left alone by a "don" rule).
    public func correct(_ text: String) -> String {
        let lookup = Dictionary(entries.compactMap { e in e.heardAs.map { (Self.key($0), e.term) } }, uniquingKeysWith: { _, last in last })
        guard !lookup.isEmpty else { return text }
        let alternatives = lookup.keys.sorted { $0.count > $1.count }.map {
            $0.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        }
        let pattern = #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + #")(?![\p{L}\p{N}]|['’](?!s(?![\p{L}\p{N}]))\p{L})"#
        // NSRegularExpression because Swift's Regex has no lookbehind. Every alternative is escaped, so this can't throw.
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let result = NSMutableString(string: text)
        // Back to front, so earlier ranges stay valid.
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            if let term = lookup[Self.key(result.substring(with: match.range))] { result.replaceCharacters(in: match.range, with: term) }
        }
        return result as String
    }

    private static func key(_ phrase: String) -> String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
