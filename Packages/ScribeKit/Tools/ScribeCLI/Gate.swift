import ArgumentParser
import Core
import Foundation
import Intelligence
import Settings

struct Gate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Score questions with the TypeSafe Jev search gate (calls the API).",
        discussion: """
            Prints P(needs web) per question and whether it meets the threshold. Questions come from the arguments, \
            or one per line on stdin. The transcript is a built-in vendor call unless --meeting selects a saved one.

            The API key is $TYPESAFE_API_KEY, else the app's Keychain entry (macOS may ask to allow access).
            """)

    @Argument(help: "Questions. Default: read lines from stdin.")
    var questions: [String] = []

    @Option(help: "Searches at or above this probability.")
    var threshold = 0.35

    @Option(help: "Use this saved meeting's transcript (id or prefix).")
    var meeting: String?

    @Option(help: "Database for --meeting. Default: the app's database.")
    var db: String?

    func run() async throws {
        let descriptorKey = ProviderDescriptor(id: "jev", displayName: "TypeSafe Jev").secretKey
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? KeychainSecretStore().secret(for: descriptorKey) else {
            throw ValidationError("Set TYPESAFE_API_KEY or add a Jev key in Scribe's Settings.")
        }
        let transcript: Transcript
        if let meeting {
            let database = try openExisting(db)
            let id = try await findMeeting(meeting, in: database).id
            transcript = Transcript(segments: try await database.transcripts.segments(meetingID: id))
        } else {
            transcript = vendorCall
        }
        var questions = questions
        if questions.isEmpty {
            while let line = readLine() {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { questions.append(line) }
            }
        }

        let gate = JevSearchGate(config: ProviderConfig(apiKey: key), threshold: threshold)
        print("threshold \(threshold), \(transcript.segments.count) transcript segments")
        for question in questions {
            do {
                let p = try await gate.probability(question: question, transcript: transcript)
                print(String(format: "%.3f  %@  %@", p, p >= threshold ? "search" : "skip  ", question))
            } catch {
                print("error  \(question): \(error.localizedDescription)")
            }
        }
    }
}

private let vendorCall = Transcript(
    segments: [
        (Speaker.them, 4.0, "Thanks for making time. We'll walk through the migration plan and then pricing."),
        (.me, 12, "Great. Our main concern is moving existing subscriptions without double-charging anyone."),
        (.them, 21, "We run a dry-run import first, so you can diff every invoice before anything goes live."),
        (.me, 34, "How long did that take for customers our size?"),
        (.them, 41, "About two weeks end to end, mostly waiting on finance sign-off."),
        (.them, 58, "On pricing, usage-based plans are billed on volume, and there's a platform fee on top."),
        (.me, 71, "We'd need that in writing, and the budget for a second contractor isn't approved yet."),
        (.them, 83, "Understood. I'll send a quote and our standard DPA by Friday."),
    ].map { TranscriptSegment(speaker: $0.0, text: $0.2, start: $0.1, end: $0.1 + 6, isFinal: true) })
