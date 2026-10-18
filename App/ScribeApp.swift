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
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

        Window("Library", id: "library") {
            LibraryWindow(library: model.library, app: model)
        }
        .defaultSize(width: 980, height: 620)

        Settings {
            SettingsView(model: model)
        }
    }
}

private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.isRecording ? "record.circle.fill" : "waveform")
            .onAppear { model.openSettings = { NSApp.activate(); openSettings() } }
    }
}

/// The meeting window is AppKit-managed so it can be opened from a notification action, where SwiftUI's
/// `openWindow` isn't reachable.
@MainActor
final class MeetingWindowController {
    private var window: NSWindow?
    private var meetingID: UUID?

    func close(ifShowing meetingID: UUID) {
        if self.meetingID == meetingID { window?.close() }
    }

    func show(_ vm: MeetingViewModel, app: AppModel) {
        let window = window ?? makeWindow()
        self.window = window
        meetingID = vm.id
        window.title = vm.meeting.title
        window.contentViewController = NSHostingController(rootView: MeetingWindow(vm: vm, app: app))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("MeetingWindow")
        return window
    }
}
