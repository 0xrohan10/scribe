import Detection
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        if let current = model.current, current.isRecording {
            Text("Recording: \(current.meeting.title)")
            Button("Show Meeting") { model.showCurrentMeeting() }
            Button("Stop Recording") { Task { await current.stop() } }
                .keyboardShortcut("s")
        } else {
            if let detected = model.detectedMeeting {
                Button("Record \(detected.app.displayName) Meeting") { model.startMeeting(from: detected) }
            }
            Button("Start Recording") { model.startMeeting() }
                .keyboardShortcut("r")
            if let current = model.current {
                Button("Show Last Meeting") { model.openPast(current.meeting) }
            }
        }

        if let error = model.lastError {
            Divider()
            Text(error)
            Button("Dismiss") { model.lastError = nil }
        }

        Divider()
        Menu("Recent Meetings") {
            if model.recentMeetings.isEmpty { Text("None yet") }
            ForEach(model.recentMeetings) { meeting in
                Button(meeting.title) { model.openPast(meeting) }
            }
        }
        if !Accessibility.isTrusted {
            Button("Enable Teams & Meet Detection…") { Accessibility.requestTrust() }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Scribe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
