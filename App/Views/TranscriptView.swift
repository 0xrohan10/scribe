import Core
import Notes
import SwiftUI

struct TranscriptView: View {
    let vm: MeetingViewModel
    @State private var followLive = true

    /// What was said around the focused note.
    private var anchored: Set<UUID> {
        guard let note = vm.focusedNote else { return [] }
        return Set(NoteAnchoring.context(for: note, in: vm.transcript).map(\.id))
    }

    var body: some View {
        let highlighted = anchored
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if vm.transcript.isEmpty {
                        Text(vm.isRecording ? "Listening…" : "No transcript.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(vm.transcript.segments) { segment in
                        SegmentRow(segment: segment, isAnchored: highlighted.contains(segment.id)).id(segment.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: vm.transcript.segments.last?.text) {
                if followLive, vm.isRecording { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.focusedNote) { _, note in
                guard let note else { return }
                followLive = false
                let target = NoteAnchoring.context(for: note, in: vm.transcript).first
                    ?? vm.transcript.segments.last { $0.start <= note.timestamp } ?? vm.transcript.segments.first
                if let target { withAnimation { proxy.scrollTo(target.id, anchor: .center) } }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followLive, vm.isRecording {
                    Button("Follow live", systemImage: "arrow.down") {
                        followLive = true
                        vm.focusedNote = nil
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    var isAnchored = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.start.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            Text(segment.speaker == .me ? "Me" : "Them")
                .font(.caption.weight(.semibold))
                .foregroundStyle(segment.speaker == .me ? Color.accentColor : .orange)
                .frame(width: 38, alignment: .leading)
            Text(segment.text)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, isAnchored ? 4 : 0)
        .background(isAnchored ? Color.yellow.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
