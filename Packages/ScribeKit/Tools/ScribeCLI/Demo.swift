import ArgumentParser
import Core
import Foundation
import Fixtures
import Intelligence
import Notes
import Persistence
import Session
import Transcription

struct Demo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a meeting through the real session, notes, Q&A and summary code with fake audio, transcription and LLM.",
        discussion: """
            Audio is silence paced in real time: system audio ("Them") from 0s, the mic ("Me") from half a segment in. \
            The fake transcriber emits a partial halfway through each segment and a final at the end of it. The echo LLM \
            answers by describing the prompt it was sent.

            Notes and questions take an optional "<seconds>:" prefix to run at that point in the meeting; without one \
            they run after the audio ends, just before stopping.

              scribe demo --seconds 12 --note "5:! billing is the main risk" --ask "7:what did they just say?" --ask "summarize so far"
            """)

    @Option(help: "Seconds of audio.")
    var seconds: Double = 12

    @Option(help: "Seconds of audio per fake transcript segment.")
    var segment: Double = 4

    @Option(help: "\"[<seconds>:]text\". A leading ! flags the note. Repeatable.")
    var note: [String] = []

    @Option(help: "\"[<seconds>:]question\". Repeatable; later questions see earlier answers.")
    var ask: [String] = []

    @Option var title = "Demo meeting"

    @Option(help: "Summary template id: \(SummaryTemplates.all.map(\.id).joined(separator: ", ")).")
    var template = SummaryTemplate.general.id

    @Option(help: "File the meeting into this folder, creating it if needed.")
    var folder: String?

    @Option(help: "Tag the meeting. Repeatable.")
    var tag: [String] = []

    @Option(help: "SQLite file to save into, created if needed. Default: in memory.")
    var db: String?

    @Flag(help: "Stop without summarizing.")
    var noSummary = false

    func run() async throws {
        let database = try db.map { try ScribeDatabase(url: URL(filePath: $0)) } ?? .inMemory()
        let llm = EchoLLM()
        let (seconds, segment) = (seconds, segment)
        let env = SessionEnvironment(
            makeSources: { _ in [SilentSource(.system, from: 0, until: seconds), SilentSource(.mic, from: segment / 2, until: seconds)] },
            transcriber: FakeTranscriptionProvider(segmentDuration: segment),
            summarizer: noSummary ? nil : LLMSummarizer(llm: llm),
            meetings: database.meetings, transcripts: database.transcripts, notes: database.notes, summaries: database.summaries,
            drainTimeout: .seconds(2))
        let session = MeetingSession(meeting: Meeting(title: title, templateID: template), scope: .allApps, environment: env)
        let clock = session.clock
        let notes = NotesController(meetingID: session.meetingID, clock: clock, repository: database.notes)
        let qa = QAEngine(llm: llm)
        func log(_ line: String) { print(String(format: "%6.2fs  ", clock.now) + line) }

        let printer = Task {
            for await event in session.events() {
                switch event {
                case .state(let state): log("state    \(state)")
                case .segment(let s): log("\(s.isFinal ? "final  " : "partial") \(s.speaker == .me ? "Me  " : "Them") [\(s.start.clockString)] \(s.text)")
                case .segmentRemoved(let id): log("echo removed \(id)")
                case .transcriptionStatus(let source, let status): log("\(source.rawValue): \(status)")
                case .summary: log("summary  saved")
                case .title(let title): log("title    \(title)")
                case .warning(let message): log("warning  \(message)")
                }
            }
        }

        var steps = (note.map { Step($0, isNote: true) } + ask.map { Step($0, isNote: false) })
        steps.sort { ($0.at ?? .infinity) < ($1.at ?? .infinity) }
        var history: [LLMMessage] = []

        try await session.start()
        for step in steps {
            // Untimed steps wait for the audio to end and the last chunk to be transcribed.
            let wait = (step.at ?? seconds + 0.5) - clock.now
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            if step.isNote {
                var draft = NoteDraft()
                draft.update(step.text, now: clock.now)
                if let saved = try await notes.commit(draft) { log("note     \(saved.flagged ? "★ " : "")[\(saved.timestamp.clockString)] \(saved.text)") }
            } else {
                log("ask      \(step.text)")
                var answer = ""
                for try await delta in qa.answer(step.text, transcript: await session.transcript, now: clock.now, history: history) {
                    switch delta {
                    case .text(let t): answer += t
                    case .activity(let a): log("activity \(a)")
                    case .sources(let sources): sources.forEach { log("source   \($0.title) \($0.url)") }
                    case .done(let reason): log("answer   (\(reason ?? "done")) \(answer)")
                    case .toolCall: break
                    }
                }
                history += [LLMMessage(role: .user, content: step.text), LLMMessage(role: .assistant, content: answer)]
            }
        }
        let tail = seconds - clock.now
        if tail > 0 { try await Task.sleep(for: .seconds(tail)) }

        log("stopping")
        await session.stop()
        await printer.value

        if let folder {
            let existing = try await database.library.folders().first { $0.name.caseInsensitiveCompare(folder) == .orderedSame }
            let target: Folder
            if let existing { target = existing } else { target = try await database.library.createFolder(named: folder) }
            try await database.library.move(meetingID: session.meetingID, toFolder: target.id)
        }
        if !tag.isEmpty { try await database.library.setTags(tag, meetingID: session.meetingID) }

        print("\nSaved \(db ?? "in memory")\n")
        try await dumpMeeting(await session.meeting, in: database)
    }
}

private struct Step {
    var at: TimeInterval?
    var text: String
    var isNote: Bool

    /// "5:text" runs at 5s; anything else is untimed.
    init(_ raw: String, isNote: Bool) {
        self.isNote = isNote
        if let colon = raw.firstIndex(of: ":"), let at = TimeInterval(raw[..<colon]) {
            self.at = at
            text = String(raw[raw.index(after: colon)...])
        } else {
            text = raw
        }
    }
}
