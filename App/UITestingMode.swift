#if DEBUG
import Core
import Fixtures
import Foundation
import Persistence
import Settings

/// `Scribe --ui-testing <dir>` runs the real UI against fake audio, the fake transcriber and the echo LLM, with its
/// database in `<dir>/scribe.sqlite` and settings that reset on every launch. `scribe ui` drives it.
@MainActor
enum UITestingMode {
    static let directory: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-testing"), i + 1 < args.count else { return nil }
        return URL(filePath: args[i + 1], directoryHint: .isDirectory)
    }()

    static func makeModel(in dir: URL) -> AppModel {
        UserDefaults(suiteName: "scribe.preview")!.removePersistentDomain(forName: "scribe.preview")
        var settings = AppSettings()
        settings.transcriptionProviderID = "fake"
        settings.promptWhenMeetingDetected = false
        let database: ScribeDatabase
        do {
            database = try ScribeDatabase(url: dir.appending(path: "scribe.sqlite"))
        } catch {
            fatalError("UI testing: couldn't open the database in \(dir.path): \(error)")
        }
        return AppModel(
            uiTesting: settings, secrets: NoSecrets(), database: database,
            sources: { _ in [SilentSource(.system), SilentSource(.mic, from: 2)] }, llm: EchoLLM())
    }
}

private struct NoSecrets: SecretStore {
    func secret(for key: String) -> String? { nil }
    func setSecret(_ value: String?, for key: String) throws {}
}
#endif
