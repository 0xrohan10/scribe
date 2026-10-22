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
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.transcript.isEmpty {
                        Text(vm.isRecording ? "Listening…" : "No transcript.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 60)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                    ForEach(vm.transcript.segments) { segment in
                        SegmentRow(segment: segment, isAnchored: highlighted.contains(segment.id)).id(segment.id).transition(.rise)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .motion(Motion.quick, value: vm.transcript.segments.map(\.id))
                .motion(value: highlighted)
            }
            .accessibilityIdentifier("transcript")
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
                // Animated here rather than on the scroll view, so jumping back to live stays instant.
                ZStack {
                    if !followLive, vm.isRecording {
                        Button("Follow live", systemImage: "arrow.down") {
                            followLive = true
                            vm.focusedNote = nil
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .padding(12)
                        .transition(.rise)
                    }
                }
                .motion(Motion.quick, value: !followLive && vm.isRecording)
            }
        }
    }
}

/// The user's speech appears in bubbles on the right. Other speech appears as plain text.
private struct SegmentRow: View {
    let segment: TranscriptSegment
    var isAnchored = false

    private var isMe: Bool { segment.speaker == .me }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            Text("\(isMe ? "Me" : "Them") · \(segment.start.clockString)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            Text(segment.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(segment.isFinal ? Theme.text : Theme.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, isMe ? 14 : 0)
                .padding(.vertical, isMe ? 9 : 0)
                .background(isMe ? Theme.bubble : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: isMe ? 520 : .infinity, alignment: isMe ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .padding(isAnchored ? 8 : 0)
        .background(isAnchored ? Theme.highlight.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .motion(Motion.quick, value: segment.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(segment.isFinal ? "transcript.segment" : "transcript.partial")
    }
}
