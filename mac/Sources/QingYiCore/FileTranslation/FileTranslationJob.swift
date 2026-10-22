import Foundation

/// Sends one request: a system prompt and a user message, returning the model's whole answer.
public typealias CompletionCall = @Sendable (_ systemPrompt: String, _ userMessage: String) async throws -> TranslationResult

public struct FileTranslationProgress: Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// `profile`: field, style and terms the user confirmed; nil when they skipped that step.
/// `terms`: the terms to enforce (the user's glossary entries and the confirmed detected terms).
public struct FileTranslationOptions {
    public var target: Language
    public var profile: DomainProfile?
    public var terms: [GlossaryEntry]
    public var extraInstructions: String
    public var skipReferences: Bool
    public var bilingual: Bool

    public init(target: Language, profile: DomainProfile?, terms: [GlossaryEntry], extraInstructions: String = "",
                skipReferences: Bool = true, bilingual: Bool = false) {
        self.target = target
        self.profile = profile
        self.terms = terms
        self.extraInstructions = extraInstructions
        self.skipReferences = skipReferences
        self.bilingual = bilingual
    }
}

public struct FileTranslationResult {
    public let outputURL: URL
    public let bilingualURL: URL?
    public let translated: Int
    public let untranslated: Int
    public let warnings: [String]
}

/// Translates one document: identifies its field and terms, translates the segments in batches with limited
/// concurrency and automatic retries, and saves the copy next to the original. Translations already received
/// are kept, so running `translate` again after an error only sends what is still missing.
public final class FileTranslationJob: @unchecked Sendable {
    private static let maxAttempts = 3

    public let document: TranslatableDocument
    private let call: CompletionCall
    private let maxConcurrency: Int
    private let lock = NSLock()
    private var done: [String: String] = [:] // tagged source text → translation
    private var doneKey: String?

    /// Seconds to wait before retry n (1-based); tests shorten it.
    public var retryDelay: @Sendable (Int) -> Double = { attempt in Double(attempt * attempt * 2) }

    public init(document: TranslatableDocument, call: @escaping CompletionCall, maxConcurrency: Int = 4) {
        self.document = document
        self.call = call
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// The language the document seems to be written in, from a sample of its text.
    public func detectSourceLanguage() -> Language? {
        LanguageDetector.detect(document.segments.prefix(200).map(\.plainText).joined(separator: "\n"))
    }

    /// Asks the model for the document's field, style and key terms. Returns nil if the answer can't be read.
    public func analyze(target: Language, answerLanguage: Language) async throws -> DomainProfile? {
        let sample = DomainAnalyzer.buildSample(document.segments)
        guard !sample.isEmpty else { return nil }
        let result = try await call(DomainAnalyzer.buildSystemPrompt(target: target, answerLanguage: answerLanguage), sample)
        let profile = DomainAnalyzer.parse(result.text)
        if profile == nil {
            Log.info("领域识别的回答无法解析：\(result.text.prefix(300))")
        }
        return profile
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Translates and saves. `progress` may be called on any thread.
    public func translate(options: FileTranslationOptions,
                          progress: (@Sendable (FileTranslationProgress) -> Void)? = nil) async throws -> FileTranslationResult {
        // Translations made for another target language or other terms don't carry over.
        let key = [options.target.code, options.profile?.domainText ?? "", options.profile?.style ?? "", options.extraInstructions,
                   options.terms.map { $0.source + "=" + $0.target }.joined(separator: "\u{1E}")].joined(separator: "\u{1F}")
        locked {
            if doneKey != key {
                done.removeAll()
            }
            doneKey = key
        }

        // The segments that will be sent, grouped by identical text (repeated headers, table headings… are translated once).
        var counts: [String: Int] = [:]
        var order: [String] = []
        for segment in document.segments where !(options.skipReferences && segment.isReference) {
            if counts[segment.text.text] == nil {
                order.append(segment.text.text)
            }
            counts[segment.text.text, default: 0] += 1
        }
        let frozenCounts = counts
        let total = counts.values.reduce(0, +)
        let alreadyDone = locked { order.filter { done[$0] != nil } }
        let progressState = ProgressState(done: alreadyDone.reduce(0) { $0 + counts[$1]! })
        progress?(FileTranslationProgress(done: progressState.value, total: total))

        let todo = locked { order.filter { done[$0] == nil } }
        let batches = SegmentBatcher.plan(todo, length: { $0.utf16.count })
        let untranslated = UntranslatedSet()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func start() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    let missing = try await self.translateBatch(batch, options: options)
                    // Segments the model left out are tried again one by one.
                    for text in missing {
                        let retry = try await self.translateBatch([text], options: options)
                        if !retry.isEmpty {
                            untranslated.insert(text)
                        }
                    }
                    let finished = batch.reduce(0) { $0 + frozenCounts[$1]! }
                    progress?(FileTranslationProgress(done: progressState.add(finished), total: total))
                }
            }
            for _ in 0..<maxConcurrency {
                start()
            }
            // The first error ends the loop and cancels the other batches; translations received so far stay for a retry.
            while try await group.next() != nil {
                start()
            }
        }
        try Task.checkCancellation()

        var translations: [Int: String] = [:]
        locked {
            for segment in document.segments where !(options.skipReferences && segment.isReference) {
                if let translation = done[segment.text.text] {
                    translations[segment.id] = translation
                }
            }
        }
        let output = OutputPaths.url(for: document.sourceURL, target: options.target)
        let bilingual = options.bilingual && document.supportsBilingual
            ? OutputPaths.url(for: document.sourceURL, target: options.target, variant: "bilingual") : nil
        try document.save(to: output, translations: translations, options: DocumentSaveOptions(target: options.target, bilingualURL: bilingual))
        let failed = document.segments.filter { untranslated.contains($0.text.text) }.count
        return FileTranslationResult(outputURL: output, bilingualURL: bilingual, translated: translations.count, untranslated: failed,
                                     warnings: document.warnings)
    }

    /// Translates the texts in one request, retrying on network and server errors. Returns the texts the
    /// answer left out. Errors the user has to fix (API key, model) are thrown at once.
    private func translateBatch(_ texts: [String], options: FileTranslationOptions) async throws -> [String] {
        let glossary = Glossary.match(options.terms, texts.map(TaggedText.stripTags).joined(separator: "\n"))
        let system = SegmentBatcher.buildSystemPrompt(target: options.target, profile: options.profile, glossary: glossary,
                                                      documentHint: document.promptHint, extraInstructions: options.extraInstructions)
        let user = SegmentBatcher.buildUserMessage(texts)
        var attempt = 0
        while true {
            attempt += 1
            do {
                let result = try await call(system, user)
                let parsed = SegmentBatcher.parseResponse(result.text, count: texts.count, complete: result.finishReason != "length")
                var missing: [String] = []
                locked {
                    for (index, text) in texts.enumerated() {
                        if let translation = parsed[index], !translation.isEmpty {
                            done[text] = translation
                        } else {
                            missing.append(text)
                        }
                    }
                }
                if !missing.isEmpty {
                    Log.info("文件翻译：\(texts.count) 段中有 \(missing.count) 段没有返回（finish_reason=\(result.finishReason ?? "nil")）")
                }
                return missing
            } catch let error as TranslationError where !error.needsSettings && attempt < FileTranslationJob.maxAttempts {
                Log.info("文件翻译请求失败，第 \(attempt) 次重试：\(error.message)")
                try await Task.sleep(nanoseconds: UInt64(max(0, retryDelay(attempt)) * 1_000_000_000))
            }
        }
    }
}

private final class ProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int

    init(done: Int) {
        self.done = done
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func add(_ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        done += count
        return done
    }
}

private final class UntranslatedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var texts = Set<String>()

    func insert(_ text: String) {
        lock.lock()
        texts.insert(text)
        lock.unlock()
    }

    func contains(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return texts.contains(text)
    }
}
