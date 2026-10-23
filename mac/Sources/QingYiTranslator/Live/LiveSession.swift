import Foundation
import QingYiCore

/// Microphone and/or system audio → mixer → `SpeechSegmenter` → one recognizer per language, on a serial queue.
/// With automatic detection a Chinese and an English recognizer both listen and `LanguageArbiter` picks the result
/// of each sentence. All callbacks arrive on the main thread. The counterpart of Platform/LiveTranscriber.cs.
final class LiveSession: @unchecked Sendable { // state is confined to `queue` or the main thread, as marked
    private static let rate = 16000

    var onPartial: ((Int, String, Double) -> Void)?
    var onFinal: ((Int, String, Double, Double, Language?) -> Void)?
    var onDiscarded: ((Int) -> Void)?
    /// Recent loudness of the microphone and the system audio, 0–1.
    var onLevels: ((Float, Float) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Another app is playing sound but the system audio stays silent: most likely the permission is missing.
    var onSystemAudioSilent: (() -> Void)?
    /// The microphone has delivered only silence since listening started.
    var onMicrophoneSilent: (() -> Void)?

    private let queue = DispatchQueue(label: "com.jingxuanwh.QingYiTranslator.live", qos: .userInitiated)
    private let segmenter = SpeechSegmenter()
    private let recognizers: [UtteranceRecognizer]
    private var sources: [LiveAudioSource] = []
    private var mixer: AudioMixer?
    private var timer: DispatchSourceTimer?
    private var cursor: Int64 = 0
    private var levels: [Float] = [0, 0]
    private var lastLevelReport: Int64 = 0
    private var systemAudioStarted: Int64?
    private var heardSystemAudio = false
    private let microphoneWatch = SilenceWatch()
    private var watchingMicrophone = false

    // Main thread: results of each utterance, gathered until every recognizer has answered.
    private var pending: [Int: Pending] = [:]
    private var preferred: Language?

    private struct Pending {
        var start: Double
        var end: Double
        var candidates: [RecognitionCandidate] = []
        var ended = false
    }

    init(recognizers: [UtteranceRecognizer]) {
        self.recognizers = recognizers
        preferred = recognizers.first?.language
        for recognizer in recognizers {
            recognizer.onPartial = { [weak self, weak recognizer] utterance, text in
                guard let self, let recognizer else { return }
                // While several languages listen, show the one that won the last sentence.
                if recognizer.language == preferred || self.recognizers.count == 1 {
                    onPartial?(utterance, LiveSession.tidy(text, recognizer.language), pending[utterance]?.start ?? 0)
                }
            }
            recognizer.onFinal = { [weak self, weak recognizer] utterance, text, confidence in
                guard let self, let recognizer else { return }
                pending[utterance]?.candidates.append(RecognitionCandidate(language: recognizer.language, text: LiveSession.tidy(text, recognizer.language),
                                                                           confidence: confidence))
                completeIfReady(utterance)
            }
        }
    }

    var languages: [Language] { recognizers.map(\.language) }

    /// Opens the devices. Throws `LiveAudioError` when one can't be opened.
    func startCapture(source: String, microphoneUID: String?) async throws {
        stopCapture()
        let useMicrophone = source == LiveSettings.sourceMicrophone || source == LiveSettings.sourceBoth
        let useSystem = source == LiveSettings.sourceSystem || source == LiveSettings.sourceBoth
        queue.sync { mixer = AudioMixer(sources: 2) }
        var opened: [LiveAudioSource] = []
        do {
            if useMicrophone {
                opened.append(try await open(MicrophoneCapture(deviceUID: microphoneUID), index: 0))
            }
            if useSystem {
                let capture: LiveAudioSource
                if #available(macOS 14.2, *) {
                    capture = ProcessTapCapture()
                } else {
                    capture = ScreenAudioCapture()
                }
                opened.append(try await open(capture, index: 1))
                queue.sync {
                    systemAudioStarted = LiveSession.now()
                    heardSystemAudio = false
                }
            }
        } catch {
            opened.forEach { $0.stop() }
            queue.sync { mixer = nil }
            throw error
        }
        sources = opened
        queue.sync {
            microphoneWatch.reset()
            watchingMicrophone = useMicrophone
        }
        startTimer()
    }

    /// Releases the devices; the sentence in progress is finished. The recognizers stay ready.
    func stopCapture() {
        sources.forEach { $0.stop() }
        sources = []
        timer?.cancel()
        timer = nil
        queue.sync {
            if mixer != nil {
                handle(segmenter.flush())
            }
            mixer = nil
            levels = [0, 0]
            systemAudioStarted = nil
            watchingMicrophone = false
        }
        DispatchQueue.main.async { [weak self] in self?.onLevels?(0, 0) }
    }

    /// Releases the devices at once; the sentence in progress still gets its final result, then the recognizers
    /// shut down. (The closure keeps the session alive until then.)
    func stop() {
        stopCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [self] in
            recognizers.forEach { $0.shutdown() }
        }
    }

    private func open(_ capture: LiveAudioSource, index: Int) async throws -> LiveAudioSource {
        capture.onSamples = { [weak self] samples in
            guard let self else { return }
            let level = min(1, SpeechSegmenter.rms(samples) * 4)
            queue.async {
                self.mixer?.push(index, samples, now: LiveSession.now())
                self.levels[index] = max(level, self.levels[index] * 0.8)
                if index == 1 && !self.heardSystemAudio && samples.contains(where: { abs($0) > 0.0001 }) {
                    self.heardSystemAudio = true
                }
            }
        }
        capture.onStopped = { [weak self] _ in
            DispatchQueue.main.async {
                self?.onFailure?(index == 0
                    ? L("麦克风已断开或停止工作。", "The microphone was disconnected or stopped working.")
                    : L("系统声音的录制停止了。", "Recording the system audio stopped."))
            }
        }
        try await capture.start()
        return capture
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // ---------------- audio queue ----------------

    private func tick() {
        guard let mixer else { return }
        let now = LiveSession.now()
        let mixed = mixer.drain(now: now)
        if !mixed.isEmpty {
            handle(segmenter.process(mixed))
        }
        if now - lastLevelReport >= 80 {
            lastLevelReport = now
            let microphone = levels[0], system = levels[1]
            levels = levels.map { $0 * 0.7 }
            DispatchQueue.main.async { [weak self] in self?.onLevels?(microphone, system) }
            if watchingMicrophone && microphoneWatch.update(level: microphone, now: Double(now) / 1000) {
                DispatchQueue.main.async { [weak self] in self?.onMicrophoneSilent?() }
            }
        }
        if let started = systemAudioStarted, now - started > 5000 {
            systemAudioStarted = nil
            if !heardSystemAudio && AudioDevices.otherAppIsPlaying() {
                DispatchQueue.main.async { [weak self] in self?.onSystemAudioSilent?() }
            }
        }
    }

    private func handle(_ events: [SegmentEvent]) {
        for event in events {
            switch event {
            case let .started(utterance, sample):
                cursor = sample
                let start = Double(sample) / Double(LiveSession.rate)
                DispatchQueue.main.async { [weak self] in
                    self?.pending[utterance] = Pending(start: start, end: start)
                }
                recognizers.forEach { $0.begin(utterance, at: sample) }
            case let .audio(_, samples):
                recognizers.forEach { $0.append(samples, at: cursor) }
                cursor += Int64(samples.count)
            case let .ended(utterance, sample):
                let end = Double(sample) / Double(LiveSession.rate)
                DispatchQueue.main.async { [weak self] in
                    self?.pending[utterance]?.end = end
                    self?.pending[utterance]?.ended = true
                    self?.completeIfReady(utterance)
                }
                recognizers.forEach { $0.end(utterance, at: cursor) }
            case let .discarded(utterance, _):
                recognizers.forEach { $0.cancel(utterance) }
                DispatchQueue.main.async { [weak self] in
                    self?.pending[utterance] = nil
                    self?.onDiscarded?(utterance)
                }
            }
        }
    }

    // ---------------- main thread ----------------

    private func completeIfReady(_ utterance: Int) {
        guard let entry = pending[utterance], entry.ended, entry.candidates.count >= recognizers.count else { return }
        pending[utterance] = nil
        let picked = LanguageArbiter.pick(entry.candidates, previous: preferred)
        if let picked {
            preferred = picked.language
        }
        onFinal?(utterance, picked?.text ?? "", entry.start, entry.end, picked?.language)
    }

    private static func now() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    private static func tidy(_ text: String, _ language: Language) -> String {
        language.isChinese ? SpeechText.useChinesePunctuation(text) : text
    }
}
