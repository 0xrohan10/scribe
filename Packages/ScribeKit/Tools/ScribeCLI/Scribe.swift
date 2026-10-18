import ArgumentParser
import Foundation

@main
struct Scribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Dev debugging for Scribe. No microphone, system audio or network unless a command says so.",
        subcommands: [Demo.self, DB.self, Gate.self, UI.self])

    static func main() async {
        // Line-buffer stdout so events show up as they happen when piped (e.g. through `tee`).
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var command = try parseAsRoot()
            if var command = command as? AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}

/// The app's database, as opened by `AppModel`.
let appDatabaseURL = URL.applicationSupportDirectory.appending(path: "Scribe/scribe.sqlite")
