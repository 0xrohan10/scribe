import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let dir = ScreenshotMode.directory {
            let model = ScreenshotMode.makeModel()
            _model = State(initialValue: model)
            Task { await ScreenshotMode.run(model: model, to: dir) }
            return
        }
        if let dir = UITestingMode.directory {
            _model = State(initialValue: UITestingMode.makeModel(in: dir))
            return
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
        }
    }
}

/// The one main window: sidebar plus library, meeting or settings. AppKit-managed so it can be opened from a
/// notification action, where SwiftUI's `openWindow` isn't reachable.
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show(app: AppModel) {
        let window = window ?? makeWindow(app: app)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(app: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Scribe"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: MainView(app: app))
        window.contentMinSize = NSSize(width: 980, height: 600)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }
}
