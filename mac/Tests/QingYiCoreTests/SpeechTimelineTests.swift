import Foundation
import Testing
@testable import QingYiCore

struct SpeechTimelineTests {
    @Test func int16KeepsEverySampleAndClips() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 1.7, -3, .nan]
        let converted = AudioSamples.int16(samples)
        #expect(converted.count == samples.count)
        #expect(converted == [0, 16384, -16384, 32767, -32767, 32767, -32767, 0])
        #expect(AudioSamples.int16([Float](repeating: 0.1, count: 4800)).count == 4800)
    }

    @Test func timelineTrimsOverlaps() {
        var timeline = AudioTimeline()
        var placed = timeline.place(start: 100, count: 50)
        #expect(placed.drop == 0 && placed.start == 100)
        placed = timeline.place(start: 150, count: 10) // follows directly
        #expect(placed.drop == 0 && placed.start == 150)
        placed = timeline.place(start: 200, count: 10) // a gap is fine
        #expect(placed.drop == 0 && placed.start == 200)
        placed = timeline.place(start: 205, count: 10) // overlaps by 5
        #expect(placed.drop == 5 && placed.start == 210)
        placed = timeline.place(start: 190, count: 10) // entirely before: dropped
        #expect(placed.drop == 10)
        #expect(timeline.end == 220)
    }

    /// Feeds speech with pauses through the segmenter the way the recognizers get it and checks that the buffer start
    /// times never go back.
    @Test func segmentedAudioNeverOverlaps() {
        let rate = 16000
        func tone(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * Double(rate))).map { i in
                let syllable = i % (rate * 240 / 1000) < rate * 200 / 1000
                return Float(syllable ? 0.3 : 0.02) * sin(Float(i) * 2 * .pi * 220 / Float(rate))
            }
        }
        let signal = [Float](repeating: 0, count: rate / 2) + tone(1.2) + [Float](repeating: 0, count: rate * 7 / 10)
            + tone(0.8) + [Float](repeating: 0, count: rate * 7 / 10) + tone(13) + [Float](repeating: 0, count: rate * 35 / 100)
            + tone(1) + [Float](repeating: 0, count: rate)
        let segmenter = SpeechSegmenter()
        var cursor = UtteranceCursor()
        var timeline = AudioTimeline()
        var pieces: [(start: Int64, count: Int)] = []
        var utterances = 0
        for chunk in stride(from: 0, to: signal.count, by: 640) {
            for event in segmenter.process(Array(signal[chunk..<min(chunk + 640, signal.count)])) {
                switch event {
                case let .started(_, sample):
                    cursor.started(at: sample)
                    utterances += 1
                case let .audio(_, samples):
                    pieces.append((cursor.audio(samples.count), samples.count))
                case .ended, .discarded:
                    break
                }
            }
        }
        #expect(utterances >= 3)
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            #expect(next.start >= previous.start + Int64(previous.count))
        }
        for piece in pieces {
            #expect(timeline.place(start: piece.start, count: piece.count).drop == 0)
        }
    }
}
