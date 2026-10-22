import Foundation
import Testing
import ZIPFoundation
@testable import QingYiCore

private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

/// Saves with a translation made by `translate` and returns the written text.
private func save(_ document: TranslatableDocument, _ translate: (String) -> String) throws -> String {
    var translations: [Int: String] = [:]
    for segment in document.segments {
        translations[segment.id] = translate(segment.text.text)
    }
    let output = OutputPaths.url(for: document.sourceURL, target: Languages.simplifiedChinese)
    try document.save(to: output, translations: translations, options: DocumentSaveOptions(target: Languages.simplifiedChinese))
    return String(decoding: try Data(contentsOf: output), as: UTF8.self)
}

struct TextDocumentTests {
    @Test func plainTextKeepsParagraphsAndUrls() throws {
        let document = try PlainTextDocument(url: temporaryFile("notes.txt", Data("Meeting notes\n\n  First point, see https://example.com/a?b=1.\nIt continues here.\n\n\n2024\n".utf8)))
        #expect(document.segments.map(\.text.text) == ["Meeting notes", "First point, see <1/>.\nIt continues here."])
        #expect(document.segments[0].role == .title)
        let output = try save(document) {
            $0.replacingOccurrences(of: "Meeting notes", with: "会议记录")
                .replacingOccurrences(of: "First point, see <1/>.\nIt continues here.", with: "第一点，见<1/>。这里继续。")
        }
        #expect(output == "会议记录\n\n  第一点，见https://example.com/a?b=1。这里继续。\n\n\n2024\n")
    }

    @Test func plainTextInGb18030ComesBackAsUtf8WithTheSameLineBreaks() throws {
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try #require("你好，世界。\r\n\r\n第二段。\r\n".data(using: String.Encoding(rawValue: gb18030)))
        let url = try temporaryFile("gbk.txt", data)
        let document = try PlainTextDocument(url: url)
        #expect(document.segments.map(\.text.text) == ["你好，世界。", "第二段。"])
        let output = OutputPaths.url(for: url, target: Languages.english)
        try document.save(to: output, translations: [0: "Hello, world.", 1: "Second\nparagraph."], options: DocumentSaveOptions(target: Languages.english))
        let bytes = try Data(contentsOf: output)
        #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self) == "Hello, world.\r\n\r\nSecond\r\nparagraph.\r\n")
    }

    @Test func markdownTranslatesTextButNotCodeOrSyntax() throws {
        let source = """
            ---
            title: Guide
            ---
            # Getting started

            Install with `npm install x` and read [the docs](https://example.com/docs "Docs") or **this part**.

            - First item
              continues here
            1. Numbered $x^2$ item

            ```bash
            echo "do not translate"
            ```

            | Name | Value |
            |------|------:|
            | Speed | 42 |

            $$
            E = mc^2
            $$

            > Quoted text
            <!-- a comment -->
            Setext title
            ============
            """
        let document = try MarkdownDocument(url: temporaryFile("guide.md", Data(source.utf8)))
        #expect(document.segments.map(\.text.text) == [
            "Getting started",
            "Install with <1/> and read [the docs]<2/> or **this part**.",
            "First item\ncontinues here",
            "Numbered <1/> item",
            "Name", "Value", "Speed",
            "Quoted text",
            "Setext title",
        ])
        #expect(document.segments[0].role == .title)
        #expect(document.segments[8].role == .heading)
        let map = [
            "Getting started": "入门",
            "Install with <1/> and read [the docs]<2/> or **this part**.": "用 <1/> 安装，并阅读[文档]<2/>或**这一部分**。",
            "First item\ncontinues here": "第一项\n继续",
            "Numbered <1/> item": "编号 <1/> 项",
            "Name": "名称", "Value": "值", "Speed": "速度|快",
            "Quoted text": "引用文字",
            "Setext title": "标题",
        ]
        let output = try save(document) { map[$0]! }
        #expect(output == """
            ---
            title: Guide
            ---
            # 入门

            用 `npm install x` 安装，并阅读[文档](https://example.com/docs "Docs")或**这一部分**。

            - 第一项
              继续
            1. 编号 $x^2$ 项

            ```bash
            echo "do not translate"
            ```

            | 名称 | 值 |
            |------|------:|
            | 速度\\|快 | 42 |

            $$
            E = mc^2
            $$

            > 引用文字
            <!-- a comment -->
            标题
            ============
            """)
    }

    @Test func subtitlesKeepNumbersTimingsAndTags() throws {
        let source = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello there,</i>\r\nmy friend.\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n♪ ♪\r\n\r\n3\r\n00:00:06,000 --> 00:00:08,000\r\nHow are you?\r\n"
        let document = try SubtitleDocument(url: temporaryFile("movie.srt", Data(source.utf8)))
        #expect(document.segments.map(\.text.text) == ["<1/>Hello there,<2/>\nmy friend.", "How are you?"])
        #expect(document.promptHint?.contains("subtitle") == true)
        let output = try save(document) { $0.hasPrefix("<1/>") ? "<1/>你好，<2/>\n\n我的朋友。" : "你好吗？" }
        #expect(output == "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>你好，</i>\r\n我的朋友。\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n♪ ♪\r\n\r\n3\r\n00:00:06,000 --> 00:00:08,000\r\n你好吗？\r\n")
    }

    @Test func missingPlaceholdersAreAppendedRatherThanLost() throws {
        let document = try PlainTextDocument(url: temporaryFile("u.txt", Data("Visit https://example.com today".utf8)))
        #expect(try save(document) { _ in "今天访问" } == "今天访问 https://example.com")
    }
}

/// Builds small Office files for the tests.
enum OfficeFiles {
    static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let x = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    static func write(_ ext: String, contentTypes: String, parts: [(String, String)]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample." + ext)
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        func add(_ name: String, _ data: Data) throws {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        try add("[Content_Types].xml", Data((header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>"# + contentTypes + "</Types>").utf8))
        try add("_rels/.rels", Data((header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>"#).utf8))
        for (name, xml) in parts {
            try add(name, Data((header + xml).utf8))
        }
        try add("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        return url
    }

    static func read(_ url: URL, _ part: String) throws -> XMLElement {
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        let entry = try #require(archive[part])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let document = try XMLDocument(data: data)
        return try #require(document.rootElement())
    }

    static func override(_ part: String, _ type: String) -> String { #"<Override PartName="/"# + part + #"" ContentType=""# + type + #""/>"# }
}

struct OpenXmlTests {
    private let wml = "application/vnd.openxmlformats-officedocument.wordprocessingml."

    private func wordSample() throws -> URL {
        try OfficeFiles.write("docx",
            contentTypes: OfficeFiles.override("word/document.xml", wml + "document.main+xml") + OfficeFiles.override("word/styles.xml", wml + "styles+xml")
                + OfficeFiles.override("word/footnotes.xml", wml + "footnotes+xml") + OfficeFiles.override("word/header1.xml", wml + "header+xml"),
            parts: [
                ("word/document.xml", """
                <w:document xmlns:w="\(OfficeFiles.w)" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\
                <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Power Flow Study</w:t></w:r></w:p>\
                <w:p><w:r><w:t xml:space="preserve">The </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>New</w:t></w:r><w:r><w:rPr><w:b/><w:lang w:val="en-US"/></w:rPr><w:t>ton</w:t></w:r><w:r><w:rPr><w:lang w:val="en-US"/></w:rPr><w:t xml:space="preserve"> method </w:t></w:r><w:hyperlink r:id="rId9"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>converges</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> fast</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:t>.</w:t></w:r></w:p>\
                <w:p><w:r><w:t xml:space="preserve">Energy is </w:t></w:r><m:oMath><m:r><m:t>E=mc^2</m:t></m:r></m:oMath><w:r><w:t xml:space="preserve"> as shown in </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> REF _Ref1 \\h </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Figure 1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t>.</w:t></w:r></w:p>\
                <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Voltage</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>12345</w:t></w:r></w:p></w:tc></w:tr></w:tbl>\
                <w:p><w:r><w:drawing><w:txbxContent><w:p><w:r><w:t>Text box words</w:t></w:r></w:p></w:txbxContent></w:drawing></w:r></w:p>\
                <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>References</w:t></w:r></w:p>\
                <w:p><w:r><w:t>[1] J. Smith, Power systems.</w:t></w:r></w:p>\
                </w:body></w:document>
                """),
                ("word/styles.xml", #"<w:styles xmlns:w=""# + OfficeFiles.w + #""><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style></w:styles>"#),
                ("word/footnotes.xml", #"<w:footnotes xmlns:w=""# + OfficeFiles.w + #""><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> See the appendix.</w:t></w:r></w:p></w:footnote></w:footnotes>"#),
                ("word/header1.xml", #"<w:hdr xmlns:w=""# + OfficeFiles.w + #""><w:p><w:r><w:t>Confidential draft</w:t></w:r></w:p></w:hdr>"#),
            ])
    }

    @Test func wordSegmentsKeepFormattingAsTags() throws {
        let document = try WordDocument(url: wordSample())
        #expect(document.segments.map(\.text.text) == [
            "Power Flow Study",
            "The <1>Newton</1> method <2>converges</2> fast<3/>.",
            "Energy is <1/> as shown in <2/>.",
            "Voltage",
            "Text box words",
            "References",
            "[1] J. Smith, Power systems.",
            "Confidential draft",
            "<1/> See the appendix.",
        ])
        #expect(document.segments[0].role == .title)
        #expect(document.segments[5].role == .heading)
        #expect(document.segments[6].isReference)
        #expect(!document.segments[4].isReference)
    }

    @Test func wordTranslationIsWrittenIntoTheRunsInItsOwnOrder() throws {
        let url = try wordSample()
        let document = try WordDocument(url: url)
        let output = url.deletingLastPathComponent().appendingPathComponent("sample.zh-Hans.docx")
        try document.save(to: output, translations: [
            0: "潮流研究",
            1: "<2>收敛</2>很快<3/>，<1>牛顿</1>法。",
            2: "如<2/>所示，能量为<1/>。",
            4: "文本框文字",
            7: "机密草稿",
            8: "<1/> 见附录。",
        ], options: DocumentSaveOptions(target: Languages.simplifiedChinese))

        let w = { QName(OfficeFiles.w, $0) }
        let root = try OfficeFiles.read(output, "word/document.xml")
        let body = try #require(root.child(w("body")))
        let paragraphs = body.children(w("p"))
        #expect(paragraphs[0].stringValue == "潮流研究")

        // Order follows the translation; bold, the hyperlink and the footnote mark survive.
        let second = paragraphs[1]
        #expect(second.descendants(w("t")).map { $0.stringValue ?? "" }.joined() == "收敛很快，牛顿法。")
        #expect(second.child(w("hyperlink"))?.stringValue == "收敛")
        #expect(second.child(w("hyperlink"))?.attributes?.first { $0.localName == "id" }?.stringValue == "rId9")
        let bold = second.children(w("r")).filter { $0.child(w("rPr"))?.child(w("b")) != nil }
        #expect(bold.map { $0.stringValue ?? "" } == ["牛顿"])
        let order = second.childElements.map { element -> String in
            if element.isNamed(w("hyperlink")) { return "link" }
            if !element.descendants(w("footnoteReference")).isEmpty { return "note" }
            return element.stringValue ?? ""
        }
        #expect(order == ["link", "很快", "note", "，", "牛顿", "法。"])

        // The formula moved after the text it now follows; the field (Figure 1) is untouched.
        let parts = paragraphs[2].childElements.map { element -> String in
            if element.localName == "oMath" { return "math" }
            if let field = element.child(w("fldChar")) { return field.attributeValue("fldCharType", ns: OfficeFiles.w) ?? "" }
            if element.child(w("instrText")) != nil { return "instr" }
            return element.stringValue ?? ""
        }
        #expect(parts == ["如", "begin", "instr", "separate", "Figure 1", "end", "所示，能量为", "math", "。"])

        #expect(paragraphs[3].descendants(w("txbxContent")).first?.stringValue == "文本框文字")
        #expect(body.descendants(w("tc")).last?.stringValue == "12345")
        #expect(paragraphs[5].stringValue == "[1] J. Smith, Power systems.") // not translated
        #expect(try OfficeFiles.read(output, "word/header1.xml").stringValue == "机密草稿")
        let note = try #require(try OfficeFiles.read(output, "word/footnotes.xml").children(w("footnote")).last)
        #expect(!note.descendants(w("footnoteRef")).isEmpty)
        #expect(note.stringValue == " 见附录。")
        #expect(note.descendants(w("t")).first?.attribute(forName: "xml:space")?.stringValue == "preserve")

        // Everything else is copied unchanged.
        let archive = try Archive(url: output, accessMode: .read, pathEncoding: nil)
        var image = Data()
        _ = try archive.extract(try #require(archive["word/media/image1.png"])) { image.append($0) }
        #expect(Array(image) == [0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    }

    @Test func untranslatedParagraphsStayTheSame() throws {
        let url = try wordSample()
        let document = try WordDocument(url: url)
        let output = url.deletingLastPathComponent().appendingPathComponent("sample.out.docx")
        try document.save(to: output, translations: [:], options: DocumentSaveOptions(target: Languages.english))
        let text = { (file: URL) in try OfficeFiles.read(file, "word/document.xml").descendants(QName(OfficeFiles.w, "t")).map { $0.stringValue ?? "" }.joined() }
        #expect(try text(url) == text(output))
    }

    @Test func powerPointKeepsRunsAndShrinksTextThatGrew() throws {
        let pml = "application/vnd.openxmlformats-officedocument.presentationml."
        func shape(_ type: String, _ paragraphs: String) -> String {
            "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"s\"/><p:cNvSpPr/><p:nvPr>" + (type.isEmpty ? "" : "<p:ph type=\"\(type)\"/>")
                + "</p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>" + paragraphs + "</p:txBody></p:sp>"
        }
        func slide(_ shapes: String) -> String {
            "<p:sld xmlns:a=\"\(OfficeFiles.a)\" xmlns:p=\"\(OfficeFiles.p)\"><p:cSld><p:spTree>" + shapes + "</p:spTree></p:cSld></p:sld>"
        }
        let url = try OfficeFiles.write("pptx",
            contentTypes: OfficeFiles.override("ppt/slides/slide1.xml", pml + "slide+xml") + OfficeFiles.override("ppt/slides/slide2.xml", pml + "slide+xml")
                + OfficeFiles.override("ppt/notesSlides/notesSlide1.xml", pml + "notesSlide+xml"),
            parts: [
                ("ppt/slides/slide1.xml", slide(shape("ctrTitle", #"<a:p><a:r><a:rPr lang="en-US"/><a:t>Results</a:t></a:r></a:p>"#)
                    + shape("", #"<a:p><a:r><a:rPr lang="en-US" b="1"/><a:t>Revenue</a:t></a:r><a:r><a:rPr lang="en-US"/><a:t xml:space="preserve"> grew</a:t></a:r><a:br><a:rPr lang="en-US"/></a:br><a:r><a:rPr lang="en-US" dirty="0"/><a:t>in Q3</a:t></a:r><a:endParaRPr lang="en-US"/></a:p>"#))),
                ("ppt/slides/slide2.xml", slide(#"<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Cost</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>"#)),
                ("ppt/notesSlides/notesSlide1.xml", "<p:notes xmlns:a=\"\(OfficeFiles.a)\" xmlns:p=\"\(OfficeFiles.p)\"><p:cSld><p:spTree>" + shape("body", "<a:p><a:r><a:t>Speak slowly.</a:t></a:r></a:p>") + "</p:spTree></p:cSld></p:notes>"),
            ])
        let document = try PresentationDocument(url: url)
        #expect(document.segments.map(\.text.text) == ["Results", "<1>Revenue</1> grew<2/>in Q3", "Cost", "Speak slowly."])
        #expect(document.segments[0].role == .title)

        let output = url.deletingLastPathComponent().appendingPathComponent("sample.en.pptx")
        try document.save(to: output, translations: [
            0: "结果",
            1: "<1>Revenue from all of our regional product lines</1> grew substantially and steadily<2/>during the third quarter of the year",
            2: "成本",
            3: "慢慢讲。",
        ], options: DocumentSaveOptions(target: Languages.english))

        let a = { QName(OfficeFiles.a, $0) }
        let slide1 = try OfficeFiles.read(output, "ppt/slides/slide1.xml")
        let bodies = slide1.descendants(QName(OfficeFiles.p, "txBody"))
        let body = try #require(bodies.first { ($0.stringValue ?? "").contains("Revenue") })
        let runs = body.descendants(a("r"))
        #expect(runs[0].child(a("rPr"))?.attributeValue("b") == "1")
        #expect(runs[0].stringValue == "Revenue from all of our regional product lines")
        #expect(body.descendants(a("br")).count == 1)
        let autofit = try #require(body.child(a("bodyPr"))?.child(a("normAutofit")))
        let scale = Int(autofit.attributeValue("fontScale") ?? "") ?? 0
        #expect(scale >= 25000 && scale <= 70000)
        // The title got shorter: no autofit.
        #expect(bodies[0].child(a("bodyPr"))?.child(a("normAutofit")) == nil)
        #expect(try OfficeFiles.read(output, "ppt/slides/slide2.xml").descendants(a("t")).first?.stringValue == "成本")
        #expect(try OfficeFiles.read(output, "ppt/notesSlides/notesSlide1.xml").descendants(a("t")).first?.stringValue == "慢慢讲。")
    }

    @Test func excelTranslatesTextCellsButNotFormulasOrNumbers() throws {
        let sml = "application/vnd.openxmlformats-officedocument.spreadsheetml."
        let url = try OfficeFiles.write("xlsx",
            contentTypes: OfficeFiles.override("xl/sharedStrings.xml", sml + "sharedStrings+xml") + OfficeFiles.override("xl/worksheets/sheet1.xml", sml + "worksheet+xml"),
            parts: [
                ("xl/sharedStrings.xml", #"<sst xmlns=""# + OfficeFiles.x + #"" count="3" uniqueCount="3"><si><t>Revenue</t></si><si><r><rPr><b/></rPr><t>Net</t></r><r><t xml:space="preserve"> income</t></r></si><si><t>2024-Q3</t></si></sst>"#),
                ("xl/worksheets/sheet1.xml", #"<worksheet xmlns=""# + OfficeFiles.x + #""><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><f>SUM(C1:C2)</f><v>3</v></c><c r="C1" t="str"><f>"total"&amp;"s"</f><v>totals</v></c><c r="D1" t="inlineStr"><is><t>Inline note</t></is></c></row></sheetData></worksheet>"#),
            ])
        let document = try SpreadsheetDocument(url: url)
        // "2024-Q3" has no words to translate.
        #expect(document.segments.map(\.text.text) == ["Revenue", "<1>Net</1> income", "Inline note"])
        let output = url.deletingLastPathComponent().appendingPathComponent("sample.zh-Hans.xlsx")
        try document.save(to: output, translations: [0: "收入", 1: "<1>净</1>收入", 2: "内联备注"], options: DocumentSaveOptions(target: Languages.simplifiedChinese))

        let x = { QName(OfficeFiles.x, $0) }
        let strings = try OfficeFiles.read(output, "xl/sharedStrings.xml").children(x("si"))
        #expect(strings[0].stringValue == "收入")
        #expect(strings[1].children(x("r")).first?.stringValue == "净")
        #expect(strings[1].children(x("r")).first?.child(x("rPr"))?.child(x("b")) != nil)
        #expect(strings[2].stringValue == "2024-Q3")
        let sheet = try OfficeFiles.read(output, "xl/worksheets/sheet1.xml")
        #expect(sheet.descendants(x("f")).first?.stringValue == "SUM(C1:C2)")
        #expect(sheet.descendants(x("c"))[2].child(x("v"))?.stringValue == "totals")
        #expect(sheet.descendants(x("is")).first?.stringValue == "内联备注")
    }

    @Test func encryptedOrLegacyFilesGiveAClearError() throws {
        let url = try temporaryFile("locked.docx", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0]))
        #expect(throws: DocumentError.self) { try DocumentLoader.open(url) }
        do {
            _ = try DocumentLoader.open(url.deletingPathExtension().appendingPathExtension("doc"))
            Issue.record("expected an error")
        } catch let error as DocumentError {
            #expect(error.message.contains(".docx"))
        }
    }
}
