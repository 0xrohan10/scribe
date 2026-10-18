import Core
import Intelligence
import Session
import SwiftUI

struct MeetingWindow: View {
    @Bindable var vm: MeetingViewModel
    let app: AppModel
    @State private var showSummary = true

    var body: some View {
        VStack(spacing: 0) {
            header
            OrganizeBar(meetingID: vm.id, library: app.library)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if !vm.warnings.isEmpty { warnings }
            Divider()
            HSplitView {
                leftPane.frame(minWidth: 380, idealWidth: 560)
                NotesPane(vm: vm).frame(minWidth: 280, idealWidth: 320)
                AskPane(vm: vm).frame(minWidth: 280, idealWidth: 340)
            }
        }
        .frame(minWidth: 1000, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Title", text: Binding(get: { vm.meeting.title }, set: { vm.rename($0) }))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
            StateBadge(state: vm.state)
            if vm.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(vm.clock.now.clockString).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Picker("Template", selection: Binding(get: { vm.meeting.templateID }, set: { vm.setTemplate($0) })) {
                ForEach(SummaryTemplates.all) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            if vm.isRecording {
                Button("Stop", systemImage: "stop.fill") { Task { await vm.stop() } }
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
            } else if vm.state == .finished {
                Button(vm.summary == nil ? "Summarize" : "Regenerate", systemImage: "sparkles") { Task { await vm.regenerateSummary() } }
                    .disabled(vm.isRegenerating || vm.transcript.isEmpty)
                Button("Delete", systemImage: "trash", role: .destructive) { app.deleteMeeting(vm.meeting) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .disabled(vm.isRegenerating)
                    .help("Delete this meeting and its recordings")
            }
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(vm.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
        .overlay(alignment: .topTrailing) {
            Button("Dismiss", systemImage: "xmark") { vm.warnings.removeAll() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
        }
    }

    @ViewBuilder
    private var leftPane: some View {
        if vm.summary != nil || vm.state == .summarizing || vm.isRegenerating {
            VStack(spacing: 0) {
                Picker("", selection: $showSummary) {
                    Text("Summary").tag(true)
                    Text("Transcript").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                if showSummary {
                    SummaryView(summary: vm.summary, isLoading: vm.state == .summarizing || vm.isRegenerating)
                } else {
                    TranscriptView(vm: vm)
                }
            }
        } else {
            TranscriptView(vm: vm)
        }
    }
}

private struct StateBadge: View {
    let state: SessionState

    var body: some View {
        let (text, color): (String, Color) =
            switch state {
            case .idle: ("Ready", .secondary)
            case .starting: ("Starting…", .orange)
            case .recording: ("● Recording", .red)
            case .stopping: ("Stopping…", .orange)
            case .summarizing: ("Summarizing…", .purple)
            case .finished: ("Finished", .green)
            case .failed: ("Failed", .red)
            }
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
