import GoogleCalendar
import SwiftUI

struct CalendarSettingsSection: View {
    @Bindable var model: CalendarModel
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var disconnecting: CalendarModel.Connection?

    var body: some View {
        Section("Google Calendar") {
            Text("Connect Google accounts and choose which calendars appear in Upcoming. Scribe can read events but cannot change them.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if model.connections.isEmpty {
                Group {
                    TextField("Desktop client ID", text: $clientID)
                        .accessibilityIdentifier("calendars.clientID")
                    SecureField("Client secret (if provided)", text: $clientSecret)
                    Text("Create a Desktop app OAuth client with the Google Calendar API enabled. See docs/guide.md for setup.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("Save configuration") {
                        do { try model.saveConfiguration(clientID: clientID, clientSecret: clientSecret) }
                        catch { model.lastError = error.localizedDescription }
                    }
                    .disabled(model.isBusy || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(model.isBusy)
            }
            ForEach(model.connections) { connection in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(connection.account.email).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Disconnect…", role: .destructive) { disconnecting = connection }
                            .disabled(model.isBusy)
                    }
                    ForEach(connection.calendars) { calendar in
                        Toggle(calendar.summary, isOn: Binding(
                            get: { model.connections.first { $0.id == connection.id }?.selectedIDs.contains(calendar.id) == true },
                            set: { enabled in
                                model.select(calendar.id, accountID: connection.id, enabled: enabled)
                                Task { await model.refresh() }
                            }))
                            .disabled(model.isBusy)
                    }
                    if let error = model.accountErrors[connection.id] {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.recording)
                        Text("Use Add Google account to sign in again.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Add Google account", systemImage: "plus") { model.connect() }
                    .disabled(model.clientID.isEmpty || model.isBusy)
                    .accessibilityIdentifier("calendars.connect")
                if model.isBusy { ProgressView().controlSize(.small) }
                if model.isConnecting {
                    Text("Complete sign-in in your browser.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Button("Cancel") { model.cancelConnection() }
                } else if !model.connections.isEmpty {
                    Spacer()
                    Button("Refresh calendars") { Task { await model.refresh() } }.disabled(model.isBusy)
                }
            }
            if let error = model.lastError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.recording)
            }
        }
        .onAppear { clientID = model.clientID; clientSecret = model.clientSecret }
        .task { await model.refresh() }
        .alert("Disconnect Google account?", isPresented: Binding(
            get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
            Button("Disconnect", role: .destructive) {
                if let connection = disconnecting { model.disconnect(connection.id) }
                disconnecting = nil
            }
            Button("Cancel", role: .cancel) { disconnecting = nil }
        } message: {
            Text("Scribe will remove this account's local credentials and events. Saved recordings and notes stay unchanged. You can also remove Scribe's access in your Google account settings.")
        }
    }
}

struct UpcomingView: View {
    let app: AppModel
    let model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upcoming").font(Theme.serif(30))
                    Text("Your next seven days. Start a recording with the meeting title.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isBusy || model.connections.isEmpty)
                    .accessibilityIdentifier("calendars.refresh")
            }
            .padding(.bottom, 24)

            if model.connections.isEmpty {
                empty("Connect Google Calendar", detail: "Add one or more Google accounts in Settings, then choose your calendars.")
            } else {
                if !model.accountErrors.isEmpty {
                    HStack {
                        Label("Some calendars could not refresh.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Review accounts") { app.showSettings() }
                    }
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.bottom, 16)
                }
                if model.events.isEmpty && !model.isBusy {
                    if model.accountErrors.isEmpty {
                        empty("No upcoming meetings", detail: "There are no timed events in your selected calendars. All-day and declined events are not shown.")
                    } else {
                        empty("Calendar access needs attention", detail: "Open calendar settings to check your accounts, then try refreshing again.")
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.events) { event in
                                eventRow(event)
                                Rectangle().fill(Theme.border).frame(height: 1)
                            }
                        }
                        .accessibilityIdentifier("calendars.events")
                    }
                }
            }
            if let date = model.lastRefresh, !model.connections.isEmpty {
                Text("Last checked \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(.top, 12)
            }
        }
        .padding(40)
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 17, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Button("Calendar settings") { app.showSettings() }.buttonStyle(QuietButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func eventRow(_ event: GoogleCalendarEvent) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
            }
            .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Text("\(model.calendarName(for: event)) · \(model.accountEmail(for: event))")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Start recording", systemImage: "record.circle") { app.startMeeting(title: event.title) }
                .buttonStyle(QuietButtonStyle())
                .accessibilityLabel("Start recording \(event.title)")
        }
        .padding(.vertical, 18)
    }
}
