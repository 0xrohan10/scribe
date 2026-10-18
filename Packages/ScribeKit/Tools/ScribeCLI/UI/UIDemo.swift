import ApplicationServices
import ArgumentParser
import Core
import Foundation
import Persistence

struct UIDemo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "Record, take notes, ask, stop, summarize and file a meeting through the real UI, checking each step.",
        discussion: "Launches a fresh Scribe under test, prints ✓ per step and exits non-zero at the first failure. Takes about 30 s.")

    @Option(help: "The Debug app bundle.")
    var app = UISession.defaultAppPath

    @Flag(help: "Leave the app running afterwards, e.g. to poke at it with the other `scribe ui` commands.")
    var keepOpen = false

    func run() async throws {
        let app = try await UISession.launch(appPath: self.app)
        let started = Date.now
        func step(_ name: String, _ body: () async throws -> Void) async throws {
            do {
                try await body()
                print(String(format: "✓ %5.1fs  %@", Date.now.timeIntervalSince(started), name))
            } catch {
                print("✗ \(name): \(error)")
                if !keepOpen { UISession.quit() }
                throw ExitCode.failure
            }
        }
        /// The first element matching `query` whose text contains `text`.
        func waitFor(_ query: String, containing text: String, timeout: Double = 10) async throws -> Element {
            try await app.wait("“\(query)” containing “\(text)”", timeout: timeout) { app.all(query).first { $0.text.contains(text) } }
        }

        try await step("launch with fakes") {}

        try await step("start recording from the menu bar") {
            try await app.menu("Start Recording")
            _ = try await waitFor("meeting.state", containing: "Recording")
        }

        try await step("live transcript shows a final segment") {
            _ = try await waitFor("transcript.segment", containing: "Thanks everyone for joining", timeout: 8)
        }

        try await step("add a flagged note") {
            try await app.type("! billing is the main risk", into: try app.find("notes.draft"))
            try app.press("notes.add")
            let row = try await waitFor("notes.row", containing: "billing is the main risk")
            guard row.descendants().contains(where: { $0.identifier == "notes.flagged" }) else { throw UIError("Note isn't flagged: \(row.text)") }
            guard !row.text.contains("!") else { throw UIError("The ! wasn't stripped: \(row.text)") }
        }

        try await step("“what did they just say?” is answered from the transcript") {
            try app.press("Ask")  // The side panel's tab.
            try await app.type("what did they just say?", into: try app.find("ask.field"), submit: true)
            _ = try await waitFor("ask.answer", containing: "They said")
        }

        try await step("other questions go to the LLM with the transcript") {
            try await app.type("what's the plan?", into: try app.find("ask.field"), submit: true)
            let answer = try await waitFor("ask.answer", containing: "(echo)")
            guard !answer.text.contains("with 0 transcript lines") else { throw UIError("The LLM got no transcript: \(answer.text)") }
        }

        try await step("tag the meeting from its header") {
            try await app.type("acme", into: try app.find("organize.addTag"), submit: true)
            _ = try await waitFor("tag", containing: "acme")
        }

        try await step("stop, then the summary shows the flagged note") {
            try app.press("meeting.stop")
            _ = try await waitFor("meeting.state", containing: "Finished", timeout: 20)
            _ = try await waitFor("summary.overview", containing: "(echo)")
            _ = try await waitFor("summary", containing: "billing is the main risk")
        }

        try await step("create a folder from the sidebar") {
            try app.press("sidebar.newFolder")
            let field = try await app.wait("the folder name field") { app.all("sidebar.folderName").first }
            try await app.type("Vendors", into: field, submit: true)
            _ = try await waitFor("sidebar", containing: "Vendors")
            _ = try await app.wait("the name field to close") { app.all("sidebar.folderName").isEmpty ? true : nil }
        }

        try await step("go back to the meeting from Recents and file it into the folder") {
            try await app.wait("the meeting in Recents") { app.all("sidebar.recent").first }.perform(kAXPressAction)
            _ = try await waitFor("meeting.state", containing: "Finished")
            try app.press("organize.folder")
            let item = try await app.wait("the Vendors menu item") {
                app.all("organize.folder").first?.descendants().first { $0.role == kAXMenuItemRole && $0.title == "Vendors" }
            }
            try item.perform(kAXPressAction)
            _ = try await waitFor("organize.folder", containing: "Vendors")
        }

        try await step("Meetings lists it with its folder and tag") {
            try app.press("sidebar.all")
            _ = try await app.wait("a row with the folder and tag") {
                app.all("library.meeting").first { $0.text.contains("#acme") && $0.text.contains("Vendors") }
            }
        }

        try await step("everything was saved") {
            let db = try ScribeDatabase(url: UISession.databaseURL)
            let entries = try await db.library.entries()
            guard entries.count == 1, let entry = entries.first else { throw UIError("Expected 1 meeting, found \(entries.count)") }
            let id = entry.meeting.id
            let folder = try await db.library.folders().first { $0.id == entry.folderID }
            let notes = try await db.notes.notes(meetingID: id)
            let segments = try await db.transcripts.segments(meetingID: id)
            let summary = try await db.summaries.summary(meetingID: id)
            var problems: [String] = []
            if folder?.name != "Vendors" { problems.append("folder is \(folder?.name ?? "none")") }
            if entry.tags != ["acme"] { problems.append("tags are \(entry.tags)") }
            if notes.map(\.text) != ["billing is the main risk"] || notes.first?.flagged != true { problems.append("notes are \(notes)") }
            if segments.isEmpty || segments.contains(where: { !$0.isFinal }) { problems.append("\(segments.count) segments, some not final") }
            if summary?.flagged.contains(where: { $0.contains("billing is the main risk") }) != true { problems.append("summary is \(String(describing: summary))") }
            if entry.meeting.endedAt == nil { problems.append("meeting has no end time") }
            guard problems.isEmpty else { throw UIError(problems.joined(separator: "; ")) }
        }

        if keepOpen {
            print("Left running. Inspect with `scribe ui tree` or `scribe db \(UISession.databaseURL.path)`.")
        } else {
            UISession.quit()
        }
    }
}
