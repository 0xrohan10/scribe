import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @State private var model: AppModel

    init() {
        // As an LSUIElement app with an Icon Composer icon, AppKit falls back to the generic app icon for alerts;
        // IconServices renders the real one, as Finder and the Dock do.
        NSApplication.shared.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
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
            if model.isRecording {
                Image(systemName: "record.circle.fill")
            } else {
                Image("ScribeMark").accessibilityLabel("Scribe")
            }
        }
    }
}

/// AppKit manages the main window so notification actions can open it without SwiftUI's `openWindow`.
///
/// While this window is open, Scribe shows a Dock icon and appears in ⌘-Tab.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(app: AppModel) {
        let window = window ?? makeWindow(app: app)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow(app: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
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
