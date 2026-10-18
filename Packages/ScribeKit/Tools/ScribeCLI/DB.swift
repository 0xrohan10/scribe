import ArgumentParser
import Core
import Foundation
import Persistence

struct DB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db", abstract: "List the meetings in a database, or dump one meeting in full.")

    @Argument(help: "SQLite file. Default: the app's database.")
    var path: String?

    @Option(help: "Meeting id (or a prefix of it) to dump in full.")
    var meeting: String?

    func run() async throws {
        let db = try openExisting(path)
        if let meeting {
            try await dumpMeeting(try await findMeeting(meeting, in: db), in: db)
        } else {
            try await listLibrary(db)
        }
    }
}

/// Opens a database file without creating one by accident.
func openExisting(_ path: String?) throws -> ScribeDatabase {
    let url = path.map { URL(filePath: $0) } ?? appDatabaseURL
    guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError("No database at \(url.path)") }
    return try ScribeDatabase(url: url)
}

func findMeeting(_ idPrefix: String, in db: ScribeDatabase) async throws -> Meeting {
    let matches = try await db.library.entries().map(\.meeting).filter { $0.id.uuidString.lowercased().hasPrefix(idPrefix.lowercased()) }
    guard matches.count == 1 else {
        throw ValidationError(matches.isEmpty ? "No meeting with id \(idPrefix)" : "\(matches.count) meetings match \(idPrefix)")
    }
    return matches[0]
}

func listLibrary(_ db: ScribeDatabase) async throws {
    let folders = try await db.library.folders()
    let entries = try await db.library.entries()
    let folderNames = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
    print("Folders: \(folders.isEmpty ? "none" : folders.map(\.name).joined(separator: ", "))")
    print("\(entries.count) meetings")
    for entry in entries {
        let m = entry.meeting
        let place = entry.folderID.flatMap { folderNames[$0] }.map { "📁 \($0)" } ?? "unfiled"
        let tags = entry.tags.map { "#\($0)" }.joined(separator: " ")
        print("  \(m.id.uuidString.prefix(8))  \(m.startedAt.formatted(date: .numeric, time: .shortened))  \(duration(m))  \(m.title)  [\(place)] \(tags)")
    }
}

func dumpMeeting(_ meeting: Meeting, in db: ScribeDatabase) async throws {
    let entry = try await db.library.entries().first { $0.id == meeting.id }
    let folder = try await db.library.folders().first { $0.id == entry?.folderID }
    print("""
        \(meeting.title)
          id        \(meeting.id.uuidString)
          app       \(meeting.app?.displayName ?? "-")
          started   \(meeting.startedAt.formatted(date: .numeric, time: .standard))
          ended     \(meeting.endedAt?.formatted(date: .numeric, time: .standard) ?? "-") (\(duration(meeting)))
          template  \(meeting.templateID)
          folder    \(folder?.name ?? "-")
          tags      \(entry?.tags.joined(separator: ", ") ?? "-")
          mic       \(meeting.micAudioPath ?? "-")
          system    \(meeting.systemAudioPath ?? "-")
        """)

    let segments = try await db.transcripts.segments(meetingID: meeting.id)
    print("\nTranscript (\(segments.count) segments)")
    for s in segments {
        print("  \(s.start.clockString)–\(s.end.clockString)  \(s.speaker == .me ? "Me  " : "Them")  \(s.isFinal ? " " : "~")\(s.text)")
    }

    let notes = try await db.notes.notes(meetingID: meeting.id)
    print("\nNotes (\(notes.count))")
    for n in notes { print("  \(n.timestamp.clockString)  \(n.flagged ? "★" : " ") \(n.text)") }

    print("\nSummary")
    if let summary = try await db.summaries.summary(meetingID: meeting.id) {
        printSummary(summary)
    } else {
        print("  none")
    }
}

func printSummary(_ s: MeetingSummary) {
    print("  overview   \(s.overview)")
    for (label, items) in [("decision", s.decisions), ("question", s.openQuestions), ("flagged", s.flagged)] {
        for item in items { print("  \(label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(item)") }
    }
    for a in s.actionItems {
        print("  action     \(a.task)\(a.owner.map { " — \($0)" } ?? "")\(a.due.map { ", due \($0)" } ?? "")")
    }
}

private func duration(_ m: Meeting) -> String {
    m.endedAt.map { $0.timeIntervalSince(m.startedAt).clockString } ?? "live"
}
