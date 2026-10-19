import Foundation
import Testing

@testable import Core

@Suite struct TranscriptTests {
    @Test func upsertReplacesPartialAndKeepsOrder() {
        var t = Transcript()
        let id = UUID()
        t.upsert(TranscriptSegment(id: id, speaker: .them, text: "hel", start: 4, end: 5, isFinal: false))
        t.upsert(TranscriptSegment(speaker: .me, text: "first", start: 1, end: 2, isFinal: true))
        t.upsert(TranscriptSegment(id: id, speaker: .them, text: "hello there", start: 4, end: 6, isFinal: true))
        #expect(t.segments.map(\.text) == ["first", "hello there"])
    }

    @Test func formattedUsesClockAndSpeaker() {
        let t = Transcript(segments: [TranscriptSegment(speaker: .them, text: "Ship it", start: 75, end: 76, isFinal: true)])
        #expect(t.formatted() == "[1:15] Them: Ship it")
    }

    @Test func clockString() {
        #expect(TimeInterval(5).clockString == "0:05")
        #expect(TimeInterval(3725).clockString == "1:02:05")
    }
}

@Suite struct LibraryModelTests {
    @Test func normalizesTags() {
        #expect(Tags.normalize(["  #Acme ", "acme", "q4   planning", "", "#"]) == ["Acme", "q4 planning"])
    }

    @Test func filters() {
        let folder = UUID()
        let filed = LibraryEntry(meeting: Meeting(title: "a"), folderID: folder, tags: ["Acme"])
        let loose = LibraryEntry(meeting: Meeting(title: "b"))
        #expect(LibraryFilter.folder(folder).matches(filed) && !LibraryFilter.folder(folder).matches(loose))
        #expect(LibraryFilter.unfiled.matches(loose) && !LibraryFilter.unfiled.matches(filed))
        #expect(LibraryFilter.tag("acme").matches(filed) && !LibraryFilter.tag("acme").matches(loose))
        #expect(LibraryFilter.all.matches(filed) && LibraryFilter.all.matches(loose))
    }
}

@Suite struct RegistryTests {
    @Test func enforcesAPIKeyAndAvailability() throws {
        var r = ProviderRegistry<String>()
        r.register(ProviderDescriptor(id: "keyed", displayName: "K", needsAPIKey: true)) { _ in "k" }
        r.register(ProviderDescriptor(id: "off", displayName: "O", isAvailable: false)) { _ in "o" }

        #expect(throws: ProviderError.missingAPIKey("keyed")) { try r.make(id: "keyed", config: .init()) }
        #expect(try r.make(id: "keyed", config: .init(apiKey: "x")) == "k")
        #expect(throws: ProviderError.unavailable("off")) { try r.make(id: "off", config: .init()) }
        #expect(throws: ProviderError.unknownProvider("nope")) { try r.make(id: "nope", config: .init()) }
    }
}

@Suite struct BroadcasterTests {
    @Test func deliversToAllSubscribersAndFinishes() async {
        let b = Broadcaster<Int>()
        let s1 = b.subscribe(), s2 = b.subscribe()
        b.send(1)
        b.send(2)
        b.finish()
        #expect(await Array(s1) == [1, 2])
        #expect(await Array(s2) == [1, 2])
        #expect(await Array(b.subscribe()) == [])
    }
}

extension Array {
    init<S: AsyncSequence>(_ s: S) async where S.Element == Element {
        self = []
        do { for try await e in s { append(e) } } catch {}
    }
}

@Suite struct VocabularyTests {
    private func vocab(_ rules: [(String, String?)]) -> Vocabulary {
        Vocabulary(entries: rules.map { VocabularyEntry(term: $0.0, heardAs: $0.1) })
    }

    @Test func correctsWholeWordsInAnyCaseKeepingSavedSpelling() {
        let v = vocab([("Rohan", "rowan"), ("WhisperKit", "whisper kit")])
        #expect(v.correct("Rowan said WHISPER  kit is fast, not rowans or arrowan") == "Rohan said WhisperKit is fast, not rowans or arrowan")
    }

    @Test func longestPhraseWins() {
        let v = vocab([("Jo", "joe"), ("Joe Biden's dog", "joe biden")])
        #expect(v.correct("joe met joe biden") == "Jo met Joe Biden's dog")
    }

    @Test func possessivesFollowButContractionsDont() {
        let v = vocab([("Rohan", "rowan"), ("Dan", "don")])
        #expect(v.correct("Rowan's plan and Rowan’s notes") == "Rohan's plan and Rohan’s notes")
        #expect(v.correct("don't ask don") == "don't ask Dan")
    }

    @Test func escapesRegexCharacters() {
        let v = vocab([("C#", "c sharp"), ("Node.js", "node.js")])
        #expect(v.correct("c sharp and node.js but not nodexjs") == "C# and Node.js but not nodexjs")
    }

    @Test func termsAreDedupedAndIncludeCorrections() {
        #expect(vocab([("Rohan", "rowan"), ("Scribe", nil), ("rohan", nil)]).terms == ["Rohan", "Scribe"])
    }

    @Test func validation() throws {
        let v = vocab([("Scribe", nil)])
        #expect(throws: VocabularyError.empty) { try v.validated(VocabularyEntry(term: "  ?! ")) }
        #expect(throws: VocabularyError.tooLong) { try v.validated(VocabularyEntry(term: String(repeating: "a", count: 61))) }
        #expect(throws: VocabularyError.duplicate("scribe")) { try v.validated(VocabularyEntry(term: "scribe")) }
        let cleaned = try v.validated(VocabularyEntry(term: "  Whisper   Kit ", heardAs: " "))
        #expect(cleaned.term == "Whisper Kit" && cleaned.heardAs == nil)
        #expect(try v.validated(VocabularyEntry(term: "iPhone", heardAs: "iphone")).heardAs == "iphone")
        // Editing an entry doesn't collide with itself.
        #expect(try v.validated(v.entries[0]).term == "Scribe")
    }
}
