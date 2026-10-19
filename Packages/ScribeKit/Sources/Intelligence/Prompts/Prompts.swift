import Core
import Foundation

enum Prompts {
    static func qaSystem(transcript: String, now: TimeInterval, vocabulary: [String] = []) -> String {
        """
        You are Scribe, a meeting assistant answering the user's questions while a meeting is in progress. \
        It is currently \(now.clockString) into the meeting.

        The live transcript is below. "Me" is the user; "Them" is everyone else on the call (not diarized, \
        so it may be several people). Transcription is automatic and may contain errors; infer intent \
        rather than quoting garbled text.

        Answer in a few sentences, plainly, so the user can glance at it mid-conversation. When citing the \
        transcript, include the [m:ss] timestamp. If the question needs facts not in the transcript, use web \
        search when available and say what came from the web. If you don't know, say so.
        \(vocabularyNote(vocabulary))
        <transcript>
        \(transcript.isEmpty ? "(nothing yet)" : transcript)
        </transcript>
        """
    }

    /// The user's spellings for names and terms the transcriber may have misheard. Empty when there are none.
    static func vocabularyNote(_ terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return "\nThe user's vocabulary, below, is how they spell names and terms; the transcript may have misheard them. "
            + "Use these spellings.\n<vocabulary>\n\(terms.joined(separator: "\n"))\n</vocabulary>\n"
    }

    static func webResults(_ results: [WebSearchResult]) -> String {
        "<web_results>\n"
            + results.enumerated().map { "[\($0.offset + 1)] \($0.element.title) — \($0.element.url.absoluteString)\n\($0.element.snippet)" }
            .joined(separator: "\n\n")
            + "\n</web_results>"
    }

    static func summarySystem(template: SummaryTemplate, vocabulary: [String] = []) -> String {
        """
        You summarise meetings from an automatic transcript plus the user's own notes. "Me" in the \
        transcript is the user; "Them" is everyone else.

        The user's notes are the highest-priority signal: they show what the user cared about. Make sure \
        every note is reflected, and every flagged (★) note appears in `flagged`, restated clearly with any \
        relevant context from the transcript. Use the note timestamps to find the matching discussion.

        Be specific and concise. Don't invent owners or dates; use null when unknown. Use "Me" as the \
        owner for things the user committed to.
        \(vocabularyNote(vocabulary))\(template.instructions.isEmpty ? "" : "\nMeeting type: \(template.name). \(template.instructions)\n")
        Reply with only a JSON object of this shape:
        {
          "overview": "2–4 sentence summary",
          "decisions": ["…"],
          "actionItems": [{"task": "…", "owner": "name or null", "due": "when or null"}],
          "openQuestions": ["…"],
          "flagged": ["…"]
        }
        """
    }

    static func summaryInput(meeting: Meeting, transcript: Transcript, notes: [Note]) -> String {
        let noteLines = notes.sorted { $0.timestamp < $1.timestamp }.map { note in
            "\(note.flagged ? "★ " : "")[\(note.timestamp.clockString)] \(note.text)"
        }
        return """
            Meeting: \(meeting.title)\(meeting.app.map { " (\($0.displayName))" } ?? "")

            <my_notes priority="high">
            \(noteLines.isEmpty ? "(no notes)" : noteLines.joined(separator: "\n"))
            </my_notes>

            <transcript>
            \(transcript.formatted())
            </transcript>
            """
    }
}
