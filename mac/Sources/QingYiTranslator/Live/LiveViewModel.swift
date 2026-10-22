import AppKit
import Combine
import QingYiCore
import SwiftUI
import UniformTypeIdentifiers

/// State and logic of the live transcription window; the counterpart of Views/LiveWindow.xaml.cs.
@MainActor
final class LiveViewModel: ObservableObject {
    private static let draftDelayNanoseconds: UInt64 = 700_000_000

    enum State { case idle, preparing, downloading, running, paused }

    /// What the banner above the transcript is about; decides its buttons.
    enum BannerKind: Equatable {
        case info
        case error
        case settings
        case permission(LivePermissions.Kind)
        case dictation
        case modelDownload([Language])
    }

    struct Banner {
        var kind: BannerKind
        var text: () -> String
        var progress: Double?
    }

    let settings: AppSettings
    let glossary: Glossary
    let transcript = LiveTranscript()

    @Published private(set) var state = State.idle
    @Published private(set) var statusText = ""
    @Published private(set) var banner: Banner?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var microphones: [AudioDevices.Device] = []

    @Published var audioSource: String { didSet { if audioSource != oldValue { sourceChanged() } } }
    @Published var microphoneId: String { didSet { if microphoneId != oldValue { sourceChanged() } } }
    @Published var sourceLanguage: String { didSet { if sourceLanguage != oldValue { sourceLanguageChanged() } } }
    @Published var targetLanguage: String { didSet { if targetLanguage != oldValue { targetLanguageChanged() } } }
    @Published var translatePartials: Bool { didSet { settings.live.translatePartials = translatePartials; settings.save() } }
    @Published var showCaptions: Bool { didSet { settings.live.showCaptions = showCaptions; settings.save(); updateCaptions() } }

    /// Wired up by `LiveController`.
    var openSettings: (() -> Void)?
    var captionsChanged: ((TranscriptLine?, TranscriptLine?) -> Void)?

    private let client = TranslationClient()
    private let context = LiveTranslationContext()
    private var session: LiveSession?
    private var sessionId = 0
    private var translationQueue: [Int] = []
    private var translating = false
    private var draftTask: Task<Void, Never>?
    private var draftLineId: Int?
    private var draftedText: String?
    private var status: (() -> String)?
    private var subscriptions = Set<AnyCancellable>()

    init(settings: AppSettings, glossary: Glossary) {
        self.settings = settings
        self.glossary = glossary
        let live = settings.live
        audioSource = live.audioSource
        microphoneId = live.microphoneId ?? ""
        sourceLanguage = live.sourceLanguage
        targetLanguage = live.targetLanguage
        translatePartials = live.translatePartials
        showCaptions = live.showCaptions
        refreshMicrophones()

        transcript.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        Loc.shared.$isEnglish.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                statusText = status?() ?? ""
                objectWillChange.send()
            }
            .store(in: &subscriptions)
    }

    var isRunning: Bool { state != .idle && state != .paused }

    var usesMicrophone: Bool { audioSource == LiveSettings.sourceMicrophone || audioSource == LiveSettings.sourceBoth }

    var usesSystemAudio: Bool { audioSource == LiveSettings.sourceSystem || audioSource == LiveSettings.sourceBoth }

    // ---------------- start / pause / stop ----------------

    func toggleRunning() {
        if isRunning {
            stop()
        } else {
            startOrResume()
        }
    }

    func startOrResume() {
        if state == .paused {
            Task { await resume() }
        } else if state == .idle {
            Task { await start() }
        }
    }

    func pause() {
        guard state == .running, let session else { return }
        session.stopCapture()
        state = .paused
        setStatus { L("已暂停", "Paused") }
    }

    /// Releases the devices and the recognizers; the sentence in progress is still finished and translated.
    func stop() {
        if state == .preparing {
            sessionId += 1 // the preparation in progress is thrown away when it completes
        }
        session?.stop()
        session = nil
        state = .idle
        draftTask?.cancel()
        micLevel = 0
        systemLevel = 0
        setStatus(transcript.lines.isEmpty ? nil : { L("已停止", "Stopped") })
    }

    private func start() async {
        guard state == .idle else { return }
        banner = nil
        state = .preparing
        setStatus { L("正在准备…", "Getting ready…") }
        let id = sessionId + 1
        sessionId = id

        // Permissions for the audio sources first; the recognizers ask for their own.
        if usesMicrophone, !(await LivePermissions.requestMicrophone()) {
            fail(.permission(.microphone)) {
                L("轻译没有使用麦克风的权限。请在“系统设置 › 隐私与安全性 › 麦克风”中打开轻译。更新轻译后，原来的授权可能失效，可以点“重置权限”再试。",
                  "QingYi isn’t allowed to use the microphone. Turn it on under System Settings › Privacy & Security › Microphone. After an update the old permission may no longer apply; click “Reset permission” and try again.")
            }
            return
        }
        if usesSystemAudio, !LivePermissions.usesProcessTap, !LivePermissions.requestScreenRecording() {
            fail(.permission(.systemAudio)) {
                L("在 macOS 14.2 之前，录制电脑的声音需要“屏幕录制”权限。请在“系统设置 › 隐私与安全性 › 屏幕录制”中打开轻译，然后重新打开轻译。",
                  "Before macOS 14.2, recording the Mac’s sound needs the Screen Recording permission. Turn on QingYi under System Settings › Privacy & Security › Screen Recording, then reopen QingYi.")
            }
            return
        }

        let languages = SpeechLocales.languages(for: sourceLanguage)
        let recognizers: [UtteranceRecognizer]
        do {
            recognizers = try await SpeechEngine.makeRecognizers(for: languages)
        } catch let error as SpeechSetupError {
            guard id == sessionId else { return }
            handleSetupError(error)
            return
        } catch {
            guard id == sessionId else { return }
            Log.error("无法启动语音识别", error)
            fail(.error) { L("无法启动语音识别：\(error.localizedDescription)", "Couldn’t start speech recognition: \(error.localizedDescription)") }
            return
        }
        guard id == sessionId, state == .preparing else {
            recognizers.forEach { $0.shutdown() }
            return
        }
        if recognizers.count < languages.count {
            let missing = languages.filter { language in !recognizers.contains { $0.language == language } }
            showBanner(.dictation) {
                L("\(missing.map(\.localName).joined(separator: "、"))的离线语音识别模型还没有安装，这次只识别\(recognizers.map(\.language.localName).joined(separator: "、"))。在“系统设置 › 键盘 › 听写”中添加该语言即可下载。",
                  "The offline speech model for \(missing.map(\.localName).joined(separator: ", ")) isn’t installed, so only \(recognizers.map(\.language.localName).joined(separator: ", ")) is recognized. Add the language under System Settings › Keyboard › Dictation to download it.")
            }
        }

        let session = LiveSession(recognizers: recognizers)
        session.onPartial = { [weak self] utterance, text, start in
            guard let self, id == sessionId else { return }
            onPartial(utterance, text, start)
        }
        session.onFinal = { [weak self] utterance, text, start, end, language in
            guard let self, id == sessionId else { return }
            onFinal(utterance, text, start, end, language)
        }
        session.onDiscarded = { [weak self] utterance in
            guard let self, id == sessionId else { return }
            transcript.discard(utterance)
        }
        session.onLevels = { [weak self, weak session] microphone, system in
            guard let self, let session, self.session === session else { return }
            micLevel = microphone
            systemLevel = system
        }
        session.onFailure = { [weak self, weak session] message in
            guard let self, let session, self.session === session else { return }
            showBanner(.error) { message }
        }
        session.onSystemAudioSilent = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            showBanner(.permission(.systemAudio)) {
                L("电脑正在播放声音，但轻译收到的是静音，可能没有“系统录音”权限。请在“系统设置 › 隐私与安全性 › 屏幕与系统录音”中允许轻译录制系统声音，然后停止再重新开始。",
                  "The Mac is playing sound but QingYi only receives silence, so it probably lacks the system audio recording permission. Allow QingYi under System Settings › Privacy & Security › Screen & System Audio Recording, then stop and start again.")
            }
        }
        self.session = session
        transcript.beginSession()
        context.clear()
        await resume()
    }

    private func resume() async {
        guard let session else { return }
        do {
            try await session.startCapture(source: audioSource, microphoneUID: microphoneId.isEmpty ? nil : microphoneId)
        } catch let error as LiveAudioError {
            state = .paused
            setStatus { L("没有在聆听", "Not listening") }
            if error.kind == .screenRecordingPermission {
                fail(.permission(.systemAudio)) { error.message + L("请在“系统设置 › 隐私与安全性 › 屏幕录制”中打开轻译，然后重新打开轻译。",
                                                                   " Turn on QingYi under System Settings › Privacy & Security › Screen Recording, then reopen QingYi.") }
                state = .paused
            } else {
                showBanner(.error) { error.message }
            }
            return
        } catch {
            state = .paused
            showBanner(.error) { error.localizedDescription }
            return
        }
        state = .running
        let languages = session.languages.map(\.localName).joined(separator: " / ")
        setStatus { L("正在聆听 · \(languages) · 本机识别", "Listening · \(languages) · on this Mac") }
    }

    private func handleSetupError(_ error: SpeechSetupError) {
        switch error {
        case .permissionDenied:
            fail(.permission(.speechRecognition)) {
                L("轻译没有使用语音识别的权限。请在“系统设置 › 隐私与安全性 › 语音识别”中打开轻译。更新轻译后，原来的授权可能失效，可以点“重置权限”再试。",
                  "QingYi isn’t allowed to use speech recognition. Turn it on under System Settings › Privacy & Security › Speech Recognition. After an update the old permission may no longer apply; click “Reset permission” and try again.")
            }
        case .notOnDevice(let languages):
            let names = languages.map(\.localName).joined(separator: L("、", ", "))
            fail(.dictation) {
                L("这台 Mac 还没有\(names)的离线语音识别模型。请打开“系统设置 › 键盘 › 听写”，开启听写并在“语言”中添加\(names)，macOS 会自动下载模型，然后再点“开始”。",
                  "This Mac doesn’t have the offline speech model for \(names) yet. Open System Settings › Keyboard › Dictation, turn Dictation on and add \(names) under Languages; macOS downloads the model. Then click Start again.")
            }
        case .needsDownload(let languages):
            let names = languages.map(\.localName).joined(separator: L("、", ", "))
            fail(.modelDownload(languages)) {
                L("第一次使用需要下载\(names)的语音识别模型（由 macOS 下载和管理，其他应用也能共用）。识别完全在本机进行，声音不会上传。",
                  "The speech model for \(names) needs a one-time download (macOS downloads and manages it, and other apps share it). Recognition runs entirely on this Mac; no audio is uploaded.")
            }
        case .unsupported(let languages):
            let names = languages.map(\.localName).joined(separator: L("、", ", "))
            fail(.error) { L("macOS 的语音识别暂不支持\(names)，请换一种语言。", "macOS speech recognition doesn’t support \(names) yet. Please pick another language.") }
        }
    }

    // ---------------- banner actions ----------------

    func bannerPrimaryAction() {
        guard let banner else { return }
        switch banner.kind {
        case .permission(let kind):
            LivePermissions.openSettings(kind)
        case .dictation:
            LivePermissions.openDictationSettings()
        case .settings:
            self.banner = nil
            openSettings?()
        case .modelDownload(let languages):
            Task { await downloadModels(languages) }
        case .info, .error:
            self.banner = nil
        }
    }

    /// Clears the app's answers so macOS asks again (useful after an update invalidated an earlier grant).
    func resetPermission(_ kind: LivePermissions.Kind) {
        LivePermissions.reset([kind])
        banner = nil
        if state == .idle || state == .paused {
            stop()
            startOrResume()
        }
    }

    private func downloadModels(_ languages: [Language]) async {
        state = .downloading
        banner?.progress = 0
        setStatus { L("正在下载语音模型…", "Downloading the speech model…") }
        do {
            try await SpeechEngine.downloadModels(for: languages) { fraction in
                DispatchQueue.main.async { [weak self] in self?.banner?.progress = fraction }
            }
        } catch {
            Log.error("下载语音模型失败", error)
            state = .idle
            setStatus(nil)
            showBanner(.modelDownload(languages)) {
                L("语音模型下载失败：\(error.localizedDescription)。请检查网络后重试。", "The speech model download failed: \(error.localizedDescription). Check your network and try again.")
            }
            return
        }
        state = .idle
        banner = nil
        await start()
    }

    private func fail(_ kind: BannerKind, _ text: @escaping () -> String) {
        state = .idle
        setStatus(nil)
        showBanner(kind, text)
    }

    private func showBanner(_ kind: BannerKind, _ text: @escaping () -> String) {
        banner = Banner(kind: kind, text: text, progress: nil)
    }

    func dismissBanner() { banner = nil }

    // ---------------- recognition results ----------------

    private func onPartial(_ utterance: Int, _ text: String, _ start: Double) {
        guard let line = transcript.updatePartial(utterance, text: text, start: start) else { return }
        updateCaptions()
        if translatePartials {
            draftLineId = line.id
            draftTask?.cancel()
            draftTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: LiveViewModel.draftDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.translateDraft(lineId: line.id)
            }
        }
    }

    private func onFinal(_ utterance: Int, _ text: String, _ start: Double, _ end: Double, _ language: Language?) {
        let line = transcript.finalize(utterance, text: text, start: start, end: end, language: language?.code)
        if line == nil || line?.id == draftLineId {
            draftTask?.cancel()
            draftLineId = nil
        }
        guard let line else { return }
        translationQueue.append(line.id)
        updateCaptions()
        Task { await translateQueue() }
    }

    // ---------------- translation ----------------

    private var selectedSource: Language? { Languages.find(sourceLanguage) }

    private var preferredTarget: Language { Languages.find(targetLanguage) ?? Languages.simplifiedChinese }

    /// Final sentences are translated one after another, each with the previous ones as context.
    private func translateQueue() async {
        guard !translating else { return }
        translating = true
        defer { translating = false }
        while !translationQueue.isEmpty {
            let id = translationQueue.removeFirst()
            guard let line = transcript.line(id: id) else { continue } // cleared meanwhile
            if let translation = await translate(line, draft: false), !translation.isEmpty {
                context.add(source: line.text, translation: translation)
            }
        }
    }

    private func translateDraft(lineId: Int) async {
        guard let line = transcript.line(id: lineId), !line.isFinal, line.text.count >= 4, line.text != draftedText else { return }
        draftedText = line.text
        _ = await translate(line, draft: true)
    }

    private func translate(_ line: TranscriptLine, draft: Bool) async -> String? {
        let (promptSource, target) = LiveTranslationContext.resolveLanguages(line.text, source: selectedSource, preferredTarget: preferredTarget)
        let request = TranslationRequest(text: line.text, source: promptSource, target: target, context: context.turns,
                                         glossary: settings.glossaryEnabled ? glossary.match(line.text) : [])
        let id = line.id
        var output = ""
        if !draft {
            transcript.setTranslation(id: id, line.translation, draft: line.translationIsDraft, translating: true)
        }
        do {
            let result = try await client.translate(preset: settings.activePreset, config: settings.active, apiKey: settings.apiKey(for: settings.activeProvider),
                                                    extraInstructions: LiveTranslationContext.buildInstructions(settings.extraInstructions),
                                                    request: request) { [weak self] delta in
                guard let self, let current = transcript.line(id: id) else { return }
                if draft && (current.isFinal || Task.isCancelled) {
                    return // the final translation takes over
                }
                output += delta
                transcript.setTranslation(id: id, output, draft: draft, translating: !draft)
                updateCaptions()
            }
            if draft {
                if transcript.line(id: id)?.isFinal == true {
                    return nil
                }
            }
            transcript.setTranslation(id: id, result.text.trimmingCharacters(in: .whitespacesAndNewlines), draft: draft, translating: false)
            if banner?.kind == .settings {
                banner = nil
            }
            updateCaptions()
            return result.text
        } catch let error as TranslationError {
            if !draft {
                transcript.setTranslation(id: id, output, draft: false, translating: false)
                showBanner(error.needsSettings ? .settings : .error) { L("翻译失败：\(error.message)", "Translation failed: \(error.message)") }
            }
        } catch {
            if !draft {
                transcript.setTranslation(id: id, output, draft: false, translating: false)
                if !(error is CancellationError) {
                    Log.error("实时翻译失败", error)
                }
            }
        }
        return nil
    }

    // ---------------- sources and languages ----------------

    func refreshMicrophones() {
        microphones = AudioDevices.inputDevices()
    }

    private func sourceChanged() {
        settings.live.audioSource = audioSource
        settings.live.microphoneId = microphoneId.isEmpty ? nil : microphoneId
        settings.save()
        if state == .running {
            Task { await resume() } // reopens the devices
        }
    }

    private func sourceLanguageChanged() {
        settings.live.sourceLanguage = sourceLanguage
        settings.save()
        if state == .running || state == .paused {
            stop() // the recognizers are set up for their languages
            startOrResume()
        }
    }

    private func targetLanguageChanged() {
        settings.live.targetLanguage = targetLanguage
        settings.save()
        context.clear() // earlier translations are in the old language
    }

    // ---------------- captions, export, clear ----------------

    func updateCaptions() {
        let lines = transcript.lines
        captionsChanged?(lines.count > 1 ? lines[lines.count - 2] : nil, lines.last)
    }

    func export(format: TranscriptFormat, content: TranscriptContent, window: NSWindow?) {
        let text = TranscriptExport.build(transcript.lines, format: format, content: content)
        if text.isEmpty {
            Dialogs.inform(window, heading: L("没有可以导出的内容", "Nothing to export"),
                           message: content == .translation ? L("还没有翻译好的句子。", "No sentence has been translated yet.")
                               : L("还没有识别出完整的句子。", "No sentence has been recognized yet."))
            return
        }
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        panel.nameFieldStringValue = L("实时转录 \(stamp)", "Transcript \(stamp)") + "." + format.rawValue
        panel.allowedContentTypes = [format == .srt ? (UTType(filenameExtension: "srt") ?? .plainText) : .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.error("导出转录失败", error)
            Dialogs.inform(window, heading: L("导出失败", "Export failed"), message: error.localizedDescription)
        }
    }

    func clear(window: NSWindow?) {
        guard !transcript.lines.isEmpty,
              Dialogs.confirm(window, heading: L("清空转录内容", "Clear the transcript"),
                              message: L("确定要清空全部原文和译文吗？没有导出的内容将无法找回。", "Delete all sentences and translations? Anything not exported is lost."),
                              confirmText: L("清空", "Clear"), danger: true) else { return }
        translationQueue.removeAll()
        draftTask?.cancel()
        draftLineId = nil
        transcript.clear()
        transcript.beginSession()
        context.clear()
        updateCaptions()
    }

    func copy(_ line: TranscriptLine, original: Bool, translation: Bool) {
        let text = [original ? line.text : "", translation ? line.translation : ""].filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setStatus(_ status: (() -> String)?) {
        self.status = status
        statusText = status?() ?? ""
    }
}
