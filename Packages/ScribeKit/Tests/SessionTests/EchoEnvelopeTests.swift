import Core
import Foundation
import Testing

@testable import Session

/// Synthetic room audio adapted from Hex's meeting_echo.rs tests (MIT).
enum EchoFixture {
    static let rate = 16_000

    static func speech(_ seconds: Double, seed: UInt32) -> [Float] {
        var state = max(1, seed &* 2_654_435_761)
        let syllable = 0.11 + Double(seed % 7) * 0.013
        return (0..<Int(seconds * Double(rate))).map { index in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            let noise = Float(state) / Float(UInt32.max) * 2 - 1
            let time = Double(index) / Double(rate)
            let phase = (time / syllable).truncatingRemainder(dividingBy: 1)
            let word = (UInt32(time / (syllable * Double(3 + seed % 3))) + seed) % 4
            let envelope = word == 0 ? 0.02 : sin(phase * .pi)
            return noise * 0.2 * Float(envelope)
        }
    }

    static func noise(_ count: Int) -> [Float] {
        var state: UInt32 = 3 &* 747_796_405
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return (Float(state) / Float(UInt32.max) * 2 - 1) * 0.001
        }
    }

    static func bleed(_ system: [Float], delay: Int = 60, gain: Float = 0.08) -> [Float] {
        let offset = delay * rate / 1_000
        var microphone = noise(system.count)
        for index in 0..<max(0, system.count - offset) { microphone[index + offset] += system[index] * gain }
        return microphone
    }

    static func envelope(system: [Float], microphone: [Float], offset: TimeInterval = 0) -> EchoEnvelope {
        var envelope = EchoEnvelope()
        for (source, samples) in [(AudioChunk.Source.system, system), (.mic, microphone)] {
            var position = 0, packet = 0
            let sizes = [1024, 333, 2048, 160]
            while position < samples.count {
                let end = min(samples.count, position + sizes[packet % sizes.count])
                envelope.append(AudioChunk(
                    source: source, pcm: Array(samples[position..<end]), sampleRate: Double(rate),
                    timestamp: offset + Double(position) / Double(rate)))
                position = end
                packet += 1
            }
        }
        return envelope
    }
}

@Suite struct EchoEnvelopeTests {
    @Test func detectsDelayedSpeakerBleedAcrossUnevenPackets() {
        let system = EchoFixture.speech(12, seed: 11)
        var envelope = EchoFixture.envelope(system: system, microphone: EchoFixture.bleed(system))
        #expect(envelope.assess(start: 2, end: 5) == .bleed)
        #expect(envelope.assess(start: 6, end: 9.5) == .bleed)
    }

    @Test func keepsLocalSpeechOverTheOtherSide() {
        let system = EchoFixture.speech(12, seed: 11)
        var microphone = EchoFixture.bleed(system)
        for (index, sample) in EchoFixture.speech(3, seed: 29).enumerated() {
            microphone[5 * EchoFixture.rate + index] += sample * 0.9
        }
        var envelope = EchoFixture.envelope(system: system, microphone: microphone)
        #expect(envelope.assess(start: 5, end: 8) == .local)
        #expect(envelope.assess(start: 1, end: 4.5) == .bleed)
    }

    @Test func keepsAShortLocalPhraseInsideALongRemoteTurn() {
        let system = EchoFixture.speech(16, seed: 11)
        var microphone = EchoFixture.bleed(system)
        for (index, sample) in EchoFixture.speech(1.2, seed: 29).enumerated() {
            microphone[8 * EchoFixture.rate + index] += sample * 0.9
        }
        var envelope = EchoFixture.envelope(system: system, microphone: microphone)
        #expect(envelope.assess(start: 1, end: 15) != .bleed)
        #expect(envelope.assess(start: 1, end: 7.5) == .bleed)
    }

    @Test func handlesMuffledEchoWithALongDelay() {
        let system = EchoFixture.speech(14, seed: 11)
        var low: Float = 0
        var room = system.map { sample in
            low += 0.15 * (sample - low)
            return low
        }
        let reflection = EchoFixture.rate * 35 / 1_000
        for index in reflection..<room.count { room[index] += room[index - reflection] * 0.55 }
        var envelope = EchoFixture.envelope(system: system, microphone: EchoFixture.bleed(room, delay: 450, gain: 0.25))
        #expect(envelope.assess(start: 2, end: 5) == .bleed)
    }

    @Test func headphonesKeepLocalSpeechAndLeaveSilenceUndecided() {
        let system = EchoFixture.speech(12, seed: 11)
        var microphone = EchoFixture.noise(system.count)
        for (index, sample) in EchoFixture.speech(3, seed: 17).enumerated() {
            microphone[4 * EchoFixture.rate + index] += sample * 0.4
        }
        var envelope = EchoFixture.envelope(system: system, microphone: microphone)
        #expect(envelope.assess(start: 4, end: 7) == .local)
        #expect(envelope.assess(start: 9, end: 11) == nil)
    }

    @Test func usesSessionTimestampsRatherThanPacketArrivalOrder() {
        let system = EchoFixture.speech(12, seed: 11)
        var envelope = EchoFixture.envelope(system: system, microphone: EchoFixture.bleed(system), offset: 3)
        #expect(envelope.assess(start: 5, end: 8) == .bleed)
        #expect(abs(envelope.covered(.mic) - 15) < 0.001)
        #expect(envelope.assess(start: 20, end: 21) == nil)
    }

    @Test func gapsAreNotStitchedTogether() {
        let speech = EchoFixture.speech(3, seed: 11)
        let microphone = EchoFixture.bleed(speech)
        var envelope = EchoFixture.envelope(system: speech, microphone: microphone)
        for (source, samples) in [(AudioChunk.Source.system, speech), (.mic, microphone)] {
            envelope.append(AudioChunk(source: source, pcm: samples, sampleRate: 16_000, timestamp: 10))
        }
        #expect(envelope.assess(start: 5, end: 8) == nil)
        #expect(envelope.assess(start: 10.5, end: 12.5) == .bleed)
        #expect(envelope.covered(.system) == 13)
    }
}
