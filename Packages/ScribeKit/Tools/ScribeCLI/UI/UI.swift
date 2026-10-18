import AppKit
import ArgumentParser
import Foundation

struct UI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "Drive the real app UI through the Accessibility API, against fake audio, transcription and LLM.",
        discussion: """
            `launch` starts a Debug Scribe.app with --ui-testing, so recording needs no permissions or network and its \
            database lives in \(UISession.dir.path)/scribe.sqlite (see `scribe db`). The other commands act on that \
            instance. Queries match an accessibility identifier (notes.add), a title (Start Recording) or a label.

            The terminal needs Accessibility access; `screenshot` also needs Screen Recording.

              scribe ui launch && scribe ui menu "Start Recording" && scribe ui wait meeting.state --contains Recording
              scribe ui type notes.draft "! billing is the main risk" && scribe ui press notes.add
              scribe ui tree meeting
            """,
        subcommands: [UIDemo.self, Launch.self, Quit.self, Tree.self, Read.self, Wait.self, Press.self, TypeText.self, MenuItem.self, Screenshot.self])
}

enum UISession {
    static let dir = URL.temporaryDirectory.appending(path: "scribe-ui", directoryHint: .isDirectory)
    static let databaseURL = dir.appending(path: "scribe.sqlite")
    private static let pidFile = dir.appending(path: "app.pid")
    /// This file is in <repo>/Packages/ScribeKit/Tools/ScribeCLI/UI/.
    static let defaultAppPath = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "build/DerivedData/Build/Products/Debug/Scribe.app").path

    /// The instance started by `launch`.
    static func app() throws -> TestedApp {
        try requireAccessibility()
        guard let pid = runningPID() else { throw ValidationError("No Scribe under test. Run `scribe ui launch` first.") }
        return TestedApp(pid: pid)
    }

    /// Quits any previous instance, wipes its data and starts a fresh one.
    static func launch(appPath: String) async throws -> TestedApp {
        try requireAccessibility()
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw ValidationError("No app at \(appPath). Build the Debug app first (see README).")
        }
        quit()
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--ui-testing", dir.path]
        config.createsNewApplicationInstance = true
        config.activates = false
        let running = try await NSWorkspace.shared.openApplication(at: URL(filePath: appPath), configuration: config)
        let pid = running.processIdentifier
        try String(pid).write(to: pidFile, atomically: true, encoding: .utf8)
        let app = TestedApp(pid: pid)
        _ = try await app.wait("Scribe's menu bar item", timeout: 15) { app.statusItem }
        return app
    }

    static func quit() {
        guard let pid = runningPID() else { return }
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func runningPID() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text),
            NSRunningApplication(processIdentifier: pid) != nil
        else { return nil }
        return pid
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a fresh Scribe under test, quitting any previous one.")

    @Option(help: "The Debug app bundle.")
    var app = UISession.defaultAppPath

    func run() async throws {
        let tested = try await UISession.launch(appPath: app)
        print("Scribe under test: pid \(tested.pid), data in \(UISession.dir.path)")
    }
}

struct Quit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit the Scribe under test.")

    func run() async throws { UISession.quit() }
}

struct Tree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the accessibility tree: every window and the menu bar item, or one element.")

    @Argument(help: "Only this element's subtree.")
    var query: String?

    @Option(help: "Levels to print.")
    var depth = 30

    func run() async throws {
        let app = try UISession.app()
        let roots = try query.map { [try app.find($0)] } ?? app.windows + [app.statusItem].compactMap { $0 }
        func show(_ element: Element, level: Int) {
            print(String(repeating: "  ", count: level) + element.summary)
            if level < depth { element.children.forEach { show($0, level: level + 1) } }
        }
        roots.forEach { show($0, level: 0) }
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the text of every element that matches, one per line.")

    @Argument var query: String

    func run() async throws {
        let matches = try UISession.app().all(query)
        guard !matches.isEmpty else { throw UIError("Nothing matches “\(query)”") }
        matches.forEach { print($0.text) }
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait until an element appears (or disappears), optionally with some text.")

    @Argument var query: String

    @Option(help: "Some match's text contains this.")
    var contains: String?

    @Option(help: "At least this many matches.")
    var count = 1

    @Flag(help: "Wait for no matches instead.")
    var gone = false

    @Option var timeout = 10.0

    func run() async throws {
        let app = try UISession.app()
        let (query, contains, count, gone) = (query, contains, count, gone)
        let found = try await app.wait("“\(query)”\(contains.map { " containing “\($0)”" } ?? "")", timeout: timeout) { () -> [Element]? in
            let matches = app.all(query).filter { e in contains.map { e.text.contains($0) } ?? true }
            return gone ? (matches.isEmpty ? [] : nil) : (matches.count >= count ? matches : nil)
        }
        found.forEach { print($0.text) }
    }
}

struct Press: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Press a button, menu button, link or row.")

    @Argument var query: String

    func run() async throws { try UISession.app().press(query) }
}

struct TypeText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Focus a field and type into it with key events.")

    @Argument var query: String
    @Argument var text: String

    @Flag(help: "Press Return afterwards.")
    var submit = false

    func run() async throws {
        let app = try UISession.app()
        try await app.type(text, into: try app.find(query), submit: submit)
    }
}

struct MenuItem: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "menu", abstract: "Open the menu bar item and choose an item, e.g. “Open Scribe”.")

    @Argument var title: String

    func run() async throws { try await UISession.app().menu(title) }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a PNG of one of the app's windows (needs Screen Recording access).")

    @Argument var file: String

    @Option(help: "Window title. Default: the frontmost window.")
    var window: String?

    func run() async throws {
        let pid = try UISession.app().pid
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let match = window.map { title in windows.first { ($0[kCGWindowName as String] as? String) == title } } ?? windows.first
        guard let id = match?[kCGWindowNumber as String] as? Int else { throw UIError("No on-screen window\(window.map { " titled “\($0)”" } ?? "")") }
        let capture = try Process.run(URL(filePath: "/usr/sbin/screencapture"), arguments: ["-x", "-o", "-l", String(id), file])
        capture.waitUntilExit()
        guard capture.terminationStatus == 0 else { throw UIError("screencapture failed (\(capture.terminationStatus))") }
        print(file)
    }
}
