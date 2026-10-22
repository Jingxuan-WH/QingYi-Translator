import AppKit
import QingYiCore
import SwiftUI
import UniformTypeIdentifiers

/// One term of the review list; entries from the user's glossary are marked.
@MainActor
final class TermRow: ObservableObject, Identifiable {
    let id = UUID()
    @Published var source: String
    @Published var target: String
    let fromGlossary: Bool

    init(source: String, target: String, fromGlossary: Bool) {
        self.source = source
        self.target = target
        self.fromGlossary = fromGlossary
    }
}

/// Calls the provider selected in the settings when the job starts; kept outside the main actor for the job's batches.
final class ModelCaller: @unchecked Sendable {
    private let lock = NSLock()
    private var preset: ProviderPreset
    private var config: ProviderConfig
    private var apiKey: String
    private var target: Language

    init(settings: AppSettings, target: Language) {
        preset = settings.activePreset
        config = settings.active
        apiKey = settings.apiKey(for: settings.activeProvider)
        self.target = target
    }

    func update(settings: AppSettings, target: Language) {
        lock.lock()
        defer { lock.unlock() }
        preset = settings.activePreset
        config = settings.active
        apiKey = settings.apiKey(for: settings.activeProvider)
        self.target = target
    }

    private func snapshot() -> (ProviderPreset, ProviderConfig, String, Language) {
        lock.lock()
        defer { lock.unlock() }
        return (preset, config, apiKey, target)
    }

    func call(_ system: String, _ user: String) async throws -> TranslationResult {
        let (preset, config, apiKey, target) = snapshot()
        let request = TranslationRequest(text: user, source: nil, target: target, systemPrompt: system)
        return try await TranslationClient().translate(preset: preset, config: config, apiKey: apiKey, extraInstructions: "", request: request) { _ in }
    }
}

/// Runs `operation` away from the main actor; cancelling the calling task cancels it too (a plain detached task
/// would keep running).
private func offMain<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let task = Task.detached(operation: operation)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// Translates a whole file: pick or drop it, review the field and terms the model found, follow the progress,
/// then open the translated copy saved next to the original.
@MainActor
final class FileTranslationViewModel: ObservableObject {
    enum Stage { case pick, loading, analyzing, review, translating, done, failed }

    let settings: AppSettings
    let glossary: Glossary

    @Published private(set) var stage = Stage.pick
    @Published private(set) var fileURL: URL?
    @Published private(set) var fileInfo = ""
    @Published var target: Language {
        didSet {
            // The detected terms were translated into the old language: ask again for the new one.
            if target != oldValue && stage == .review {
                analyze()
            }
        }
    }
    @Published var domain = ""
    @Published var style = ""
    @Published var terms: [TermRow] = []
    @Published var skipReferences = true
    @Published var bilingual = false
    @Published private(set) var hasReferences = false
    @Published private(set) var supportsBilingual = false
    @Published private(set) var detectedLanguage: Language?
    @Published private(set) var analysisNote: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var heading = ""
    @Published private(set) var detail = ""
    @Published private(set) var warnings: [String] = []
    @Published private(set) var result: FileTranslationResult?
    @Published private(set) var needsSettings = false
    @Published private(set) var canResume = false

    /// Wired up by the app delegate.
    var openSettings: (() -> Void)?

    private var document: TranslatableDocument?
    private var job: FileTranslationJob?
    private var caller: ModelCaller?
    private var userTerms: [GlossaryEntry] = []
    private var options: FileTranslationOptions?
    private var work: Task<Void, Never>?
    private var workId = 0
    private var started = Date()

    init(settings: AppSettings, glossary: Glossary) {
        self.settings = settings
        self.glossary = glossary
        target = Languages.find(settings.targetLanguage) ?? Languages.simplifiedChinese
    }

    var isTranslating: Bool { stage == .translating }
    var isBusy: Bool { stage == .loading || stage == .analyzing || stage == .translating }

    var serviceText: String { L("翻译服务：\(settings.activePreset.displayName.text) · \(settings.active.model)", "Service: \(settings.activePreset.displayName.text) · \(settings.active.model)") }

    // ---------------- files ----------------

    /// Starts with `url`; refused (with a message) while another file is being translated.
    func open(_ url: URL) {
        if refuseWhileTranslating() {
            return
        }
        load(url)
    }

    func chooseFile(from window: NSWindow?) {
        if refuseWhileTranslating() {
            return
        }
        let panel = NSOpenPanel()
        panel.title = L("选择要翻译的文件", "Choose a file to translate")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentLoader.extensions.compactMap { UTType(filenameExtension: $0) }
        if let folder = fileURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func refuseWhileTranslating() -> Bool {
        guard stage == .translating else { return false }
        Dialogs.inform(nil, heading: L("正在翻译另一个文件", "Another file is being translated"),
                       message: L("请等它完成，或先取消，再翻译新的文件。", "Wait for it to finish, or cancel it, before translating a new file."))
        return true
    }

    private func nextWork() -> Int {
        work?.cancel()
        workId += 1
        return workId
    }

    private func load(_ url: URL) {
        let id = nextWork()
        fileURL = url
        document = nil
        job = nil
        result = nil
        canResume = false
        fileInfo = url.deletingLastPathComponent().path
        stage = .loading
        work = Task { [weak self] in
            do {
                let document = try await offMain { try DocumentLoader.open(url) }
                guard let self, self.workId == id else { return }
                self.document = document
                let caller = ModelCaller(settings: self.settings, target: self.target)
                self.caller = caller
                // A local model handles one request at a time.
                let concurrency = self.settings.activePreset.id == "Ollama" ? 1 : 4
                let job = FileTranslationJob(document: document, call: { system, user in try await caller.call(system, user) }, maxConcurrency: concurrency)
                self.job = job
                let detected = job.detectSourceLanguage()
                self.detectedLanguage = detected
                let preferred = Languages.find(self.settings.targetLanguage) ?? Languages.simplifiedChinese
                self.stage = .analyzing // set before target, so changing it doesn't start another analysis
                self.target = detected.map { $0.isSameLanguage(as: preferred) } == true ? Languages.fallback(for: preferred) : preferred
                self.userTerms = self.settings.glossaryEnabled ? DomainAnalyzer.matchGlossary(self.glossary.entries, document.segments) : []
                self.fileInfo = self.describe(document, url)
                self.hasReferences = document.segments.contains { $0.isReference }
                self.supportsBilingual = document.supportsBilingual
                self.analyze()
            } catch let error as DocumentError {
                guard let self, self.workId == id else { return }
                self.fail(error.message, canResume: false)
            } catch {
                guard let self, self.workId == id else { return }
                Log.error("读取文件失败：\(url.path)", error)
                self.fail(L("无法读取文件：\(error.localizedDescription)", "Couldn’t read the file: \(error.localizedDescription)"), canResume: false)
            }
        }
    }

    private func describe(_ document: TranslatableDocument, _ url: URL) -> String {
        let characters = document.segments.reduce(0) { $0 + $1.plainText.count }
        let kind: String
        switch url.pathExtension.lowercased() {
        case "pdf": kind = "PDF"
        case "docx", "docm": kind = "Word"
        case "pptx", "pptm": kind = "PowerPoint"
        case "xlsx", "xlsm": kind = "Excel"
        case "md", "markdown": kind = "Markdown"
        case "srt": kind = L("SRT 字幕", "SRT subtitles")
        default: kind = L("纯文本", "Plain text")
        }
        let count = document.segments.count
        return L("\(kind) · \(count) 段 · 约 \(characters) 字符", "\(kind) · \(count) segments · about \(characters) characters")
    }

    // ---------------- analysis ----------------

    private func analyze() {
        guard let job, let caller else { return }
        let id = nextWork()
        stage = .analyzing
        caller.update(settings: settings, target: target)
        let target = self.target
        let answer = Loc.isEnglish ? Languages.english : Languages.simplifiedChinese
        work = Task { [weak self] in
            do {
                let profile = try await offMain { try await job.analyze(target: target, answerLanguage: answer) }
                guard let self, self.workId == id else { return }
                self.showReview(profile, note: profile == nil
                    ? L("没能识别出领域（模型的回答无法解析）。可以自己填写，或直接开始翻译。", "The field couldn’t be identified (the model’s answer was unreadable). Fill it in yourself, or just start.")
                    : nil)
            } catch is CancellationError {
                // Skipped or replaced.
            } catch let error as TranslationError {
                guard let self, self.workId == id else { return }
                if error.needsSettings {
                    self.fail(error.message, canResume: false, needsSettings: true)
                } else {
                    self.showReview(nil, note: L("领域识别失败：\(error.message)。可以自己填写，或直接开始翻译。",
                                                 "Identifying the field failed: \(error.message). Fill it in yourself, or just start."))
                }
            } catch {
                guard let self, self.workId == id else { return }
                self.showReview(nil, note: L("领域识别失败：\(error.localizedDescription)", "Identifying the field failed: \(error.localizedDescription)"))
            }
        }
    }

    private func showReview(_ profile: DomainProfile?, note: String?) {
        domain = profile?.domainText ?? ""
        style = profile?.style ?? ""
        terms = DomainAnalyzer.mergeTerms(userTerms, profile?.terms ?? []).map { TermRow(source: $0.source, target: $0.target, fromGlossary: $0.fromGlossary) }
        analysisNote = note
        stage = .review
    }

    func addTerm() { terms.append(TermRow(source: "", target: "", fromGlossary: false)) }

    func delete(_ row: TermRow) { terms.removeAll { $0.id == row.id } }

    // ---------------- translation ----------------

    /// `useProfile` false: the "skip" button, translating with the user's glossary only.
    func start(useProfile: Bool) {
        guard let document else { return }
        var profile: DomainProfile?
        var chosen = userTerms
        if useProfile {
            let field = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            let register = style.trimmingCharacters(in: .whitespacesAndNewlines)
            if !field.isEmpty || !register.isEmpty {
                profile = DomainProfile(domain: field, subdomain: "", style: register, terms: [])
            }
            chosen = Glossary.clean(terms.map { GlossaryEntry(source: $0.source, target: $0.target) })
        }
        options = FileTranslationOptions(target: target, profile: profile, terms: chosen, extraInstructions: settings.extraInstructions,
                                         skipReferences: skipReferences || !hasReferences, bilingual: bilingual && document.supportsBilingual)
        translate()
    }

    func resume() {
        if canResume {
            translate()
        }
    }

    private func translate() {
        guard let job, let options, let caller else { return }
        let id = nextWork()
        caller.update(settings: settings, target: options.target)
        stage = .translating
        progress = 0
        heading = L("正在翻译…", "Translating…")
        detail = L("正在准备…", "Getting ready…")
        started = Date()
        work = Task { [weak self] in
            do {
                let result = try await offMain {
                    try await job.translate(options: options) { report in
                        Task { @MainActor [weak self] in self?.report(report, id: id) }
                    }
                }
                guard let self, self.workId == id else { return }
                self.finish(result)
            } catch is CancellationError {
                guard let self, self.workId == id else { return }
                self.fail(L("已取消。已经翻译的部分会保留，继续翻译时不会重复请求。", "Cancelled. What was already translated is kept and won’t be requested again."),
                          canResume: true, cancelled: true)
            } catch let error as TranslationError {
                guard let self, self.workId == id else { return }
                self.fail(error.message, canResume: true, needsSettings: error.needsSettings)
            } catch let error as DocumentError {
                guard let self, self.workId == id else { return }
                self.fail(error.message, canResume: true)
            } catch {
                guard let self, self.workId == id else { return }
                Log.error("文件翻译失败", error)
                self.fail(L("翻译失败：\(error.localizedDescription)", "Translation failed: \(error.localizedDescription)"), canResume: true)
            }
        }
    }

    private func report(_ report: FileTranslationProgress, id: Int) {
        guard workId == id, stage == .translating else { return }
        progress = report.total == 0 ? 1 : Double(report.done) / Double(report.total)
        var text = L("已翻译 \(report.done) / \(report.total) 段", "\(report.done) of \(report.total) segments translated")
        let elapsed = Date().timeIntervalSince(started)
        if report.done > 0 && report.done < report.total && elapsed > 5 {
            let remaining = elapsed / Double(report.done) * Double(report.total - report.done)
            let minutes = remaining < 60 ? L("不到 1 分钟", "under a minute") : L("约 \(Int((remaining / 60).rounded(.up))) 分钟", "about \(Int((remaining / 60).rounded(.up))) min")
            text += L(" · 预计还需\(minutes)", " · \(minutes) left")
        }
        detail = text
    }

    func cancel() {
        work?.cancel()
        if stage == .loading {
            fileURL = nil
            stage = .pick
        }
    }

    private func finish(_ result: FileTranslationResult) {
        self.result = result
        heading = L("翻译完成", "Translation finished")
        detail = L("已保存为 \(result.outputURL.lastPathComponent)\n位置：\(result.outputURL.deletingLastPathComponent().path)",
                   "Saved as \(result.outputURL.lastPathComponent)\nin \(result.outputURL.deletingLastPathComponent().path)")
        var list: [String] = []
        if result.untranslated > 0 {
            list.append(L("有 \(result.untranslated) 段没能翻译，保留了原文。", "\(result.untranslated) segment(s) couldn’t be translated and kept the original text."))
        }
        warnings = list + result.warnings
        stage = .done
    }

    private func fail(_ message: String, canResume: Bool, needsSettings: Bool = false, cancelled: Bool = false) {
        self.canResume = canResume && job != nil && options != nil
        self.needsSettings = needsSettings
        heading = cancelled ? L("翻译已取消", "Translation cancelled") : L("出了点问题", "Something went wrong")
        detail = message
        warnings = []
        stage = .failed
    }

    func openOutput() {
        if let url = result?.outputURL {
            NSWorkspace.shared.open(url)
        }
    }

    func openBilingual() {
        if let url = result?.bilingualURL {
            NSWorkspace.shared.open(url)
        }
    }

    func revealOutput() {
        if let url = result?.outputURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Handles a file drop; true when it contained a file.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor [weak self] in self?.open(url) }
        }
        return true
    }
}

struct FileTranslationView: View {
    @ObservedObject var model: FileTranslationViewModel
    @EnvironmentObject var loc: Loc
    var window: () -> NSWindow?
    var close: () -> Void

    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            Group {
                switch model.stage {
                case .pick: pickPanel
                case .loading, .analyzing: busyPanel
                case .review: reviewPanel
                case .translating, .done, .failed: resultPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Palette.window)
        .frame(minWidth: 560, minHeight: 460)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { model.handleDrop($0) }
    }

    private var fileHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9).fill(Palette.accentSoft).frame(width: 38, height: 38)
                .overlay(Image(systemName: "doc.text").font(.system(size: 17, weight: .medium)).foregroundColor(Palette.accentText))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.fileURL?.lastPathComponent ?? L("还没有选择文件", "No file chosen yet"))
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(Palette.textPrimary).lineLimit(1).truncationMode(.middle)
                Text(model.fileInfo).font(.system(size: 12)).foregroundColor(Palette.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.fileURL != nil {
                Button(L("选择其他文件…", "Choose another file…")) { model.chooseFile(from: window()) }
                    .buttonStyle(LinkButtonStyle()).disabled(model.isTranslating)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var pickPanel: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundColor(Palette.accentText)
            Text(L("把文件拖到这里，或点击选择文件", "Drop a file here, or click to choose one"))
                .font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.textPrimary).padding(.top, 14)
            Text(L("支持 PDF（文字版）、Word、PowerPoint、Excel、TXT、Markdown 和 SRT 字幕。译文另存在原文件旁边，原文件不会被修改。",
                   "PDF (with real text), Word, PowerPoint, Excel, TXT, Markdown and SRT subtitles. The translation is saved next to the original, which is never changed."))
                .font(.system(size: 13)).foregroundColor(Palette.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460).padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Palette.accentSoft : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Palette.accent : Palette.inputLine, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .contentShape(Rectangle())
        .onTapGesture { model.chooseFile(from: window()) }
        .padding(24)
    }

    private var busyPanel: some View {
        VStack(spacing: 14) {
            Text(model.stage == .loading ? L("正在读取文件…", "Reading the file…") : L("正在识别文档的领域和术语…", "Identifying the document’s field and terms…"))
                .font(.system(size: 15)).foregroundColor(Palette.textPrimary)
            ProgressView().progressViewStyle(.linear).frame(width: 320)
            Text(model.stage == .loading
                 ? L("大的 PDF 可能需要十几秒。", "A large PDF can take a few seconds.")
                 : L("会把标题、摘要、各级标题和部分段落发给模型，只请求一次。", "The title, abstract, headings and some paragraphs are sent to the model in one request."))
                .font(.system(size: 12)).foregroundColor(Palette.textTertiary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 48)
    }

    private var reviewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("翻译成", "Translate into")).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                    Picker("", selection: $model.target) {
                        ForEach(Languages.all) { language in
                            Text(language.localName).tag(language)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 200)
                    if let detected = model.detectedLanguage {
                        Text(L("原文：\(detected.localName)（自动识别）", "Source: \(detected.localName) (detected)"))
                            .font(.system(size: 12)).foregroundColor(Palette.textTertiary)
                    }
                    Spacer()
                }
                .padding(.top, 14)

                SectionTitle(text: L("领域与文体", "Field and style"))
                Text(model.analysisNote ?? L("模型根据文档摘录识别出下面的信息，翻译时会据此选用术语和行文风格。可以直接修改。",
                                             "The model identified the following from excerpts of the document; the translation follows it. You can edit it."))
                    .font(.system(size: 12)).foregroundColor(model.analysisNote == nil ? Palette.textTertiary : Palette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(L("领域", "Field")).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                        TextField("", text: $model.domain).formField()
                    }
                    GridRow {
                        Text(L("文体", "Style")).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
                        TextField("", text: $model.style).formField()
                    }
                }

                HStack(alignment: .lastTextBaseline) {
                    SectionTitle(text: L("术语（\(model.terms.count)）", "Terms (\(model.terms.count))"))
                    Spacer()
                    Button(L("+ 添加术语", "+ Add a term")) { model.addTerm() }.buttonStyle(LinkButtonStyle())
                }
                Text(L("全文的这些术语都会按这里的译法翻译。标着“术语表”的来自你的术语表，优先于识别出的术语。这里的修改只用于这次翻译。",
                       "These terms are translated this way throughout. Entries marked “Glossary” come from your glossary and take priority over detected terms. Changes here apply to this translation only."))
                    .font(.system(size: 12)).foregroundColor(Palette.textTertiary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                if model.terms.isEmpty {
                    Text(L("没有术语。", "No terms.")).font(.system(size: 12)).foregroundColor(Palette.textTertiary)
                }
                VStack(spacing: 6) {
                    ForEach(model.terms) { row in
                        TermRowView(row: row) { model.delete(row) }
                    }
                }

                SectionTitle(text: L("选项", "Options"))
                if model.hasReferences {
                    ToggleRow(title: L("不翻译参考文献列表（节省费用，引用信息保持原样）", "Don’t translate the reference list (saves cost; citations stay as they are)"),
                              isOn: $model.skipReferences)
                }
                if model.supportsBilingual {
                    ToggleRow(title: L("同时生成双语对照 PDF（原文页和译文页交替，适合版面复杂的文档）", "Also create a bilingual PDF (original and translated pages alternate; handy for complex layouts)"),
                              isOn: $model.bilingual)
                }
                if !model.hasReferences && !model.supportsBilingual {
                    Text(L("这个文件没有可选项。", "No options for this file.")).font(.system(size: 12)).foregroundColor(Palette.textTertiary)
                }
            }
            .padding(EdgeInsets(top: 4, leading: 24, bottom: 18, trailing: 24))
        }
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            if model.stage == .done || model.stage == .failed {
                Image(systemName: model.stage == .done ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundColor(model.stage == .done ? Palette.success : Palette.warning)
            }
            Text(model.heading).font(.system(size: 17, weight: .semibold)).foregroundColor(Palette.textPrimary)
                .multilineTextAlignment(.center).padding(.top, 10)
            if model.stage == .translating {
                ProgressView(value: model.progress).progressViewStyle(.linear).frame(width: 360).padding(.top, 16)
            }
            Text(model.detail).font(.system(size: 13)).foregroundColor(Palette.textSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.top, 12)
            if !model.warnings.isEmpty {
                Text(model.warnings.joined(separator: "\n")).font(.system(size: 12)).foregroundColor(Palette.warning)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            }
            if model.stage == .done {
                HStack(spacing: 10) {
                    Button(L("打开译文", "Open translation")) { model.openOutput() }.buttonStyle(PrimaryButtonStyle())
                    Button(L("在访达中显示", "Show in Finder")) { model.revealOutput() }.buttonStyle(SecondaryButtonStyle())
                    if model.result?.bilingualURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                        Button(L("打开双语对照版", "Open bilingual version")) { model.openBilingual() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.top, 18)
            }
        }
        .padding(.horizontal, 48)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.stage == .review || model.stage == .translating ? model.serviceText : "")
                .font(.system(size: 12)).foregroundColor(Palette.textTertiary).lineLimit(1)
            Spacer()
            switch model.stage {
            case .pick:
                Button(L("选择文件…", "Choose a file…")) { model.chooseFile(from: window()) }.buttonStyle(PrimaryButtonStyle())
            case .loading, .translating:
                Button(L("取消", "Cancel")) { model.cancel() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            case .analyzing:
                Button(L("跳过，直接翻译", "Skip and translate")) { model.start(useProfile: false) }.buttonStyle(SecondaryButtonStyle())
                    .help(L("不使用识别出的领域和术语，只按你的术语表翻译", "Ignore the detected field and terms; use only your glossary"))
            case .review:
                Button(L("跳过，直接翻译", "Skip and translate")) { model.start(useProfile: false) }.buttonStyle(SecondaryButtonStyle())
                    .help(L("不使用识别出的领域和术语，只按你的术语表翻译", "Ignore the detected field and terms; use only your glossary"))
                Button(L("开始翻译", "Start translating")) { model.start(useProfile: true) }.buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button(L("关闭", "Close")) { close() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("翻译其他文件…", "Translate another file…")) { model.chooseFile(from: window()) }.buttonStyle(PrimaryButtonStyle())
            case .failed:
                if model.needsSettings {
                    Button(L("打开设置", "Open settings")) { model.openSettings?() }.buttonStyle(SecondaryButtonStyle())
                }
                if model.canResume {
                    Button(L("继续翻译", "Continue")) { model.resume() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button(L("选择文件…", "Choose a file…")) { model.chooseFile(from: window()) }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24))
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct TermRowView: View {
    @ObservedObject var row: TermRow
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(L("术语", "Term"), text: $row.source).formField()
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundColor(Palette.textTertiary)
            TextField(L("译法", "Translation"), text: $row.target).formField()
            if row.fromGlossary {
                Text(L("术语表", "Glossary")).font(.system(size: 11)).foregroundColor(Palette.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Palette.accentSoft))
                    .help(L("来自你的术语表，优先使用", "From your glossary; it takes priority"))
            }
            IconButton(symbol: "trash", help: L("删除", "Delete"), size: 26, fontSize: 12) { onDelete() }
        }
    }
}

/// The "翻译文件" entry in the main window's header, next to "翻译文本".
struct TranslateFileHeaderButton: View {
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 13, weight: .medium))
                Text(L("翻译文件", "Translate files")).font(.system(size: 14))
            }
            .foregroundColor(hovering ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Palette.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("翻译 PDF、Word、PPT、Excel 等文件 (⌘O)，也可以把文件拖进窗口", "Translate PDF, Word, PowerPoint, Excel and other files (⌘O); you can also drop a file on the window"))
        .accessibilityLabel(L("翻译文件", "Translate files"))
    }
}
