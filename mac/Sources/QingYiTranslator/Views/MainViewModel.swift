import AppKit
import Combine
import QingYiCore
import SwiftUI

/// State and logic of the main window; the view only renders it.
@MainActor
final class MainViewModel: ObservableObject {
    // Longer texts are only translated on demand (⌘↩), so an accidental ⌘A, ⌘C⌘C can't burn tokens.
    private static let autoTranslateLimit = 20_000
    private static let debounceNanoseconds: UInt64 = 700_000_000

    let settings: AppSettings
    let history: TranslationHistory
    let glossary: Glossary

    private let client = TranslationClient()
    private let incremental = IncrementalCache()
    private var subscriptions = Set<AnyCancellable>()

    @Published var sourceText = "" {
        didSet { if sourceText != oldValue { onSourceChanged() } }
    }
    @Published var outputText = ""
    @Published private(set) var statusText = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorNeedsSettings = false
    @Published private(set) var isBusy = false
    @Published private(set) var detected: Language?
    @Published private(set) var source: Language?          // nil: detect automatically
    @Published private(set) var preferredTarget: Language   // what the user picked
    @Published private(set) var target: Language            // what the current text goes into
    @Published var isHistoryOpen = false
    @Published var historySearch = ""
    @Published private(set) var copied = false
    @Published private(set) var availableUpdate: ReleaseInfo?
    @Published private(set) var topmost: Bool
    @Published private(set) var engineText = ""
    @Published private(set) var engineOk = true
    @Published private(set) var placeholderHint = ""
    @Published private(set) var shortcutHint = ""
    @Published private(set) var shortcutHintIsError = false
    @Published private(set) var focusRequest = 0

    /// Wired up by the app delegate.
    var openSettings: (() -> Void)?
    var openGlossary: (() -> Void)?
    var showUpdate: ((ReleaseInfo) -> Void)?
    var hideWindow: (() -> Void)?
    var shortcutDescriptions: () -> [String] = { [] }
    var shortcutError: () -> String? = { nil }

    private var debounceTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationId = 0
    private var lastRequestKey: String?
    private var status: (() -> String)?
    private var restoringHistory = false
    private var copyFeedbackVersion = 0

    init(settings: AppSettings, history: TranslationHistory, glossary: Glossary) {
        self.settings = settings
        self.history = history
        self.glossary = glossary
        let preferred = Languages.find(settings.targetLanguage) ?? Languages.simplifiedChinese
        source = Languages.find(settings.sourceLanguage)
        preferredTarget = preferred
        target = preferred
        topmost = settings.topmost

        Loc.shared.$isEnglish
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onInterfaceLanguageChanged() }
            .store(in: &subscriptions)
        history.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        refreshSettingsDisplay()
    }

    // ---------------- called by the app ----------------

    /// Brings up text from the clipboard or hotkey. With text, translates it; without, focuses the input box.
    func showWithText(_ text: String?) {
        isHistoryOpen = false
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            focusSource()
            return
        }
        // A fixed source language that doesn't match the new text would give nonsense, so fall back to detection.
        if let chosen = source, let found = LanguageDetector.detect(text), !found.isSameLanguage(as: chosen) {
            source = nil
            settings.sourceLanguage = Languages.autoCode
        }
        sourceText = text
        focusSource()
        translate(force: false)
    }

    func focusSource() { focusRequest += 1 }

    func refreshSettingsDisplay() {
        let preset = settings.activePreset
        let config = settings.active
        let problem: String? = config.model.trimmingCharacters(in: .whitespaces).isEmpty ? L("未设置模型", "No model set")
            : preset.requiresApiKey && settings.apiKey(for: settings.activeProvider).isEmpty ? L("未设置 API Key", "No API key")
            : nil
        engineText = "\(preset.displayName.text) · \(problem ?? config.model)"
        engineOk = problem == nil

        let shortcuts = shortcutDescriptions()
        let joined = shortcuts.joined(separator: L(" 或 ", " or "))
        placeholderHint = shortcuts.isEmpty ? "" : L("也可以在任意软件中选中文字，按 \(joined) 翻译", "Or select text in any app and press \(joined)")
        if let error = shortcutError() {
            shortcutHint = error
            shortcutHintIsError = true
        } else {
            shortcutHint = shortcuts.isEmpty ? "" : L("选中文字后按 \(joined) 翻译", "Select text and press \(joined) to translate")
            shortcutHintIsError = false
        }
    }

    func onSettingsChanged() {
        refreshSettingsDisplay()
        // The request key covers provider, model, extra instructions and the glossary,
        // so this only calls the API if one of them changed.
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translate(force: false)
        }
    }

    /// Shows or hides the "new version" badge in the header.
    func showUpdateAvailable(_ release: ReleaseInfo?) { availableUpdate = release }

    /// A one-off message in the status line, e.g. after an update.
    func showNotice(_ message: @escaping () -> String) {
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setStatus(message)
        }
    }

    // ---------------- translation ----------------

    func translate(force: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        let text = sourceText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resetOutput()
            return
        }
        if !force && text.count > MainViewModel.autoTranslateLimit {
            cancelTranslation()
            let length = text.count
            setStatus { L("文本较长（\(MainViewModel.group(length)) 字符），按 ⌘↩ 开始翻译", "Long text (\(MainViewModel.group(length)) characters). Press ⌘↩ to translate") }
            return
        }

        let (detected, promptSource, target) = resolveLanguages(text)
        self.detected = detected
        self.target = target

        let preset = settings.activePreset
        let config = settings.active
        let apiKey = settings.apiKey(for: settings.activeProvider)
        let contextKey = buildContextKey(promptSource: promptSource, target: target, preset: preset, config: config)
        let requestKey = contextKey + "\u{1F}" + text
        if !force && requestKey == lastRequestKey {
            return
        }
        lastRequestKey = requestKey

        // Reuse the translation of unchanged leading paragraphs; ⌘↩ / the retranslate button starts over.
        let plan = force || !settings.incrementalTranslation ? IncrementalPlan.full(text) : incremental.plan(contextKey: contextKey, text: text)

        cancelTranslation()
        hideError()
        if plan.nothingNew {
            outputText = MainViewModel.trimEnd(plan.reusedTranslation)
            incremental.commit(contextKey: contextKey, plan: plan, remainderTranslation: "")
            return
        }

        translationId += 1
        let id = translationId
        outputText = plan.reusedTranslation
        let full = plan.isFull
        setStatus { full ? L("正在翻译…", "Translating…") : L("正在翻译新增内容…", "Translating the new part…") }
        isBusy = true
        let started = Date()
        let glossaryHits = settings.glossaryEnabled ? glossary.match(plan.remainder) : []
        let request = TranslationRequest(text: plan.remainder, source: promptSource, target: target, context: plan.context, glossary: glossaryHits)
        let extra = settings.extraInstructions

        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.translate(preset: preset, config: config, apiKey: apiKey, extraInstructions: extra,
                                                        request: request) { [weak self] delta in
                    guard let self, self.translationId == id else { return }
                    self.outputText += delta
                }
                guard translationId == id else { return }
                incremental.commit(contextKey: contextKey, plan: plan, remainderTranslation: result.text)
                let elapsed = Date().timeIntervalSince(started)
                let hits = glossaryHits.count
                setStatus { MainViewModel.describeResult(result, preset: preset, elapsed: elapsed, full: full, glossaryHits: hits) }
                if !result.text.isEmpty {
                    recordHistory(text: text, source: promptSource ?? detected, target: target, preset: preset, config: config)
                }
            } catch is CancellationError {
                // Superseded by newer input.
            } catch let error as TranslationError {
                if translationId == id {
                    failTranslation(error.message, needsSettings: error.needsSettings)
                }
            } catch {
                Log.error("翻译失败", error)
                if translationId == id {
                    failTranslation(L("翻译失败：\(error.localizedDescription)", "Translation failed: \(error.localizedDescription)"), needsSettings: false)
                }
            }
            if translationId == id {
                translationTask = nil
                isBusy = false
            }
        }
    }

    /// With automatic detection, text already written in the picked target language goes to the fallback
    /// (Chinese → English, anything else → Chinese); the model is then left to identify the source itself.
    private func resolveLanguages(_ text: String) -> (detected: Language?, promptSource: Language?, target: Language) {
        if let chosen = source {
            return (chosen, chosen, preferredTarget)
        }
        let detected = LanguageDetector.detect(text)
        let target = detected != nil && detected!.isSameLanguage(as: preferredTarget) ? Languages.fallback(for: preferredTarget) : preferredTarget
        return (detected, nil, target)
    }

    private func buildContextKey(promptSource: Language?, target: Language, preset: ProviderPreset, config: ProviderConfig) -> String {
        [promptSource?.code ?? Languages.autoCode, target.code, preset.id, config.baseUrl, config.model,
         settings.extraInstructions, settings.glossaryEnabled ? "\(glossary.version)" : "-1"].joined(separator: "\u{1F}")
    }

    private static func describeResult(_ result: TranslationResult, preset: ProviderPreset, elapsed: TimeInterval, full: Bool, glossaryHits: Int) -> String {
        var summary: String
        switch result.finishReason {
        case "length": summary = L("译文过长，已被截断", "The translation was too long and got cut off")
        case "content_filter": summary = L("部分内容被服务商过滤，译文可能不完整", "The provider filtered some content; the translation may be incomplete")
        case "insufficient_system_resource": summary = L("服务器资源不足，译文可能不完整，请稍后重试", "The server ran out of resources; the translation may be incomplete. Please try again later")
        default:
            summary = result.text.isEmpty
                ? L("服务器没有返回译文", "The server returned no translation")
                : L("\(preset.displayName.text) · \(String(format: "%.1f", elapsed)) 秒", "\(preset.displayName.text) · \(String(format: "%.1f", elapsed)) s")
        }
        if !result.text.isEmpty && (result.finishReason == nil || result.finishReason == "stop") {
            if !full {
                summary += L(" · 只翻译了新增内容", " · only the new part was translated")
            }
            if glossaryHits > 0 {
                summary += L(" · 用到 \(glossaryHits) 条术语", glossaryHits == 1 ? " · 1 glossary term" : " · \(glossaryHits) glossary terms")
            }
        }
        return summary
    }

    private func recordHistory(text: String, source: Language?, target: Language, preset: ProviderPreset, config: ProviderConfig) {
        guard settings.saveHistory else { return }
        history.record(HistoryEntry(time: Date(), sourceText: text, translatedText: outputText, sourceLanguage: source?.code,
                                    targetLanguage: target.code, engine: "\(preset.displayName.en) · \(config.model)"))
    }

    private func failTranslation(_ message: String, needsSettings: Bool) {
        lastRequestKey = nil
        setStatus(nil)
        errorMessage = message
        errorNeedsSettings = needsSettings
    }

    private func hideError() { errorMessage = nil }

    private func setStatus(_ status: (() -> String)?) {
        self.status = status
        statusText = status?() ?? ""
    }

    private func cancelTranslation() {
        guard let task = translationTask else { return }
        task.cancel()
        translationTask = nil
        translationId += 1
        isBusy = false
    }

    private func resetOutput() {
        cancelTranslation()
        lastRequestKey = nil
        incremental.clear()
        outputText = ""
        hideError()
        setStatus(nil)
        detected = nil
        target = preferredTarget
    }

    private func onSourceChanged() {
        if restoringHistory {
            return
        }
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debounceTask?.cancel()
            resetOutput()
            return
        }
        guard settings.autoTranslate else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: MainViewModel.debounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            translate(force: false)
        }
    }

    // ---------------- languages ----------------

    var sourceLabel: String {
        if let source {
            return source.localName
        }
        if let detected {
            return L("\(detected.localName)（检测到）", "\(detected.localName) (detected)")
        }
        return L("检测语言", "Detect language")
    }

    func selectSource(_ language: Language?) {
        source = language
        settings.sourceLanguage = language?.code ?? Languages.autoCode
        translate(force: false)
    }

    func selectTarget(_ language: Language) {
        preferredTarget = language
        target = language
        settings.targetLanguage = language.code
        translate(force: false)
    }

    func swapLanguages() {
        let from = source ?? LanguageDetector.detect(sourceText) ?? Languages.fallback(for: target)
        let to = target
        source = to
        preferredTarget = from
        target = from
        settings.sourceLanguage = to.code
        settings.targetLanguage = from.code

        // Like DeepL, the translation becomes the new input.
        let translation = outputText
        if !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            restoringHistory = true
            sourceText = translation
            restoringHistory = false
        }
        translate(force: false)
    }

    // ---------------- history ----------------

    var filteredHistory: [HistoryEntry] {
        let query = historySearch.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return history.entries
        }
        return history.entries.filter {
            $0.sourceText.range(of: query, options: .caseInsensitive) != nil || $0.translatedText.range(of: query, options: .caseInsensitive) != nil
        }
    }

    var historyEmptyText: String {
        if !history.entries.isEmpty {
            return L("没有找到匹配的记录", "No matching entries")
        }
        return settings.saveHistory ? L("还没有翻译记录", "No translations yet") : L("翻译历史已在设置中关闭", "History is turned off in Settings")
    }

    func toggleHistory() { isHistoryOpen.toggle() }

    func deleteHistory(_ entry: HistoryEntry) { history.remove(entry) }

    func clearHistory(window: NSWindow?) {
        if Dialogs.confirm(window, heading: L("清空翻译历史", "Clear history"),
                           message: L("确定要清空全部翻译历史吗？此操作无法撤销。", "Delete all history entries? This can’t be undone."),
                           confirmText: L("清空", "Clear all"), danger: true) {
            history.clear()
        }
    }

    /// Shows a past translation without calling the API; editing it afterwards translates incrementally.
    func restoreFromHistory(_ entry: HistoryEntry) {
        cancelTranslation()
        debounceTask?.cancel()
        restoringHistory = true
        sourceText = entry.sourceText
        restoringHistory = false

        let target = Languages.find(entry.targetLanguage) ?? preferredTarget
        // Keep the user's pick when it already leads to this entry's language (e.g. the Chinese→English fallback);
        // otherwise adopt the entry's target, so the drop-down and any later edits agree with what is on screen.
        if resolveLanguages(entry.sourceText).target != target {
            preferredTarget = target
            settings.targetLanguage = target.code
        }
        detected = source ?? LanguageDetector.detect(entry.sourceText)
        self.target = target

        hideError()
        outputText = entry.translatedText
        setStatus { L("来自翻译历史 · \(entry.timeText)", "From history · \(entry.timeText)") }

        let contextKey = buildContextKey(promptSource: source, target: target, preset: settings.activePreset, config: settings.active)
        lastRequestKey = contextKey + "\u{1F}" + entry.sourceText
        incremental.commit(contextKey: contextKey, plan: IncrementalPlan.full(entry.sourceText), remainderTranslation: entry.translatedText)

        isHistoryOpen = false
        focusSource()
    }

    // ---------------- UI actions ----------------

    func clearSource() {
        sourceText = ""
        focusSource()
    }

    func copyTranslation() {
        let text = outputText
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copyFeedbackVersion += 1
        let version = copyFeedbackVersion
        copied = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, version == copyFeedbackVersion else { return }
            copied = false
        }
    }

    func togglePin() {
        topmost.toggle()
        settings.topmost = topmost
        settings.save()
    }

    private func onInterfaceLanguageChanged() {
        refreshSettingsDisplay()
        statusText = status?() ?? ""
        objectWillChange.send()
    }

    var characterCountText: String {
        let length = sourceText.count
        if length == 0 {
            return ""
        }
        return L("\(MainViewModel.group(length)) 字符", length == 1 ? "1 character" : "\(MainViewModel.group(length)) characters")
    }

    static func group(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private static func trimEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
}
