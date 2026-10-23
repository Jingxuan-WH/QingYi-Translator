import Foundation

/// Converts the 16 kHz float samples of the audio pipeline for a speech recognizer.
public enum AudioSamples {
    /// One 16-bit sample per input sample, so a buffer covers exactly the frames it was given; values beyond ±1 are clipped.
    public static func int16(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            sample.isNaN ? 0 : Int16((max(-1, min(1, sample)) * 32767).rounded())
        }
    }
}

/// Where the audio of each utterance lies on the 16 kHz timeline as the recognizers receive it: an utterance starts at
/// the sample its `.started` event names, and its audio follows without gaps (the pre-roll first).
public struct UtteranceCursor: Sendable {
    public private(set) var position: Int64 = 0

    public init() {}

    public mutating func started(at sample: Int64) {
        position = sample
    }

    /// Where `count` samples of utterance audio start; moves past them.
    public mutating func audio(_ count: Int) -> Int64 {
        let start = position
        position += Int64(count)
        return start
    }
}

/// Keeps the buffers handed to SpeechAnalyzer in order: it stops working ("Audio input timestamp overlaps or precedes
/// prior audio input") if a buffer starts before the previous one ended. A buffer that would overlap loses its
/// overlapping start, or is dropped when nothing is left.
public struct AudioTimeline: Sendable {
    /// The end of the last buffer placed, in frames.
    public private(set) var end: Int64?

    public init() {}

    /// - Returns: How many leading frames to drop (all of them when the buffer lies entirely before `end`), and where the
    ///   rest starts.
    public mutating func place(start: Int64, count: Int) -> (drop: Int, start: Int64) {
        let earliest = end ?? start
        let drop = Int(max(0, min(Int64(count), earliest - start)))
        end = max(earliest, start + Int64(count))
        return (drop, start + Int64(drop))
    }
}
