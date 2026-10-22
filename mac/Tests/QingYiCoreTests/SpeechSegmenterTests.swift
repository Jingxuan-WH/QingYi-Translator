import Testing
import Foundation
@testable import QingYiCore

/// Test signals at 16 kHz.
enum Signals {
    static let rate = 16000

    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

    /// Speech-like bursts: 200 ms of a loud tone, then 40 ms of near silence, repeated.
    static func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let gap = i % (rate * 240 / 1000) >= rate * 200 / 1000
            return (gap ? amplitude * 0.07 : amplitude) * sin(2 * Float.pi * 220 * Float(i) / Float(rate))
        }
    }

    static func noise(_ seconds: Double, rms: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed
        let scale = rms * 3.0.squareRoot().float // uniform noise in [-a, a] has an RMS of a/√3
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)
            return (unit * 2 - 1) * scale
        }
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] { a.indices.map { a[$0] + ($0 < b.count ? b[$0] : 0) } }
}

private extension Double {
    var float: Float { Float(self) }
}

struct SpeechSegmenterTests {
    private func run(_ samples: [Float], _ segmenter: SpeechSegmenter = SpeechSegmenter(), chunk: Int = 480) -> [SegmentEvent] {
        var events: [SegmentEvent] = []
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            events += segmenter.process(Array(samples[index..<end]))
            index = end
        }
        return events
    }

    private func started(_ events: [SegmentEvent]) -> [(Int, Int64)] {
        events.compactMap { if case let .started(u, s) = $0 { return (u, s) } else { return nil } }
    }

    private func ended(_ events: [SegmentEvent]) -> [(Int, Int64)] {
        events.compactMap { if case let .ended(u, s) = $0 { return (u, s) } else { return nil } }
    }

    private func audioLength(_ events: [SegmentEvent], utterance: Int? = nil) -> Int {
        events.reduce(0) { total, event in
            if case let .audio(u, samples) = event, utterance == nil || u == utterance { return total + samples.count }
            return total
        }
    }

    private func discardedCount(_ events: [SegmentEvent]) -> Int {
        events.filter { if case .discarded = $0 { return true } else { return false } }.count
    }

    @Test func silenceAndQuietNoiseProduceNothing() {
        #expect(run(Signals.silence(3)).isEmpty)
        #expect(run(Signals.noise(3, rms: 0.002)).isEmpty)
    }

    @Test func oneUtteranceWithPreRollAndTail() throws {
        let rate = Int64(Signals.rate)
        let events = run(Signals.silence(0.5) + Signals.speech(1.5) + Signals.silence(1.5))
        let start = try #require(started(events).first)
        let end = try #require(ended(events).first)
        #expect(started(events).count == 1 && ended(events).count == 1)
        #expect(start.0 == end.0)
        #expect((rate * 15 / 100...rate / 2).contains(start.1))           // pre-roll before the first loud frame
        #expect((rate * 195 / 100...rate * 225 / 100).contains(end.1))    // last voiced frame + ~200 ms
        let reach = start.1 + Int64(audioLength(events))
        #expect((rate * 26 / 10...rate * 27 / 10).contains(reach))         // audio runs until the pause is long enough
        #expect(discardedCount(events) == 0)
        if case .started = events.first {} else { Issue.record("first event should be .started") }
        if case .ended = events.last {} else { Issue.record("last event should be .ended") }
    }

    @Test func shortClickIsDiscarded() {
        let events = run(Signals.silence(0.5) + Signals.speech(0.1) + Signals.silence(1.5))
        #expect(started(events).count == 1)
        #expect(discardedCount(events) == 1)
        #expect(ended(events).isEmpty)
    }

    @Test func twoSentencesWithAPause() {
        let events = run(Signals.silence(0.3) + Signals.speech(1.2) + Signals.silence(1) + Signals.speech(0.8) + Signals.silence(1))
        #expect(ended(events).map(\.0) == [1, 2])
    }

    @Test func shortPauseOnlySplitsAfterSoftMax() throws {
        let shortPause = Signals.speech(5) + Signals.silence(0.36) + Signals.speech(2) + Signals.silence(1.5)
        #expect(ended(run(shortPause)).count == 1)

        let afterSoftMax = Signals.speech(13) + Signals.silence(0.36) + Signals.speech(2) + Signals.silence(1.5)
        let splits = ended(run(afterSoftMax))
        #expect(splits.count == 2)
        let first = try #require(splits.first)
        #expect((Int64(13 * Signals.rate)...Int64(13.4 * Double(Signals.rate))).contains(first.1))
    }

    @Test func longSpeechIsCutAtTheMaximum() throws {
        let events = run(Signals.speech(40))
        let first = try #require(ended(events).first)
        let length = audioLength(events, utterance: first.0)
        #expect((Int(27.9 * Double(Signals.rate))...Int(28.1 * Double(Signals.rate))).contains(length))
        #expect(started(events).contains { $0.0 == 2 })
    }

    @Test func steadyNoiseStopsCountingAsSpeech() {
        let segmenter = SpeechSegmenter()
        let events = run(Signals.noise(8, rms: 0.02), segmenter)
        #expect(!segmenter.isSpeaking)
        #expect(!started(events).contains { $0.1 > Int64(3 * Signals.rate) })
        #expect((0.012...0.03).contains(Double(segmenter.noiseFloor)))

        // Speech over the same noise is still found.
        let later = run(Signals.add(Signals.speech(1.5), Signals.noise(1.5, rms: 0.02, seed: 2)) + Signals.noise(1.5, rms: 0.02, seed: 3), segmenter)
        #expect(!ended(later).isEmpty)
    }

    @Test func flushEndsTheCurrentUtterance() {
        let segmenter = SpeechSegmenter()
        _ = run(Signals.silence(0.2) + Signals.speech(1), segmenter)
        #expect(segmenter.isSpeaking)
        let events = segmenter.flush()
        if case .ended = events.last {} else { Issue.record("flush should end the utterance") }
        #expect(!segmenter.isSpeaking)
        #expect(segmenter.flush().isEmpty)
    }

    @Test func chunkSizeDoesNotMatter() {
        let signal = Signals.silence(0.4) + Signals.speech(1.3) + Signals.silence(1) + Signals.speech(0.7) + Signals.silence(1)
        func describe(_ events: [SegmentEvent]) -> [String] {
            events.compactMap {
                switch $0 {
                case .audio: return nil
                case let .started(u, s): return "started\(u)@\(s)"
                case let .ended(u, s): return "ended\(u)@\(s)"
                case let .discarded(u, s): return "discarded\(u)@\(s)"
                }
            }
        }
        #expect(describe(run(signal, chunk: 100)) == describe(run(signal, chunk: 4096)))
    }
}

struct AudioMixerTests {
    private func fill(_ count: Int, _ value: Float) -> [Float] { [Float](repeating: value, count: count) }

    @Test func singleSourcePassesThrough() {
        let mixer = AudioMixer(sources: 1)
        mixer.push(0, fill(160, 0.25), now: 0)
        #expect(mixer.drain(now: 0) == fill(160, 0.25))
        #expect(mixer.drain(now: 10).isEmpty)
    }

    @Test func waitsForTheSlowerSourceAndSums() {
        let mixer = AudioMixer(sources: 2)
        mixer.push(0, fill(320, 0.25), now: 0)
        mixer.push(1, fill(160, 0.5), now: 0)
        #expect(mixer.drain(now: 0) == fill(160, 0.75))
        mixer.push(1, fill(160, 0.9), now: 10)
        #expect(mixer.drain(now: 10) == fill(160, 1)) // 0.25 + 0.9, clipped
    }

    @Test func aSourceThatNeverDeliveredDoesNotBlock() {
        let mixer = AudioMixer(sources: 2)
        mixer.push(0, fill(160, 0.1), now: 0)
        #expect(mixer.drain(now: 0).count == 160)
    }

    @Test func stalledSourceCountsAsSilence() {
        let mixer = AudioMixer(sources: 2)
        mixer.push(1, fill(160, 0.5), now: 0)
        var total = 0
        for t in stride(from: Int64(0), through: 600, by: 10) {
            mixer.push(0, fill(160, 0.1), now: t)
            total += mixer.drain(now: t).count
        }
        #expect(total == 61 * 160)
    }

    @Test func fillsSilenceWhenEverythingIsQuiet() {
        let mixer = AudioMixer(sources: 1)
        mixer.push(0, fill(160, 0.1), now: 0)
        #expect(mixer.drain(now: 0).count == 160)
        #expect(mixer.drain(now: 100).isEmpty)
        let silence = mixer.drain(now: 600)
        #expect(silence.count == 600 * 16)
        #expect(silence.allSatisfy { $0 == 0 })
        #expect(mixer.drain(now: 700).isEmpty) // silence comes in chunks of at least the stall time
        #expect(mixer.drain(now: 900).count == 300 * 16)
    }

    @Test func buffersAtMostOneSecondAhead() {
        let mixer = AudioMixer(sources: 2)
        var mixed = 0
        for t in stride(from: Int64(0), to: 3000, by: 10) {
            mixer.push(0, fill(160, 0.1), now: t)
            mixer.push(1, fill(1, 0.1), now: t) // a source that delivers far too little
            mixed += mixer.drain(now: t).count
        }
        #expect(mixed == 300)
        #expect((15_900...16_000).contains(mixer.drain(now: 3300).count)) // both stalled: flushes what was kept
    }
}
