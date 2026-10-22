import Core
import Intelligence
import Session
import SwiftUI

/// Shows a meeting's header, transcript or summary, note input, and side panel for notes and questions.
struct MeetingView: View {
    @Bindable var vm: MeetingViewModel
    let app: AppModel
    @State private var showSummary = true
    @State private var showPanel = true
    @State private var newTodo: TodoItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.isCapturing, !vm.transcriptionStatuses.isEmpty {
                HStack(spacing: 18) {
                    ForEach(AudioChunk.Source.allCases, id: \.self) { source in
                        if let status = vm.transcriptionStatuses[source] {
                            TranscriptionSourceStatus(source: source, status: status) {
                                Task { await vm.retryTranscription(source) }
                            }
                            .disabled(!vm.isRecording)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
            if !vm.warnings.isEmpty {
                warnings.transition(.move(edge: .top).combined(with: .opacity))
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                centerColumn
                if showPanel {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    SidePanel(vm: vm)
                        .frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .motion(value: showPanel)
        .motion(Motion.quick, value: vm.warnings)
        .sheet(item: $newTodo) { TodoEditor(item: $0, model: app.todos) }
    }

    private var hasSummary: Bool { vm.summary != nil || vm.state == .summarizing || vm.isRegenerating }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: Binding(get: { vm.meeting.title }, set: { vm.rename($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityIdentifier("meeting.title")
                HStack(spacing: 10) {
                    StateBadge(state: vm.state).accessibilityIdentifier("meeting.state")
                    if vm.isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(vm.clock.now.clockString).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    } else {
                        Text(vm.meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    Menu {
                        Picker("Template", selection: Binding(get: { vm.meeting.templateID }, set: { vm.setTemplate($0) })) {
                            ForEach(SummaryTemplates.all) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(SummaryTemplates.all.first { $0.id == vm.meeting.templateID }?.name ?? "General", systemImage: "doc.text")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 12))
                    .tint(Theme.secondary)
                    .accessibilityIdentifier("meeting.template")
                    Rectangle().fill(Theme.border).frame(width: 1, height: 12)
                    OrganizeBar(meetingID: vm.id, library: app.library)
                }
            }
            Spacer(minLength: 16)
            actions
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if vm.isRecording {
                Button("Stop", systemImage: "stop.fill") { Task { await vm.stop() } }
                    .buttonStyle(CapsuleButtonStyle(fill: Theme.recording))
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("meeting.stop")
                    .transition(.rise)
            } else if vm.state == .finished || isFailed {
                Button(vm.summary == nil ? "Summarize" : "Regenerate", systemImage: "sparkles") {
                    Task { await vm.regenerateSummary(); await app.todos.reload() }
                }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(vm.isRegenerating || vm.transcript.isEmpty)
                    .accessibilityIdentifier("meeting.summarize")
                    .transition(.rise)
                Button("Delete", systemImage: "trash") { app.deleteMeeting(vm.meeting) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(QuietButtonStyle())
                    .disabled(vm.isRegenerating)
                    .help("Delete this meeting and its recordings")
                    .accessibilityIdentifier("meeting.delete")
            }
            if vm.state == .recording || vm.state == .finished {
                Button("Add a todo from this meeting", systemImage: "plus.circle") {
                    app.todos.lastError = nil
                    newTodo = TodoItem(title: "", owner: "Me", meetingID: vm.meeting.id, meetingTitle: vm.meeting.title)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
                .help("Add a todo linked to this meeting")
                .accessibilityIdentifier("meeting.addTodo")
            }
            Button(showPanel ? "Hide Notes and Questions" : "Show Notes and Questions", systemImage: "sidebar.right") { showPanel.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
                .help(showPanel ? "Hide notes and questions" : "Show notes and questions")
                .accessibilityIdentifier("meeting.panel")
        }
        .motion(Motion.quick, value: vm.state)
    }

    private var isFailed: Bool {
        if case .failed = vm.state { return true }
        return false
    }

    private var warnings: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.flag)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(vm.warnings.enumerated()), id: \.offset) { _, warning in Text(warning) }
            }
            .font(.system(size: 12))
            Spacer()
            Button("Dismiss", systemImage: "xmark") { vm.warnings.removeAll() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Theme.flag.opacity(0.1))
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            if hasSummary {
                PillTabs(selection: $showSummary, options: [(true, "Summary"), (false, "Transcript")])
                    .accessibilityIdentifier("meeting.pane")
                    .padding(.top, 14)
                    .transition(.rise)
            }
            ZStack {
                if hasSummary && showSummary {
                    SummaryView(
                        summary: vm.summary, isLoading: vm.state == .summarizing || vm.isRegenerating,
                        fix: vm.canCorrect ? { term in Task { await vm.fix(term) } } : nil,
                        dismiss: { term in Task { await vm.dismiss(term) } }
                    )
                    .transition(.rise)
                } else {
                    TranscriptView(vm: vm).transition(.rise)
                }
            }
            .frame(maxHeight: .infinity)
            // The transcript scrolls under the composer and fades out behind it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if vm.isLive {
                    NoteComposer(vm: vm)
                        .frame(maxWidth: 720)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 18)
                        .background(LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .motion(value: [hasSummary, showSummary])
    }
}

private struct TranscriptionSourceStatus: View {
    let source: AudioChunk.Source
    let status: TranscriptionStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source == .mic ? "mic" : "speaker.wave.2")
            Text("\(source == .mic ? "Microphone" : "System audio"): \(title)")
                .accessibilityIdentifier("transcription.status.\(source.rawValue)")
            if case .failed = status {
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("transcription.retry.\(source.rawValue)")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(color)
        .help(detail)
    }

    private var title: String {
        switch status {
        case .waitingForAudio: "Waiting for audio"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .retrying(let attempt, _): "Retrying (\(attempt))…"
        case .failed: "Transcription failed"
        case .unavailable: "Unavailable"
        case .stopped: "Stopped"
        }
    }

    private var detail: String {
        switch status {
        case .retrying(_, let reason), .failed(let reason), .unavailable(let reason): reason
        default: title
        }
    }

    private var color: Color {
        switch status {
        case .transcribing: Theme.highlight
        case .retrying: Theme.flag
        case .failed, .unavailable: Theme.recording
        default: Theme.secondary
        }
    }
}

/// Two or three options in a capsule, the selection sliding between them.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selection == value {
                                Capsule().fill(Theme.surface).shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(3)
        .background(Theme.bubble, in: Capsule())
        .motion(Motion.quick, value: selection)
        .accessibilityElement(children: .contain)
    }
}

private struct StateBadge: View {
    let state: SessionState

    var body: some View {
        let (text, color): (String, Color) =
            switch state {
            case .idle: ("Ready", Theme.secondary)
            case .starting: ("Starting…", Theme.secondary)
            case .recording: ("Recording", Theme.recording)
            case .stopping: ("Stopping…", Theme.secondary)
            case .summarizing: ("Summarizing…", Theme.highlight)
            case .finished: ("Finished", Theme.secondary)
            case .failed: ("Failed", Theme.recording)
            }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).contentTransition(.opacity)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
        .motion(Motion.quick, value: state)
    }
}
