import AVFoundation
import CoreMedia
import QingYiCore
import Speech

/// Recognizes one language, utterance by utterance as `SpeechSegmenter` cuts them. The begin / append / end calls
/// come from the audio pipeline's queue; the callbacks arrive on the main thread.
protocol UtteranceRecognizer: AnyObject {
    var language: Language { get }
    var onPartial: ((Int, String) -> Void)? { get set }
    /// Exactly once per utterance that was ended; the text may be empty. The confidence is 0–1 when known.
    var onFinal: ((Int, String, Double?) -> Void)? { get set }
    /// - Parameter sample: Position in the 16 kHz stream (the time base of `SpeechSegmenter`).
    func begin(_ utterance: Int, at sample: Int64)
    func append(_ samples: [Float], at sample: Int64)
    func end(_ utterance: Int, at sample: Int64)
    /// The utterance was only noise; no final result is needed.
    func cancel(_ utterance: Int)
    func shutdown()
}

enum SpeechSetupError: Error {
    case permissionDenied
    /// macOS 13–25: the language's offline model isn't installed (it comes with Dictation).
    case notOnDevice([Language])
    /// macOS 26: the language's model is supported but not downloaded yet.
    case needsDownload([Language])
    case unsupported([Language])
    /// macOS 26: the app couldn't reserve the language's model; the detail comes from macOS.
    case cannotReserve([Language], String)
    /// macOS 26: a download finished, but macOS doesn't report the model as installed.
    case downloadIncomplete([Language], SpeechModelStatus)
}

/// Picks the recognizer: SpeechAnalyzer / SpeechTranscriber on macOS 26 and later, SFSpeechRecognizer
/// (always on-device) before that.
enum SpeechEngine {
    static var usesAnalyzer: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        #endif
        return false
    }

    static var displayName: String { usesAnalyzer ? "SpeechAnalyzer" : "SFSpeechRecognizer" }

    /// Creates a recognizer per language. Throws `SpeechSetupError` when something has to be done first;
    /// with several languages, the ones that can't run are left out as long as one can.
    static func makeRecognizers(for languages: [Language]) async throws -> [UtteranceRecognizer] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
            Log.info("语音识别：SpeechAnalyzer，语言 \(codes(languages))")
            var recognizers: [UtteranceRecognizer] = []
            var missing: [Language] = []
            var failure: Error?
            for language in languages {
                do {
                    recognizers.append(try await AnalyzerSpeechRecognizer.make(language: language, keeping: languages))
                } catch SpeechSetupError.needsDownload(let languages) {
                    missing += languages
                } catch {
                    Log.error("无法创建 SpeechAnalyzer（\(language.code)）", error)
                    failure = failure ?? error
                }
            }
            if !missing.isEmpty {
                recognizers.forEach { $0.shutdown() }
                throw SpeechSetupError.needsDownload(missing)
            }
            if recognizers.isEmpty {
                throw failure ?? SpeechSetupError.unsupported(languages)
            }
            return recognizers
        }
        #endif
        let allowed = await LivePermissions.requestSpeechRecognition()
        Log.info("语音识别：SFSpeechRecognizer，权限\(allowed ? "已授权" : "被拒绝")")
        guard allowed else {
            throw SpeechSetupError.permissionDenied
        }
        var recognizers: [UtteranceRecognizer] = []
        var notOnDevice: [Language] = []
        for language in languages {
            if let recognizer = SystemSpeechRecognizer(language: language) {
                recognizers.append(recognizer)
            } else {
                notOnDevice.append(language)
            }
        }
        Log.info("离线语音识别：可用 \(codes(recognizers.map(\.language)))，没有离线模型 \(codes(notOnDevice))")
        if recognizers.isEmpty {
            throw SpeechSetupError.notOnDevice(notOnDevice)
        }
        return recognizers
    }

    /// macOS 26: downloads the speech models of `languages` (managed by macOS, shared with other apps). `keeping` are
    /// all the languages about to be used, whose reservations must stay.
    static func downloadModels(for languages: [Language], keeping: [Language], progress: @escaping (Double) -> Void) async throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            for (index, language) in languages.enumerated() {
                try await AnalyzerSpeechRecognizer.download(language: language, keeping: keeping) { fraction in
                    progress((Double(index) + fraction) / Double(languages.count))
                }
            }
        }
        #endif
    }

    static func codes(_ languages: [Language]) -> String {
        languages.isEmpty ? "-" : languages.map(\.code).joined(separator: "+")
    }
}

// MARK: - SFSpeechRecognizer (macOS 13+)

/// One on-device recognition request per utterance. Ending the request at each pause keeps every request
/// well under the one-minute limit and gives a final result right after the speaker stops.
final class SystemSpeechRecognizer: UtteranceRecognizer {
    let language: Language
    var onPartial: ((Int, String) -> Void)?
    var onFinal: ((Int, String, Double?) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private var current: Utterance?   // audio pipeline queue only

    private final class Utterance {
        let id: Int
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var text = ""
        var delivered = false  // main thread only

        init(id: Int) { self.id = id }
    }

    /// Nil when the language has no offline model on this Mac.
    init?(language: Language) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: SpeechLocales.identifier(for: language))),
              recognizer.supportsOnDeviceRecognition else { return nil }
        self.language = language
        self.recognizer = recognizer
        recognizer.defaultTaskHint = .dictation
    }

    func begin(_ utterance: Int, at sample: Int64) {
        let state = Utterance(id: utterance)
        state.request.shouldReportPartialResults = true
        state.request.requiresOnDeviceRecognition = true
        state.request.addsPunctuation = true
        state.request.taskHint = .dictation
        // Results arrive on the recognizer's queue, the main queue.
        state.task = recognizer.recognitionTask(with: state.request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                state.text = result.bestTranscription.formattedString
                if result.isFinal {
                    deliver(state, confidence: SystemSpeechRecognizer.confidence(result))
                } else if !state.delivered {
                    onPartial?(state.id, state.text)
                }
            }
            if error != nil {
                deliver(state, confidence: nil) // e.g. "no speech detected": keep whatever was heard
            }
        }
        current = state
    }

    func append(_ samples: [Float], at sample: Int64) {
        guard let current, let buffer = MonoResampler.buffer(samples) else { return }
        current.request.append(buffer)
    }

    func end(_ utterance: Int, at sample: Int64) {
        guard let state = current, state.id == utterance else { return }
        current = nil
        state.request.endAudio()
        // The final result normally follows within a fraction of a second; don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.deliver(state, confidence: nil)
        }
    }

    func cancel(_ utterance: Int) {
        guard let state = current, state.id == utterance else { return }
        current = nil
        state.task?.cancel()
        DispatchQueue.main.async { state.delivered = true }
    }

    func shutdown() {
        if let current {
            cancel(current.id)
        }
    }

    private func deliver(_ state: Utterance, confidence: Double?) {
        guard !state.delivered else { return }
        state.delivered = true
        state.task = nil
        onFinal?(state.id, state.text, confidence)
    }

    private static func confidence(_ result: SFSpeechRecognitionResult) -> Double? {
        let values = result.bestTranscription.segments.map { Double($0.confidence) }
        guard !values.isEmpty, values.contains(where: { $0 > 0 }) else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - SpeechAnalyzer (macOS 26+)

#if compiler(>=6.2)
/// One long-running SpeechAnalyzer per language, fed only the utterances. At each pause the analyzer is asked to
/// finalize up to that point, so the sentence's final text arrives right away; its phrases are collected per utterance.
@available(macOS 26.0, *)
final class AnalyzerSpeechRecognizer: UtteranceRecognizer, @unchecked Sendable { // utterance state is main-thread only
    let language: Language
    var onPartial: ((Int, String) -> Void)?
    var onFinal: ((Int, String, Double?) -> Void)?

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: FormatConverter
    private var resultsTask: Task<Void, Never>?
    private var utterances: [Utterance] = []   // main thread only

    private final class Utterance {
        let id: Int
        let start: Double
        var end: Double?
        var text = ""
        var volatile = ""
        var confidences: [Double] = []
        var delivered = false

        init(id: Int, start: Double) {
            self.id = id
            self.start = start
        }
    }

    private init(language: Language, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.language = language
        self.analyzer = analyzer
        self.input = input
        converter = FormatConverter(to: format)
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    DispatchQueue.main.async { self?.handle(result) }
                }
            } catch {
                Log.error("SpeechAnalyzer 识别出错", error)
            }
        }
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.transcriptionConfidence])
    }

    private static func locale(for language: Language) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: SpeechLocales.identifier(for: language))) else {
            throw SpeechSetupError.unsupported([language])
        }
        return locale
    }

    /// - Parameter keeping: All the languages of this session, whose model reservations must stay.
    static func make(language: Language, keeping: [Language]) async throws -> AnalyzerSpeechRecognizer {
        let speechLocale = try await locale(for: language)
        let module = transcriber(for: speechLocale)
        // Whether the model is installed only shows once the locale is reserved. assetInstallationRequest(supporting:)
        // can't tell: it returns a request even for an installed model.
        try await reserve(speechLocale, for: language, keeping: keeping)
        let status = await modelStatus(module)
        Log.info("语音模型 \(name(speechLocale))：\(status.rawValue)")
        switch SpeechModelPlan.action(for: status) {
        case .ready:
            break
        case .download:
            throw SpeechSetupError.needsDownload([language])
        case .unsupported:
            throw SpeechSetupError.unsupported([language])
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: nil)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechSetupError.unsupported([language])
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        Log.info("SpeechAnalyzer 已启动：\(name(speechLocale))，\(format)")
        return AnalyzerSpeechRecognizer(language: language, transcriber: module, analyzer: analyzer, format: format, input: continuation)
    }

    static func download(language: Language, keeping: [Language], progress: @escaping (Double) -> Void) async throws {
        let speechLocale = try await locale(for: language)
        let module = transcriber(for: speechLocale)
        try await reserve(speechLocale, for: language, keeping: keeping)
        var status = await modelStatus(module)
        Log.info("下载语音模型 \(name(speechLocale))：开始前 \(status.rawValue)")
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let observation = request.progress.observe(\.fractionCompleted) { value, _ in
                    progress(value.fractionCompleted)
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
            status = await modelStatus(module)
        }
        Log.info("下载语音模型 \(name(speechLocale))：结束后 \(status.rawValue)")
        guard status == .installed else {
            throw SpeechSetupError.downloadIncomplete([language], status)
        }
        progress(1)
    }

    /// Reserves the locale's model for this app: macOS reports a model as installed, and keeps it, for the locales an
    /// app has reserved. When the app already holds as many reservations as allowed, ones it doesn't need now go first.
    private static func reserve(_ speechLocale: Locale, for language: Language, keeping languages: [Language]) async throws {
        var needed: [String] = []
        for other in languages {
            if let otherLocale = try? await locale(for: other) {
                needed.append(key(otherLocale))
            }
        }
        let reserved = await AssetInventory.reservedLocales
        let maximum = AssetInventory.maximumReservedLocales
        let release = SpeechModelPlan.reservationsToRelease(reserved: reserved.map { key($0) }, needed: needed, maximum: maximum)
        for old in reserved where release.contains(key(old)) {
            let released = await AssetInventory.release(reservedLocale: old)
            Log.info("释放不再使用的语音模型预留 \(name(old))：\(released)")
        }
        let summary = "已预留 \(reserved.isEmpty ? "-" : reserved.map { name($0) }.joined(separator: ", "))，上限 \(maximum)"
        do {
            let added = try await AssetInventory.reserve(locale: speechLocale)
            Log.info("预留语音模型 \(name(speechLocale))：\(added ? "新预留" : "之前已预留")（\(summary)）")
        } catch {
            Log.error("无法预留语音模型 \(name(speechLocale))（\(summary)）", error)
            throw SpeechSetupError.cannotReserve([language], error.localizedDescription)
        }
    }

    private static func modelStatus(_ module: SpeechTranscriber) async -> SpeechModelStatus {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    private static func key(_ locale: Locale) -> String {
        SpeechModelPlan.key(languageCode: locale.language.languageCode?.identifier ?? locale.identifier, region: locale.region?.identifier)
    }

    private static func name(_ locale: Locale) -> String { locale.identifier(.bcp47) }

    func begin(_ utterance: Int, at sample: Int64) {
        let start = Double(sample) / 16000
        DispatchQueue.main.async { [weak self] in
            self?.utterances.append(Utterance(id: utterance, start: start))
        }
    }

    func append(_ samples: [Float], at sample: Int64) {
        guard let source = MonoResampler.buffer(samples), let buffer = converter.convert(source) else { return }
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: sample, timescale: 16000)))
    }

    func end(_ utterance: Int, at sample: Int64) {
        let end = Double(sample) / 16000
        DispatchQueue.main.async { [weak self] in
            self?.utterances.first { $0.id == utterance }?.end = end
        }
        let analyzer = self.analyzer
        Task { [weak self] in
            do {
                try await analyzer.finalize(through: CMTime(value: sample, timescale: 16000))
            } catch {
                Log.error("SpeechAnalyzer 无法结束这句话", error)
            }
            // Results already delivered by now are queued on the main thread before this.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.deliver(utterance) }
        }
    }

    func cancel(_ utterance: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.utterances.removeAll { $0.id == utterance }
        }
    }

    func shutdown() {
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    // Main thread.
    private func handle(_ result: SpeechTranscriber.Result) {
        let time = result.range.start.seconds
        // Phrases belong to the last utterance that started before them.
        guard let utterance = utterances.last(where: { !$0.delivered && $0.start <= time + 0.05 }) ?? utterances.first(where: { !$0.delivered }) else { return }
        let text = String(result.text.characters)
        if result.isFinal {
            utterance.text = join(utterance.text, text)
            utterance.volatile = ""
            for run in result.text.runs {
                if let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                    let number: Any = value
                    if let confidence = (number as? Double) ?? (number as? Float).map(Double.init) {
                        utterance.confidences.append(confidence)
                    }
                }
            }
            if let end = utterance.end, result.resultsFinalizationTime.seconds >= end - 0.01 {
                deliver(utterance.id)
            } else {
                onPartial?(utterance.id, utterance.text)
            }
        } else {
            utterance.volatile = text
            onPartial?(utterance.id, join(utterance.text, text))
        }
    }

    private func deliver(_ id: Int) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        let utterance = utterances.remove(at: index)
        guard !utterance.delivered else { return }
        utterance.delivered = true
        let text = join(utterance.text, utterance.volatile) // volatile text that never got finalized is still better than nothing
        let confidence = utterance.confidences.isEmpty ? nil : utterance.confidences.reduce(0, +) / Double(utterance.confidences.count)
        onFinal?(id, text, confidence)
    }

    // Languages written with spaces get one between phrases.
    private func join(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespaces)
        let b = second.trimmingCharacters(in: .whitespaces)
        if a.isEmpty || b.isEmpty {
            return a + b
        }
        let unspaced = language.isChinese || language.code == "ja" || language.code == "th"
        return unspaced ? a + b : a + " " + b
    }
}

/// Converts 16 kHz mono buffers to the format a SpeechAnalyzer asked for.
final class FormatConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format {
            return buffer
        }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
#endif
