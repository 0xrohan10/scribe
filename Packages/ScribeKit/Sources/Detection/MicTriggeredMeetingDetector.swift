import Core
import Foundation

/// When the mic goes live, polls the probes until one recognises a meeting and emits `.started`.
/// Emits `.ended` when the mic goes idle or the meeting disappears for `missesToEnd` polls in a row.
/// The second rule matters because Scribe's own recording keeps the mic "running somewhere".
public actor MicTriggeredMeetingDetector: MeetingDetector {
    private let mic: any MicActivitySignal
    private let probes: [any MeetingProbe]
    private let pollInterval: Duration
    private let missesToEnd: Int
    private let broadcaster = Broadcaster<MeetingEvent>()

    private var micActive = false
    private var current: DetectedMeeting?
    private var misses = 0
    private var task: Task<Void, Never>?

    public init(
        mic: any MicActivitySignal = MicActivityMonitor(),
        probes: [any MeetingProbe] = [ZoomProbe(), WindowTitleProbe.teams, WindowTitleProbe.meet],
        pollInterval: Duration = .seconds(2),
        missesToEnd: Int = 3
    ) {
        self.mic = mic
        self.probes = probes
        self.pollInterval = pollInterval
        self.missesToEnd = missesToEnd
    }

    public nonisolated var events: AsyncStream<MeetingEvent> { broadcaster.subscribe() }

    /// The meeting currently detected, if any.
    public var currentMeeting: DetectedMeeting? { current }

    public func start() {
        guard task == nil else { return }
        task = Task { [mic, pollInterval] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await active in mic.changes() { await self.micChanged(active) }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollInterval)
                        await self.poll()
                    }
                }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func micChanged(_ active: Bool) async {
        micActive = active
        if active {
            await poll()
        } else if current != nil {
            end()
        }
    }

    private func poll() async {
        guard micActive || current != nil else { return }
        var found: DetectedMeeting?
        for probe in probes {
            if let match = await probe.probe() {
                found = match
                break
            }
        }
        switch (current, found) {
        case (nil, let meeting?) where micActive:
            current = meeting
            misses = 0
            broadcaster.send(.started(app: meeting.app, pid: meeting.pid))
        case (.some, nil):
            misses += 1
            if misses >= missesToEnd { end() }
        case (.some, .some):
            misses = 0
        default:
            break
        }
    }

    private func end() {
        current = nil
        misses = 0
        broadcaster.send(.ended)
    }
}
