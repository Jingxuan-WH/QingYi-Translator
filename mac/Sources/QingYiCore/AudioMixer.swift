import Foundation

/// Mixes the 16 kHz mono streams of the microphone and the system audio into one. Each device delivers on its own
/// clock and in its own chunk sizes, so samples wait until every active source has caught up. A source that stops
/// delivering counts as silence after `stallMilliseconds`, and when every source is quiet the mixer emits silence
/// itself, so a pause after the last sentence still ends it. Same logic as Core/AudioMixer.cs on Windows.
public final class AudioMixer {
    public static let stallMilliseconds: Int64 = 250

    private var queues: [[Float]]
    private var lastPush: [Int64?]
    private let sampleRate: Int
    private let maxBuffered: Int
    private var lastOutput: Int64?

    public init(sources: Int, sampleRate: Int = 16000) {
        queues = Array(repeating: [], count: sources)
        lastPush = Array(repeating: nil, count: sources)
        self.sampleRate = sampleRate
        maxBuffered = sampleRate // one second ahead of the slowest source is plenty
    }

    public func push(_ source: Int, _ samples: [Float], now: Int64) {
        guard !samples.isEmpty else { return }
        queues[source].append(contentsOf: samples)
        lastPush[source] = now
        if queues[source].count > maxBuffered {
            queues[source].removeFirst(queues[source].count - maxBuffered)
        }
    }

    /// Returns whatever can be mixed now; may be empty.
    public func drain(now: Int64) -> [Float] {
        if lastOutput == nil {
            lastOutput = now
        }
        let active = queues.indices.filter { isActive($0, now: now) }
        var mixed: [Float]
        if !active.isEmpty {
            let count = active.map { queues[$0].count }.min() ?? 0
            if count == 0 {
                return []
            }
            mixed = [Float](repeating: 0, count: count)
            for index in queues.indices {
                take(index, into: &mixed, count: min(count, queues[index].count))
            }
        } else {
            // Nothing is coming in: flush what is left and fill the time since the last output with silence.
            let buffered = queues.map(\.count).max() ?? 0
            let elapsed = Int((now - (lastOutput ?? now)) * Int64(sampleRate) / 1000)
            let length = min(max(buffered, elapsed), sampleRate * 2)
            if length <= 0 || (buffered == 0 && now - (lastOutput ?? now) < AudioMixer.stallMilliseconds) {
                return []
            }
            mixed = [Float](repeating: 0, count: length)
            for index in queues.indices {
                take(index, into: &mixed, count: min(length, queues[index].count))
            }
        }
        for i in mixed.indices {
            mixed[i] = min(1, max(-1, mixed[i]))
        }
        lastOutput = now
        return mixed
    }

    private func isActive(_ source: Int, now: Int64) -> Bool {
        guard let last = lastPush[source] else { return false }
        return now - last <= AudioMixer.stallMilliseconds
    }

    private func take(_ source: Int, into mixed: inout [Float], count: Int) {
        guard count > 0 else { return }
        queues[source].withUnsafeBufferPointer { buffer in
            for i in 0..<count {
                mixed[i] += buffer[i]
            }
        }
        queues[source].removeFirst(count)
    }
}
