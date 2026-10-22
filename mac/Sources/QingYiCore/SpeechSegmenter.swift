import Foundation

public enum SegmentEvent: Equatable {
    /// Speech began; `sample` is where the utterance starts, pre-roll included.
    case started(utterance: Int, sample: Int64)
    /// More audio of the current utterance.
    case audio(utterance: Int, samples: [Float])
    /// The utterance is over; `sample` is just after its last voiced frame.
    case ended(utterance: Int, sample: Int64)
    /// The "utterance" was only a click or a cough; whatever was recognized from it should be dropped.
    case discarded(utterance: Int, sample: Int64)
}

/// Cuts a continuous mono stream into utterances by loudness: speech starts after a few loud frames (with a short
/// pre-roll so the first syllable isn't clipped) and ends after a pause. The noise floor adapts, so a fan or a quiet
/// room doesn't count as speech. After a long stretch without a pause a shorter one is enough, and nothing grows past
/// `maxUtteranceMilliseconds`, so a lecture is still split into sentences.
/// The same algorithm as Core/SpeechSegmenter.cs of the Windows version.
public final class SpeechSegmenter {
    public static let frameMilliseconds = 20

    /// About -44 dBFS: quieter frames are never speech, however quiet the room is.
    public static let minSpeechLevel: Float = 0.006

    private static let speechOverNoise: Float = 3.2   // about +10 dB above the noise floor
    private static let releaseRatio: Float = 0.6      // speech goes on until the level drops well below the start level
    private static let startFrames = 3                // 60 ms of loud audio starts an utterance
    private static let preRollMilliseconds = 300
    private static let tailMilliseconds = 200         // kept after the last voiced frame in the reported end time
    private static let minSpeechMilliseconds = 200
    private static let noiseBlockFrames = 10          // the noise floor is the quietest 200 ms block…
    private static let noiseBlocks = 8                // …of the last 1.6 s

    public let sampleRate: Int

    /// Pause that ends an utterance.
    public var endSilenceMilliseconds = 650

    /// Utterances longer than this already end at a `shortPauseMilliseconds` pause.
    public var softMaxMilliseconds = 12_000

    public var shortPauseMilliseconds = 300

    public var maxUtteranceMilliseconds = 28_000

    private let frameSize: Int
    private var frame: [Float]
    private var frameFill = 0
    private var preRoll: [Float]
    private var preRollStart = 0
    private var preRollCount = 0
    private var blockMinimums = [Float](repeating: 0, count: SpeechSegmenter.noiseBlocks)
    private var blockCount = 0
    private var blockFrames = 0
    private var blockMinimum = Float.greatestFiniteMagnitude
    public private(set) var noiseFloor = SpeechSegmenter.minSpeechLevel / SpeechSegmenter.speechOverNoise
    private var position: Int64 = 0
    private var candidateFrames = 0
    private var lastId = 0
    private var utterance = 0               // 0 while idle
    private var utteranceLength: Int64 = 0
    private var lastVoiceEnd: Int64 = 0
    private var voicedFrames = 0
    private var silentFrames = 0

    public init(sampleRate: Int = 16000) {
        self.sampleRate = sampleRate
        frameSize = sampleRate * SpeechSegmenter.frameMilliseconds / 1000
        frame = [Float](repeating: 0, count: frameSize)
        preRoll = [Float](repeating: 0, count: sampleRate * SpeechSegmenter.preRollMilliseconds / 1000)
    }

    public var isSpeaking: Bool { utterance != 0 }

    /// Samples consumed so far; the time base of all events.
    public var currentPosition: Int64 { position + Int64(frameFill) }

    public func process(_ samples: [Float]) -> [SegmentEvent] {
        var events: [SegmentEvent] = []
        var audio: [Float] = []
        var index = 0
        while index < samples.count {
            let take = min(samples.count - index, frameSize - frameFill)
            for i in 0..<take {
                frame[frameFill + i] = samples[index + i]
            }
            frameFill += take
            index += take
            if frameFill == frameSize {
                frameFill = 0
                processFrame(&events, &audio)
            }
        }
        flushAudio(&events, &audio)
        return events
    }

    /// Ends the current utterance, e.g. when capture stops or pauses.
    public func flush() -> [SegmentEvent] {
        var events: [SegmentEvent] = []
        if utterance != 0 {
            var audio = Array(frame[0..<frameFill])
            utteranceLength += Int64(frameFill)
            end(&events, &audio)
        }
        position += Int64(frameFill)
        frameFill = 0
        preRollCount = 0
        candidateFrames = 0
        return events
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            sum += Double(sample) * Double(sample)
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    private func processFrame(_ events: inout [SegmentEvent], _ audio: inout [Float]) {
        let level = SpeechSegmenter.rms(frame)
        let threshold = max(SpeechSegmenter.minSpeechLevel, noiseFloor * SpeechSegmenter.speechOverNoise)
        position += Int64(frameSize)
        trackNoiseFloor(level)

        if utterance == 0 {
            pushPreRoll()
            candidateFrames = level >= threshold ? candidateFrames + 1 : 0
            if candidateFrames < SpeechSegmenter.startFrames {
                return
            }
            lastId += 1
            utterance = lastId
            let pre = takePreRoll()
            events.append(.started(utterance: utterance, sample: position - Int64(pre.count)))
            audio = pre
            utteranceLength = Int64(pre.count)
            voicedFrames = candidateFrames
            silentFrames = 0
            lastVoiceEnd = position
            candidateFrames = 0
            return
        }

        audio.append(contentsOf: frame)
        utteranceLength += Int64(frameSize)
        if level >= threshold * SpeechSegmenter.releaseRatio {
            voicedFrames += 1
            silentFrames = 0
            lastVoiceEnd = position
        } else {
            silentFrames += 1
        }

        let lengthMs = utteranceLength * 1000 / Int64(sampleRate)
        let pauseNeeded = lengthMs >= Int64(softMaxMilliseconds) ? shortPauseMilliseconds : endSilenceMilliseconds
        if silentFrames * SpeechSegmenter.frameMilliseconds >= pauseNeeded || lengthMs >= Int64(maxUtteranceMilliseconds) {
            end(&events, &audio)
        }
    }

    private func end(_ events: inout [SegmentEvent], _ audio: inout [Float]) {
        flushAudio(&events, &audio)
        let tooShort = voicedFrames * SpeechSegmenter.frameMilliseconds < SpeechSegmenter.minSpeechMilliseconds
        let endSample = min(currentPosition, lastVoiceEnd + Int64(sampleRate * SpeechSegmenter.tailMilliseconds / 1000))
        events.append(tooShort ? .discarded(utterance: utterance, sample: endSample) : .ended(utterance: utterance, sample: endSample))
        utterance = 0
        utteranceLength = 0
        voicedFrames = 0
        silentFrames = 0
    }

    private func flushAudio(_ events: inout [SegmentEvent], _ audio: inout [Float]) {
        if !audio.isEmpty && utterance != 0 {
            events.append(.audio(utterance: utterance, samples: audio))
        }
        audio = []
    }

    // "Minimum statistics": even continuous speech has quiet moments between syllables, so the quietest stretch of the
    // last couple of seconds is the background. A steady fan or hum thus stops counting as speech after about 2 s.
    private func trackNoiseFloor(_ level: Float) {
        blockMinimum = min(blockMinimum, level)
        blockFrames += 1
        if blockFrames < SpeechSegmenter.noiseBlockFrames {
            return
        }
        blockMinimums[blockCount % SpeechSegmenter.noiseBlocks] = blockMinimum
        blockCount += 1
        blockFrames = 0
        blockMinimum = .greatestFiniteMagnitude

        let quietest = blockMinimums[0..<min(blockCount, SpeechSegmenter.noiseBlocks)].min() ?? level
        let floor = quietest < noiseFloor ? quietest : noiseFloor + (quietest - noiseFloor) * 0.5
        noiseFloor = max(0.0002, floor)
    }

    private func pushPreRoll() {
        for sample in frame {
            preRoll[(preRollStart + preRollCount) % preRoll.count] = sample
            if preRollCount < preRoll.count {
                preRollCount += 1
            } else {
                preRollStart = (preRollStart + 1) % preRoll.count
            }
        }
    }

    private func takePreRoll() -> [Float] {
        var result = [Float](repeating: 0, count: preRollCount)
        for i in 0..<preRollCount {
            result[i] = preRoll[(preRollStart + i) % preRoll.count]
        }
        preRollStart = 0
        preRollCount = 0
        return result
    }
}
