import Core
import Foundation
import Testing
import os

@testable import Detection

private final class FakeMic: MicActivitySignal, Sendable {
    let (stream, continuation) = AsyncStream<Bool>.makeStream()
    func changes() -> AsyncStream<Bool> { stream }
}

private final class FakeProbe: MeetingProbe, Sendable {
    let result = OSAllocatedUnfairLock<DetectedMeeting?>(initialState: nil)
    func probe() async -> DetectedMeeting? { result.withLock { $0 } }
}

@Suite struct DetectorTests {
    @Test func startsWhenMicLiveAndProbeMatches_endsAfterMisses() async throws {
        let mic = FakeMic(), probe = FakeProbe()
        let detector = MicTriggeredMeetingDetector(mic: mic, probes: [probe], pollInterval: .milliseconds(10), missesToEnd: 2)
        var events = detector.events.makeAsyncIterator()
        await detector.start()

        probe.result.withLock { $0 = DetectedMeeting(app: .zoom, pid: 42, bundleID: "us.zoom.xos") }
        mic.continuation.yield(true)
        #expect(await events.next() == .started(app: .zoom, pid: 42))

        probe.result.withLock { $0 = nil }
        #expect(await events.next() == .ended)
        await detector.stop()
    }

    @Test func micIdleEndsImmediately() async throws {
        let mic = FakeMic(), probe = FakeProbe()
        let detector = MicTriggeredMeetingDetector(mic: mic, probes: [probe], pollInterval: .seconds(60))
        var events = detector.events.makeAsyncIterator()
        await detector.start()

        probe.result.withLock { $0 = DetectedMeeting(app: .meet, pid: 7, bundleID: "com.google.Chrome") }
        mic.continuation.yield(true)
        #expect(await events.next() == .started(app: .meet, pid: 7))
        mic.continuation.yield(false)
        #expect(await events.next() == .ended)
        await detector.stop()
    }

    @Test func titleMatchers() {
        let teams = WindowTitleProbe.teams.matches, meet = WindowTitleProbe.meet.matches
        #expect(teams("Meeting with Ana | Microsoft Teams"))
        #expect(teams("Call with Sam | Microsoft Teams"))
        #expect(!teams("Calendar | Microsoft Teams"))
        #expect(!teams("Chat | Microsoft Teams"))
        #expect(meet("Meet - abc-defg-hij"))
        #expect(meet("Meet – Weekly sync"))
        #expect(!meet("Google Meet"))
    }
}
