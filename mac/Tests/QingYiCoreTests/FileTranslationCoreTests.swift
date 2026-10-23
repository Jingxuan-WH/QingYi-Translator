import Foundation
import Testing
@testable import QingYiCore

struct TaggedTextTests {
    @Test func mainFormatStaysUntaggedAndOthersGetOneNumberEach() {
        let tagged = TaggedText.build([
            .of("The ", 0), .of("power flow", 1), .of(" is solved by ", 0), .of("Newton", 2), .of(" and ", 0), .of("Raphson", 2), .object(0), .of(".", 0),
        ])
        #expect(tagged.baseStyle == 0)
        #expect(tagged.text == "The <1>power flow</1> is solved by <2>Newton</2> and <2>Raphson</2><3/>.")
    }

    @Test func spacesStayOutsideTheTags() {
        #expect(TaggedText.build([.of("plain text here", 0), .of(" bold ", 1), .of("x", 0)]).text == "plain text here <1>bold</1> x")
    }

    @Test func parseRestoresFormatsInTheTranslatedOrder() {
        let tagged = TaggedText.build([.of("the ", 0), .of("red", 1), .of(" car is fast", 0)])
        #expect(tagged.parse("la voiture <1>rouge</1> est rapide") == [.of("la voiture ", 0), .of("rouge", 1), .of(" est rapide", 0)])
    }

    @Test func parseToleratesBrokenAndUnknownTags() {
        let tagged = TaggedText.build([.of("aaaa ", 0), .of("bb", 1), .object(0), .of(" cc", 0)])
        #expect(tagged.text == "aaaa <1>bb</1><2/> cc")
        #expect(tagged.parse("x <1>y <7> z<2></2>") == [.of("x ", 0), .of("y <7> z", 1), .object(0)])
        #expect(tagged.parse("pl</1>ain") == [.of("plain", 0)])
    }

    @Test func stripTagsAndWhitespacePieces() {
        #expect(TaggedText.stripTags("a <1>b</1><2/> c") == "a b c")
        let tagged = TaggedText.build([.of("one", 0), .of(" ", 1), .of("two", 0)])
        #expect(tagged.text == "one two")
        #expect(!tagged.hasTags)
    }
}

struct SegmentBatcherTests {
    @Test func planRespectsCharacterAndCountLimits() {
        #expect(SegmentBatcher.plan([500, 500, 2000, 3000, 10, 10], length: { $0 }, maxChars: 2400, maxItems: 3) == [[500, 500], [2000], [3000], [10, 10]])
        #expect(SegmentBatcher.plan(Array(repeating: 1, count: 10), length: { $0 }, maxItems: 3).count == 4)
    }

    @Test func messageAndResponseRoundTrip() {
        #expect(SegmentBatcher.buildUserMessage(["Hello <1>world</1>", "Second"]) == "<seg id=\"1\">Hello <1>world</1></seg>\n<seg id=\"2\">Second</seg>\n")
        let parsed = SegmentBatcher.parseResponse("Sure:\n<seg id=\"2\"> 第二 </seg>\n<seg id='1'>你好<1>世界</1></seg>", count: 2)
        #expect(parsed[0] == "你好<1>世界</1>")
        #expect(parsed[1] == "第二")
        #expect(SegmentBatcher.parseResponse("<seg id=\"1\">a</seg><seg id=\"3\">c</seg><seg id=\"9\">x</seg>", count: 3).keys.sorted() == [0, 2])
    }

    @Test func singleSegmentMayComeBackBare() {
        #expect(SegmentBatcher.parseResponse("你好", count: 1)[0] == "你好")
        #expect(SegmentBatcher.parseResponse("<seg id=\"1\">cut o", count: 1, complete: false).isEmpty)
        #expect(SegmentBatcher.parseResponse("bare", count: 2).isEmpty)
    }

    @Test func promptCarriesFieldStyleAndGlossary() {
        let profile = DomainProfile(domain: "电气工程", subdomain: "电力系统", style: "学术论文", terms: [])
        let prompt = SegmentBatcher.buildSystemPrompt(target: Languages.simplifiedChinese, profile: profile,
                                                      glossary: [GlossaryEntry(source: "power flow", target: "潮流")],
                                                      documentHint: "Subtitles hint.", extraInstructions: "Be formal.")
        #expect(prompt.contains("into Simplified Chinese"))
        #expect(prompt.contains("Field: 电气工程 · 电力系统"))
        #expect(prompt.contains("Style of the document: 学术论文"))
        #expect(prompt.contains("- power flow = 潮流"))
        #expect(prompt.contains("8. Subtitles hint."))
        #expect(prompt.hasSuffix("Additional requirements from the user:\nBe formal.\n"))
    }
}

struct DomainAnalyzerTests {
    @Test func sampleMarksFormatChangesInsideWords() {
        let formula = DocumentSegment(id: 0, text: TaggedText.build([.of("V", 0), .of("cell", 1), .of(" = E", 0), .of("Nernst", 1)]))
        let chinese = DocumentSegment(id: 1, text: TaggedText.build([.of("电堆性能的", 0), .of("退化", 1), .of("很慢。", 0)]))
        let sample = DomainAnalyzer.buildSample([formula, chinese])
        #expect(sample.contains("V_cell = E_Nernst"))
        #expect(sample.contains("电堆性能的退化很慢。"))
        #expect(DomainAnalyzer.buildSystemPrompt(target: Languages.simplifiedChinese, answerLanguage: Languages.simplifiedChinese).contains("V_cell"))
    }

    @Test func parsesFencedJsonWithChatter() throws {
        let profile = try #require(DomainAnalyzer.parse("""
            Here is the analysis:
            ```json
            {"domain": "电气工程", "subdomain": "电力系统", "style": "学术论文，正式",
             "terms": [{"source": "power flow", "target": "潮流"}, {"source": "MATLAB", "target": "MATLAB"}, {"source": "droop control", "target": "下垂控制"},]}
            ```
            """))
        #expect(profile.domainText == "电气工程 · 电力系统")
        #expect(profile.style == "学术论文，正式")
        // Terms that stay unchanged are left out.
        #expect(profile.terms.map(\.source) == ["power flow", "droop control"])
    }

    @Test func parsesOtherShapes() throws {
        let map = try #require(DomainAnalyzer.parse(#"{"Domain":"Law","terms":{"tort":"侵权","estoppel":"禁反言"}}"#))
        #expect(map.domainText == "Law")
        #expect(map.terms.count == 2)
        let pairs = try #require(DomainAnalyzer.parse(#"{"field":"Medicine","glossary":[["stent","支架"],{"term":"angioplasty","translation":"血管成形术"}]}"#))
        #expect(pairs.terms.map(\.source) == ["stent", "angioplasty"])
        #expect(DomainAnalyzer.parse("I cannot help with that.") == nil)
        #expect(DomainAnalyzer.parse("{not json") == nil)
    }

    @Test func userGlossaryWinsOverDetectedTerms() {
        let merged = DomainAnalyzer.mergeTerms(
            [GlossaryEntry(source: "power flow", target: "潮流"), GlossaryEntry(source: "电网", target: "power grid")],
            [GlossaryEntry(source: "Power Flow", target: "功率流"), GlossaryEntry(source: "power grid", target: "电力网"),
             GlossaryEntry(source: "inverter", target: "逆变器")])
        #expect(merged == [ReviewTerm(source: "power flow", target: "潮流", fromGlossary: true),
                           ReviewTerm(source: "电网", target: "power grid", fromGlossary: true),
                           ReviewTerm(source: "inverter", target: "逆变器", fromGlossary: false)])
    }

    @Test func sampleCoversTitleAbstractHeadingsAndSpreadOutParagraphs() {
        func segment(_ id: Int, _ text: String, _ role: SegmentRole = .body) -> DocumentSegment {
            DocumentSegment(id: id, text: TaggedText.build([.of(text, 0)]), role: role)
        }
        var segments = [segment(0, "A Study of Power Flow", .title), segment(1, "Abstract", .heading),
                        segment(2, "We study the power flow problem in distribution grids."), segment(3, "1. Introduction", .heading)]
        for i in 4..<200 {
            segments.append(segment(i, "Paragraph \(i) " + String(repeating: "x", count: 300)))
        }
        segments.append(segment(200, "References", .heading))
        let reference = segment(201, "[1] A. Author, Old paper.")
        reference.isReference = true
        segments.append(reference)

        let sample = DomainAnalyzer.buildSample(segments, maxChars: 6000)
        #expect(sample.count <= 6000)
        #expect(sample.hasPrefix("[Title] A Study of Power Flow\n[Abstract] We study the power flow problem"))
        #expect(sample.contains("- 1. Introduction"))
        #expect(sample.contains("Paragraph 4 "))
        #expect(!sample.contains("Old paper"))
        #expect(segments[80..<120].contains { sample.contains(String($0.plainText.prefix(14))) })
        #expect(segments[150..<200].contains { sample.contains(String($0.plainText.prefix(14))) })
    }

    @Test func referenceHeadingsAndOutputPaths() throws {
        for text in ["References", "REFERENCES", "7. References", "VII. REFERENCES", "参考文献"] {
            #expect(ReferenceSection.isHeading(text), "\(text)")
        }
        #expect(!ReferenceSection.isHeading("References to earlier work show that"))
        #expect(!ReferenceSection.isHeading("Introduction"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("paper.pdf")
        try Data("x".utf8).write(to: source)
        #expect(OutputPaths.url(for: source, target: Languages.simplifiedChinese).lastPathComponent == "paper.zh-Hans.pdf")
        try Data("x".utf8).write(to: directory.appendingPathComponent("paper.zh-Hans.pdf"))
        #expect(OutputPaths.url(for: source, target: Languages.simplifiedChinese).lastPathComponent == "paper.zh-Hans (2).pdf")
        #expect(OutputPaths.url(for: source, target: Languages.english, variant: "bilingual").lastPathComponent == "paper.en.bilingual.pdf")
        try FileManager.default.removeItem(at: directory)
    }
}

/// A document whose segments are given directly; save records what it was asked to write.
final class FakeDocument: TranslatableDocument {
    private(set) var saved: [Int: String]?

    init(_ texts: [String]) {
        super.init(sourceURL: FileManager.default.temporaryDirectory.appendingPathComponent("qy-fake-\(UUID().uuidString).txt"))
        for text in texts {
            addSegment(text)
        }
    }

    override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        saved = translations
    }
}

/// A model that upper-cases each segment, with a hook to misbehave.
final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var systemPrompts: [String] = []
    /// Call number and user message → answer; nil answers normally.
    var override: ((Int, String) throws -> String?)?

    private func record(_ system: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        systemPrompts.append(system)
        return calls
    }

    var call: CompletionCall {
        { [self] system, user in
            let number = record(system)
            if let answer = try override?(number, user) {
                return TranslationResult(text: answer, finishReason: "stop")
            }
            let pattern = try NSRegularExpression(pattern: "<seg id=\"(\\d+)\">(.*?)</seg>", options: [.dotMatchesLineSeparators])
            let source = user as NSString
            var answer = ""
            for match in pattern.matches(in: user, range: NSRange(location: 0, length: source.length)) {
                answer += "<seg id=\"\(source.substring(with: match.range(at: 1)))\">\(source.substring(with: match.range(at: 2)).uppercased())</seg>"
            }
            return TranslationResult(text: answer, finishReason: "stop")
        }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var reports: [FileTranslationProgress] = []

    func add(_ report: FileTranslationProgress) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }
}

struct FileTranslationJobTests {
    private func options(_ terms: [GlossaryEntry] = []) -> FileTranslationOptions {
        FileTranslationOptions(target: Languages.simplifiedChinese, profile: DomainProfile(domain: "Law", subdomain: "", style: "Contract", terms: []), terms: terms)
    }

    @Test func translatesEverySegmentOnceAndReportsProgress() async throws {
        let document = FakeDocument(["alpha", "beta", "alpha", "gamma"])
        let model = FakeModel()
        let log = ProgressLog()
        let result = try await FileTranslationJob(document: document, call: model.call).translate(options: options()) { log.add($0) }
        #expect(document.saved?.sorted { $0.key < $1.key }.map(\.value) == ["ALPHA", "BETA", "ALPHA", "GAMMA"])
        #expect(model.calls == 1) // one batch, the repeated "alpha" sent once
        #expect(log.reports.last == FileTranslationProgress(done: 4, total: 4))
        #expect(result.untranslated == 0)
        #expect(model.systemPrompts[0].contains("Field: Law"))
    }

    @Test func onlyMatchingTermsAreSentWithEachBatch() async throws {
        let model = FakeModel()
        _ = try await FileTranslationJob(document: FakeDocument(["The tort of negligence."]), call: model.call)
            .translate(options: options([GlossaryEntry(source: "tort", target: "侵权"), GlossaryEntry(source: "estoppel", target: "禁反言")]))
        #expect(model.systemPrompts[0].contains("- tort = 侵权"))
        #expect(!model.systemPrompts[0].contains("estoppel"))
    }

    @Test func retriesNetworkErrorsAndSegmentsTheModelSkipped() async throws {
        let document = FakeDocument(["one", "two", "three"])
        let model = FakeModel()
        model.override = { call, _ in
            switch call {
            case 1: throw TranslationError("busy")
            case 2: return "<seg id=\"1\">ONE</seg><seg id=\"3\">THREE</seg>" // "two" left out
            default: return nil
            }
        }
        let job = FileTranslationJob(document: document, call: model.call)
        job.retryDelay = { _ in 0 }
        let result = try await job.translate(options: options())
        #expect(document.saved?.sorted { $0.key < $1.key }.map(\.value) == ["ONE", "TWO", "THREE"])
        #expect(model.calls == 3)
        #expect(result.untranslated == 0)
    }

    @Test func settingsErrorsStopAtOnceAndARetryResumes() async throws {
        let texts = (0..<80).map { "segment \($0) " + String(repeating: "x", count: 100) }
        let document = FakeDocument(texts)
        let model = FakeModel()
        var broken = true
        model.override = { call, _ in
            if broken && call == 2 {
                throw TranslationError("bad key", needsSettings: true)
            }
            return nil
        }
        let job = FileTranslationJob(document: document, call: model.call, maxConcurrency: 1)
        job.retryDelay = { _ in 0 }
        do {
            _ = try await job.translate(options: options())
            Issue.record("expected an error")
        } catch let error as TranslationError {
            #expect(error.needsSettings)
        }
        #expect(model.calls == 2)

        broken = false
        let before = model.calls
        let log = ProgressLog()
        _ = try await job.translate(options: options()) { log.add($0) }
        #expect(document.saved?.count == 80)
        // The first batch was kept; only the rest was sent again.
        #expect((log.reports.first?.done ?? 0) > 0)
        #expect(model.calls - before == SegmentBatcher.plan(texts, length: { $0.utf16.count }).count - 1)
    }

    @Test func unanswerableSegmentsKeepTheirOriginal() async throws {
        let document = FakeDocument(["keep me", "fine"])
        let model = FakeModel()
        model.override = { _, user in
            if user.contains("keep me") && !user.contains("fine") { return "" }
            return user.contains("fine") ? "<seg id=\"2\">FINE</seg>" : nil
        }
        let result = try await FileTranslationJob(document: document, call: model.call).translate(options: options())
        #expect(result.untranslated == 1)
        #expect(document.saved?[0] == nil)
        #expect(document.saved?[1] == "FINE")
    }

    @Test func referencesAreSkippedWhenAsked() async throws {
        let document = FakeDocument(["Body text"])
        document.addSegment("[1] A. Author, Title.").isReference = true
        let model = FakeModel()
        var skip = options()
        skip.skipReferences = true
        _ = try await FileTranslationJob(document: document, call: model.call).translate(options: skip)
        #expect(document.saved?.keys.sorted() == [0])
        skip.skipReferences = false
        _ = try await FileTranslationJob(document: document, call: model.call).translate(options: skip)
        #expect(document.saved?.keys.sorted() == [0, 1])
    }

    @Test func analyzeReadsTheProfile() async throws {
        let model = FakeModel()
        model.override = { _, _ in #"{"domain":"法学","subdomain":"侵权法","style":"教材","terms":[{"source":"duty of care","target":"注意义务"}]}"# }
        let profile = try await FileTranslationJob(document: FakeDocument(["Contract law basics", "The tort of negligence requires a duty of care."]),
                                                   call: model.call)
            .analyze(target: Languages.simplifiedChinese, answerLanguage: Languages.simplifiedChinese)
        #expect(profile?.domainText == "法学 · 侵权法")
        #expect(profile?.terms.first?.target == "注意义务")
        #expect(model.systemPrompts[0].contains("into Simplified Chinese"))
    }
}
