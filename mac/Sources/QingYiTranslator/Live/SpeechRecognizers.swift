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
    /// Recognition ran into an error; the message is for the user. True when the recognizer stopped for good.
    var onFailure: ((String, Bool) -> Void)? { get set }
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
    var onFailure: ((String, Bool) -> Void)? // each utterance is its own request, so an error only ends that one

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
/// If the analyzer stops with an error, it is set up again (up to a few times) and the user is told.
@available(macOS 26.0, *)
final class AnalyzerSpeechRecognizer: UtteranceRecognizer, @unchecked Sendable { // state is guarded as marked
    private static let maxFailures = 3

    let language: Language
    var onPartial: ((Int, String) -> Void)?
    var onFinal: ((Int, String, Double?) -> Void)?
    var onFailure: ((String, Bool) -> Void)?

    private let speechLocale: Locale
    private let format: AVAudioFormat
    private let builder: AnalyzerInputBuilder  // audio pipeline queue only
    private let lock = NSLock()
    // Guarded by `lock`; replaced when the analyzer is set up again after an error.
    private var analyzer: SpeechAnalyzer
    private var input: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var isShutDown = false
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

    private init(language: Language, locale: Locale, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.language = language
        speechLocale = locale
        self.format = format
        self.analyzer = analyzer
        self.input = input
        builder = AnalyzerInputBuilder(format: format, name: AnalyzerSpeechRecognizer.name(locale))
        resultsTask = watchResults(of: transcriber, generation: 0)
    }

    /// Results go to the main thread. When they stop for any reason but `shutdown()`, the analyzer has stopped working.
    private func watchResults(of transcriber: SpeechTranscriber, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            var failure: Error?
            do {
                for try await result in transcriber.results {
                    DispatchQueue.main.async { self?.handle(result) }
                }
            } catch {
                failure = error
            }
            self?.resultsEnded(generation: generation, error: failure)
        }
    }

    private func resultsEnded(generation: Int, error: Error?) {
        guard let failures = countFailure(generation: generation) else { return } // shut down, or an older analyzer
        let name = AnalyzerSpeechRecognizer.name(speechLocale)
        Log.error("SpeechAnalyzer 停止工作（\(name)，第 \(failures) 次）\(error == nil ? "：识别结果意外结束" : "")", error)
        let detail = error?.localizedDescription ?? L("识别结果意外结束", "its results ended unexpectedly")
        DispatchQueue.main.async { [weak self] in self?.deliverAll() } // the sentences in progress won't get more text
        guard failures <= AnalyzerSpeechRecognizer.maxFailures else {
            report(L("\(language.localName)的语音识别接连出错，已经停止（\(detail)）。请点“开始”重新开始；详细信息已写入日志。",
                     "Speech recognition for \(language.localName) failed repeatedly and has stopped (\(detail)). Click Start to begin again; details were written to the log."),
                   stopped: true)
            return
        }
        Task { [weak self] in await self?.restart(after: detail) }
    }

    private func restart(after detail: String) async {
        let name = AnalyzerSpeechRecognizer.name(speechLocale)
        do {
            let module = AnalyzerSpeechRecognizer.transcriber(for: speechLocale)
            let analyzer = SpeechAnalyzer(modules: [module], options: nil)
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            guard let old = replace(analyzer: analyzer, input: continuation, transcriber: module) else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }
            old.input.finish()
            await old.analyzer.cancelAndFinishNow()
            Log.info("SpeechAnalyzer 已重新启动：\(name)")
            report(L("\(language.localName)的语音识别出错了（\(detail)），已经自动重新启动，正在说的那句话可能不完整。",
                     "Speech recognition for \(language.localName) ran into an error (\(detail)) and was restarted; the sentence being spoken may be incomplete."),
                   stopped: false)
        } catch {
            Log.error("SpeechAnalyzer 无法重新启动（\(name)）", error)
            report(L("\(language.localName)的语音识别出错了（\(detail)），重新启动也失败了。请点“开始”重新开始；详细信息已写入日志。",
                     "Speech recognition for \(language.localName) ran into an error (\(detail)) and couldn’t be restarted. Click Start to begin again; details were written to the log."),
                   stopped: true)
        }
    }

    private func report(_ message: String, stopped: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message, stopped) }
    }

    // ---------------- state guarded by the lock ----------------

    /// Counts a failure of the current analyzer; nil when it doesn't count (shut down, or an analyzer already replaced).
    private func countFailure(generation: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown, generation == self.generation else { return nil }
        failures += 1
        return failures
    }

    private func replace(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation,
                         transcriber: SpeechTranscriber) -> (analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return nil }
        let old = (self.analyzer, self.input)
        self.analyzer = analyzer
        self.input = input
        generation += 1
        resultsTask = watchResults(of: transcriber, generation: generation)
        return old
    }

    private func current() -> (analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        return (analyzer, input)
    }

    private func resetFailures() {
        lock.lock()
        defer { lock.unlock() }
        failures = 0
    }

    private func markShutDown() -> (analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, task: Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        isShutDown = true
        return (analyzer, input, resultsTask)
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
        return AnalyzerSpeechRecognizer(language: language, locale: speechLocale, transcriber: module, analyzer: analyzer, format: format,
                                        input: continuation)
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
        let inputs = builder.inputs(samples, at: sample)
        guard !inputs.isEmpty else { return }
        let input = current().input
        inputs.forEach { input.yield($0) }
    }

    func end(_ utterance: Int, at sample: Int64) {
        let rest = builder.finish()
        let (analyzer, input) = current()
        rest.forEach { input.yield($0) }
        let through = builder.end ?? CMTime(value: sample, timescale: 16000)
        let end = through.seconds
        DispatchQueue.main.async { [weak self] in
            self?.utterances.first { $0.id == utterance }?.end = end
        }
        Task { [weak self] in
            do {
                try await analyzer.finalize(through: through)
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
        let (analyzer, input, task) = markShutDown()
        input.finish()
        task?.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }

    // Main thread.
    private func handle(_ result: SpeechTranscriber.Result) {
        let time = result.range.start.seconds
        // Phrases belong to the last utterance that started before them.
        guard let utterance = utterances.last(where: { !$0.delivered && $0.start <= time + 0.05 }) ?? utterances.first(where: { !$0.delivered }) else { return }
        let text = String(result.text.characters)
        if result.isFinal {
            resetFailures() // working again
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

    private func deliverAll() {
        for id in utterances.filter({ !$0.delivered }).map(\.id) {
            deliver(id)
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

/// Turns the 16 kHz mono samples of each utterance into inputs for a SpeechAnalyzer: in the format it asked for, on one
/// timeline that never goes back. The usual formats (16 kHz mono, 16-bit or float) are filled sample by sample, so a
/// buffer holds exactly the frames it was given. AVAudioConverter, needed only for another sample rate, holds frames
/// back between calls (4800 in gave 4096 out, then 640 in gave 704 out), so its buffers are timed by the frames it
/// actually produced and it is drained at the end of each utterance. Used from the audio pipeline's queue only.
final class AnalyzerInputBuilder {
    private let format: AVAudioFormat
    private let name: String
    private let direct: Bool
    private var converter: AVAudioConverter?
    private var converterNext: Int64?   // where the converter's next output starts, in the analyzer's frames
    private var timeline = AudioTimeline()

    init(format: AVAudioFormat, name: String) {
        self.format = format
        self.name = name
        direct = format.sampleRate == 16000 && format.channelCount == 1
            && (format.commonFormat == .pcmFormatInt16 || format.commonFormat == .pcmFormatFloat32)
    }

    /// The end of the audio handed over so far.
    var end: CMTime? {
        timeline.end.map { CMTime(value: $0, timescale: CMTimeScale(format.sampleRate)) }
    }

    /// - Parameter sample: Where `samples` start on the 16 kHz timeline.
    func inputs(_ samples: [Float], at sample: Int64) -> [AnalyzerInput] {
        guard !samples.isEmpty else { return [] }
        if direct {
            let (drop, start) = place(start: sample, count: samples.count)
            guard drop < samples.count, let buffer = makeBuffer(samples[drop...]) else { return [] }
            return [input(buffer, at: start)]
        }
        guard let source = MonoResampler.buffer(samples) else { return [] }
        let start = converterNext ?? Int64((Double(sample) * format.sampleRate / 16000).rounded())
        converterNext = start
        guard let output = convert(source) else { return [] }
        converterNext = start + Int64(output.frameLength)
        return placed(output, at: start)
    }

    /// The end of an utterance: drains the converter, so nothing it held back slips into the next utterance.
    func finish() -> [AnalyzerInput] {
        guard !direct, let start = converterNext else { return [] }
        defer {
            converter?.reset()
            converterNext = nil
        }
        guard let output = convert(nil) else { return [] }
        return placed(output, at: start)
    }

    private func placed(_ buffer: AVAudioPCMBuffer, at start: Int64) -> [AnalyzerInput] {
        let count = Int(buffer.frameLength)
        let (drop, placedStart) = place(start: start, count: count)
        guard drop < count, let kept = drop == 0 ? buffer : slice(buffer, from: drop) else { return [] }
        return [input(kept, at: placedStart)]
    }

    private func place(start: Int64, count: Int) -> (drop: Int, start: Int64) {
        let placed = timeline.place(start: start, count: count)
        if placed.drop > 0 {
            Log.info("SpeechAnalyzer（\(name)）：音频与上一块重叠，丢掉开头的 \(placed.drop) / \(count) 帧")
        }
        return placed
    }

    private func input(_ buffer: AVAudioPCMBuffer, at start: Int64) -> AnalyzerInput {
        AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: start, timescale: CMTimeScale(format.sampleRate)))
    }

    private func makeBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if format.commonFormat == .pcmFormatInt16 {
            guard let data = buffer.int16ChannelData else { return nil }
            let converted = AudioSamples.int16(Array(samples))
            converted.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: converted.count) }
        } else {
            guard let data = buffer.floatChannelData else { return nil }
            samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    /// Converts `source`, or with nil drains what the converter still holds.
    private func convert(_ source: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        if converter == nil {
            converter = AVAudioConverter(from: MonoResampler.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(source?.frameLength ?? 0) * format.sampleRate / 16000) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let source, !consumed {
                consumed = true
                inputStatus.pointee = .haveData
                return source
            }
            inputStatus.pointee = source == nil ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            Log.error("SpeechAnalyzer（\(name)）：音频格式转换失败", error)
            return nil
        }
        return output.frameLength == 0 ? nil : output
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from offset: Int) -> AVAudioPCMBuffer? {
        let count = Int(buffer.frameLength) - offset
        guard count > 0, let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        result.frameLength = AVAudioFrameCount(count)
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let sources = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let targets = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for (source, target) in zip(sources, targets) {
            guard let from = source.mData, let to = target.mData else { return nil }
            to.copyMemory(from: from + offset * bytesPerFrame, byteCount: count * bytesPerFrame)
        }
        return result
    }
}
#endif
