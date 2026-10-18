import AppKit
import SwiftUI

@main
struct ScribeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

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

    func show(_ vm: MeetingViewModel, app: AppModel) {
        let window = window ?? makeWindow()
        self.window = window
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
