import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import QingYiCore

/// Characters laid out like a typesetter would, for testing the layout analysis without a PDF
/// (the same pages as tests/Translator.Tests/PdfTests.cs on Windows).
enum Glyphs {
    static func isCjk(_ c: Character) -> Bool { (c.unicodeScalars.first?.value ?? 0) >= 0x2E80 }

    static func width(_ text: String, _ size: Double) -> Double {
        text.reduce(0) { $0 + ($1 == " " ? 0.25 * size : isCjk($1) ? size : 0.5 * size) }
    }

    static func line(_ text: String, _ x: Double, _ baseline: Double, _ size: Double = 10, _ font: String = "Times-Roman") -> [PdfGlyph] {
        var glyphs: [PdfGlyph] = []
        var x = x
        for c in text {
            let w = c == " " ? 0.25 * size : isCjk(c) ? size : 0.5 * size
            if c != " " {
                glyphs.append(PdfGlyph(String(c), x, baseline - 0.2 * size, x + w, baseline + 0.7 * size, size, font))
            }
            x += w
        }
        return glyphs
    }

    /// Wraps words into lines between x0 and x1, the first line indented.
    static func paragraph(_ text: String, _ x0: Double, _ x1: Double, _ baseline: Double, _ pitch: Double, indent: Double = 10, size: Double = 10) -> [PdfGlyph] {
        var glyphs: [PdfGlyph] = []
        var current = ""
        var start = x0 + indent
        var baseline = baseline
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if start + width(candidate, size) > x1 && !current.isEmpty {
                glyphs += line(current, start, baseline, size)
                baseline -= pitch
                start = x0
                current = word
            } else {
                current = candidate
            }
        }
        return glyphs + line(current, start, baseline, size)
    }

    static let text1 = "Microgrids are small power systems that can run connected to the main grid or on their own, and they have been studied"
    static let text2 = "Their control is usually organised in three layers, from fast local loops to slow economic dispatch of all the units."
    static let text3 = ["Droop control shares the load among", "inverters without any communication,", "which keeps the distri-", "bution of power robust and simple."]

    /// A two-column page: title, two paragraphs on the left, a paragraph, a formula, a heading and a reference on the right.
    static func twoColumnPage() -> [PdfGlyph] {
        var glyphs: [PdfGlyph] = []
        let title = "A Study of Microgrids"
        glyphs += line(title, 300 - width(title, 20) / 2, 760, 20, "Times-Bold")
        glyphs += paragraph(text1, 50, 290, 700, 12)
        // A superscript footnote mark after "studied".
        let last = glyphs[glyphs.count - 1]
        glyphs.append(PdfGlyph("1", last.x1, last.y0 + 4, last.x1 + 3, last.y0 + 9, 6, "Times-Roman"))
        let next = glyphs.filter { $0.fontSize == 10 }.map(\.y0).min()! + 0.2 * 10 - 12
        glyphs += paragraph(text2, 50, 290, next, 12)
        for (i, text) in text3.enumerated() {
            glyphs += line(text, i == 0 ? 320 : 310, 700 - 12 * Double(i))
        }
        glyphs += line("∑ α ≤ β + γ", 400, 630, 10, "CMMI10")
        glyphs += line("References", 310, 600, 10, "Times-Bold")
        glyphs += line("[1] A. Author, A paper on grids, 2020.", 310, 585, 10)
        return glyphs
    }
}

struct PdfLayoutTests {
    @Test func findsColumnsParagraphsFormulasAndReadingOrder() {
        let blocks = PdfLayout.analyze(Glyphs.twoColumnPage(), pageWidth: 600, pageHeight: 800)
        let texts = blocks.map(\.text)
        #expect(blocks.count == 7)
        guard blocks.count == 7 else { return }
        #expect(texts[0] == "A Study of Microgrids")
        #expect(texts[1].hasPrefix("Microgrids are small power systems"))
        #expect(texts[1].hasSuffix("have been studied1"))
        #expect(texts[2].hasPrefix("Their control is usually organised"))
        #expect(texts[3].contains("the distribution of power"))
        #expect(blocks[4].isFormula)
        #expect(texts[5] == "References")
        #expect(blocks[5].bold)
        #expect(texts[6].hasPrefix("[1] A. Author"))
        #expect(blocks[0].centered)
        #expect(blocks[0].fontSize == 20)
        #expect(abs(blocks[1].linePitch - 12) < 0.001)
        #expect(blocks[1].x1 >= 280 && blocks[1].x1 <= 290)
        #expect(blocks[3].x0 >= 309 && blocks[3].x0 <= 311)
    }

    @Test func chineseLinesJoinWithoutSpaces() {
        let blocks = PdfLayout.analyze(Glyphs.line("微电网是一种小型电力系统，", 50, 700) + Glyphs.line("可以并网运行。", 50, 687), pageWidth: 600, pageHeight: 800)
        #expect(blocks.map(\.text) == ["微电网是一种小型电力系统，可以并网运行。"])
    }

    @Test func inlineMathBecomesAnObject() {
        let glyphs = Glyphs.line("where", 50, 700) + Glyphs.line("α", 80, 700, 10, "CMMI10") + Glyphs.line("is the angle", 90, 700)
        let blocks = PdfLayout.analyze(glyphs, pageWidth: 600, pageHeight: 800)
        #expect(blocks.count == 1)
        #expect(blocks.first?.isFormula == false)
        #expect(blocks.first?.pieces == [.of("where ", 0), .object(0, "α"), .of(" is the angle", 0)])
    }

    @Test func listItemsAreSeparateBlocks() {
        let glyphs = Glyphs.line("• First item of the list", 50, 700) + Glyphs.line("• Second item of the list", 50, 688)
        #expect(PdfLayout.analyze(glyphs, pageWidth: 600, pageHeight: 800).count == 2)
    }

    /// "V_cell = E_Nernst − η_act − η_ohm − η_conc   (1)" as a typesetter draws it: italic letters, smaller and lower subscripts.
    private func formulaLine(_ baseline: Double, numbered: Bool) -> [PdfGlyph] {
        var glyphs: [PdfGlyph] = []
        var x = 200.0
        func put(_ text: String, _ size: Double = 10, _ font: String = "Times-Italic", dy: Double = 0) {
            glyphs += Glyphs.line(text, x, baseline + dy, size, font)
            x += Glyphs.width(text, size)
        }
        put("V")
        put("cell", 7, "Times-Roman", dy: -2.5)
        put(" = ", 10, "Times-Roman")
        put("E")
        put("Nernst", 7, "Times-Roman", dy: -2.5)
        for loss in ["act", "ohm", "conc"] {
            put(" − ", 10, "Times-Roman")
            put("η")
            put(loss, 7, "Times-Roman", dy: -2.5)
        }
        if numbered {
            glyphs += Glyphs.line("(1)", 520, baseline)
        }
        return glyphs
    }

    @Test(arguments: [true, false]) func displayFormulasAreLeftAloneWithOrWithoutANumber(numbered: Bool) {
        // Close below and above paragraph lines: the formula must not join them.
        let glyphs = Glyphs.line("The cell voltage follows from the Nernst voltage minus three losses,", 50, 700)
            + formulaLine(688, numbered: numbered)
            + Glyphs.line("where each loss grows with the current drawn from the stack.", 50, 676)
        let blocks = PdfLayout.analyze(glyphs, pageWidth: 600, pageHeight: 800)
        let formulas = blocks.filter { $0.text.contains("=") }
        #expect(formulas.count == 1)
        #expect(formulas.first?.isFormula == true)
        #expect(formulas.first?.text.contains("Nernst") == true)
        #expect(blocks.filter { !$0.isFormula }.count == 2)
        #expect(blocks.filter { !$0.isFormula }.allSatisfy { !$0.text.contains("η") })
    }

    @Test func proseWithAnEqualsSignIsNotAFormula() {
        let blocks = PdfLayout.analyze(Glyphs.line("The rated power P = 5 kW is reached at noon on most sunny days.", 50, 700), pageWidth: 600, pageHeight: 800)
        #expect(blocks.count == 1)
        #expect(blocks.first?.isFormula == false)
    }

    @Test func subscriptsBecomeObjectsThatKeepTheirPlace() throws {
        let glyphs = Glyphs.line("The voltage", 50, 700) + Glyphs.line("V", 108, 700, 10, "Times-Italic") + Glyphs.line("cell", 113, 697.5, 7)
            + Glyphs.line("drops by 5%.", 130, 700)
        let blocks = PdfLayout.analyze(glyphs, pageWidth: 600, pageHeight: 800)
        let block = try #require(blocks.first)
        #expect(blocks.count == 1)
        #expect(block.pieces == [.of("The voltage ", 0), .object(0, "Vcell"), .of(" drops by 5%.", 0)])
        let atom = try #require(block.atoms[0])
        #expect(atom.glyphs.map(\.text) == ["V", "c", "e", "l", "l"])
        #expect(atom.glyphs[0].dx == 0)
        #expect(abs(atom.glyphs[0].dy) < 0.5)
        #expect(abs(atom.glyphs[1].dx - 5) < 0.001)
        #expect(atom.glyphs[1].dy > -3 && atom.glyphs[1].dy < -2) // lower
        #expect(atom.glyphs[1].fontSize == 7)
        #expect(abs(atom.width - 19) < 0.001)
    }

    @Test func boldTextGetsItsOwnStyle() {
        let glyphs = Glyphs.line("Abstract—", 50, 700, 10, "Times-Bold") + Glyphs.line("This paper studies small grids.", 100, 700)
        let blocks = PdfLayout.analyze(glyphs, pageWidth: 600, pageHeight: 800)
        #expect(blocks.count == 1)
        #expect(blocks.first?.pieces == [.of("Abstract— ", 1), .of("This paper studies small grids.", 0)])
    }

    @Test func fontNamesAreClassified() {
        #expect(PdfLayout.isBoldFont("ABCDEF+TimesNewRomanPS-BoldMT"))
        #expect(!PdfLayout.isBoldFont("Times-Roman"))
        #expect(PdfLayout.isSerifFont("ABCDEF+CMR10"))
        #expect(PdfLayout.isSerifFont("SimSun"))
        #expect(!PdfLayout.isSerifFont("Arial-BoldMT"))
        #expect(PdfLayout.isMathGlyph(PdfGlyph("x", 0, 0, 1, 1, 10, "XYZABC+CMMI10")))
        #expect(!PdfLayout.isMathGlyph(PdfGlyph("x", 0, 0, 1, 1, 10, "Times-Italic")))
    }
}

struct PdfDocumentTests {
    /// True when the characters of `part` appear in `text` in this order. The covered original stays in the page
    /// underneath the translation, so text extracted from it interleaves the two.
    private func containsInOrder(_ text: String, _ part: String) -> Bool {
        var rest = Substring(text)
        for c in part where !c.isWhitespace {
            guard let index = rest.firstIndex(of: c) else { return false }
            rest = rest[rest.index(after: index)...]
        }
        return true
    }

    /// A one-page PDF drawn with CoreText: a title, a three-line paragraph on a light blue box, and a rule.
    private func samplePdf() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("paper.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 230 / 255, green: 240 / 255, blue: 1, alpha: 1))
        context.fill(CGRect(x: 60, y: 842 - 200, width: 475, height: 60))
        func draw(_ text: String, _ font: CTFont, _ x: Double, _ baseline: Double) {
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as [NSAttributedString.Key: Any]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        let title = CTFontCreateWithName("TimesNewRomanPS-BoldMT" as CFString, 18, nil)
        let body = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 10, nil)
        draw("Control of Small Power Grids", title, 180, 842 - 95)
        let lines = ["Small power grids can run connected to the main grid or alone.",
                     "Their control is organised in layers, from fast local loops",
                     "to the slow economic dispatch of all generating units."]
        for (i, text) in lines.enumerated() {
            draw(text, body, 70, 842 - 160 - 12 * Double(i))
        }
        context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.stroke(CGRect(x: 60, y: 842 - 260, width: 475, height: 0.5))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test func readsBlocksAndWritesTheTranslationIntoTheSameBoxes() throws {
        let url = try samplePdf()
        let document = try PdfDocumentFile(url: url)
        try #require(document.segments.count == 2, "segments: \(document.segments.map(\.plainText))")
        #expect(document.segments[0].plainText == "Control of Small Power Grids")
        #expect(document.segments[0].role == .title)
        #expect(document.segments[1].plainText.hasPrefix("Small power grids can run connected"))
        #expect(document.segments[1].plainText.contains("from fast local loops to the slow"))

        let output = OutputPaths.url(for: url, target: Languages.english)
        let bilingual = OutputPaths.url(for: url, target: Languages.english, variant: "bilingual")
        try document.save(to: output, translations: [
            0: "GRID CONTROL",
            1: "TRANSLATED PARAGRAPH that is a good deal longer than the original paragraph was, so the font has to shrink to fit the box. "
                + "It goes on for a while longer, adding more and more words, until it clearly can't fit at the original size any more.",
        ], options: DocumentSaveOptions(target: Languages.english, bilingualURL: bilingual))

        let result = try #require(PDFDocument(url: output))
        #expect(result.pageCount == 1)
        let text = result.page(at: 0)?.string ?? ""
        #expect(containsInOrder(text, "GRID CONTROL"))
        #expect(containsInOrder(text, "TRANSLATED PARAGRAPH"))
        #expect(PDFDocument(url: bilingual)?.pageCount == 2)
    }

    @Test func writesChineseWithASystemFont() throws {
        let url = try samplePdf()
        let document = try PdfDocumentFile(url: url)
        let output = OutputPaths.url(for: url, target: Languages.simplifiedChinese)
        var translations: [Int: String] = [:]
        for segment in document.segments {
            translations[segment.id] = segment.role == .title ? "小型电网的控制" : "小型电网可以并网运行，也可以独立运行。"
        }
        try document.save(to: output, translations: translations, options: DocumentSaveOptions(target: Languages.simplifiedChinese))
        let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(containsInOrder(text, "小型电网的控制"))
        #expect(containsInOrder(text, "独立运行"))
    }

    /// A paragraph, a numbered display formula (italic letters, subscripts, minus signs, Greek letters) and a paragraph
    /// with an inline Greek letter with a subscript and a math symbol, drawn with CoreText.
    private func formulaPdf() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-formula-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("formula.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let body = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 10, nil)
        let bold = CTFontCreateWithName("TimesNewRomanPS-BoldMT" as CFString, 10, nil)
        let italic = CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString, 10, nil)
        let small = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 7, nil)
        var x = 0.0, y = 0.0
        func put(_ text: String, _ font: CTFont, dy: Double = 0) {
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as [NSAttributedString.Key: Any]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
            context.textPosition = CGPoint(x: x, y: y + dy)
            CTLineDraw(line, context)
            x += CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        (x, y) = (70, 842 - 160)
        put("Abstract—", bold)
        put(" The cell voltage follows from the Nernst voltage minus three losses of the stack,", body)
        (x, y) = (70, 842 - 172)
        put("as given in the equation below for every operating point of the system.", body)
        (x, y) = (200, 842 - 200)
        put("V", italic)
        put("cell", small, dy: -2.5)
        put(" = ", body)
        put("E", italic)
        put("Nernst", small, dy: -2.5)
        for loss in ["act", "ohm", "conc"] {
            put(" − ", body)
            put("η", italic)
            put(loss, small, dy: -2.5)
        }
        x = 515
        put("(1)", body)
        (x, y) = (70, 842 - 230)
        put("The loss ", body)
        put("η", italic)
        put("act", small, dy: -2.5)
        put(" grows with the current, while the product a", body)
        put("⋅", body)
        put("b stays small at every load.", body)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// The characters on the formula's line (baseline 842 − 200), with their positions and sizes.
    private func formulaGlyphs(_ url: URL) throws -> [String] {
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        return PdfDocumentFile.glyphs(of: page).filter { (842.0 - 206)...(842 - 194) ~= $0.y0 + 0.25 * $0.fontSize }
            .map { "\($0.text) \(Int(($0.x0 * 10).rounded())) \(Int(($0.fontSize * 10).rounded()))" }
    }

    @Test func displayFormulasStayAsTheyWereAndObjectsKeepTheirCharacters() throws {
        let url = try formulaPdf()
        let document = try PdfDocumentFile(url: url)
        // The two paragraphs; the formula and its number aren't sent for translation.
        try #require(document.segments.count == 2, "segments: \(document.segments.map(\.text.text))")
        #expect(!document.segments.contains { $0.plainText.contains("=") })
        let intro = try #require(document.segments.first { $0.plainText.contains("Nernst voltage") })
        let paragraph = try #require(document.segments.first { $0.plainText.contains("grows with the current") })
        #expect(intro.text.text.hasPrefix("<1>Abstract—</1>"))
        let tagged = paragraph.text.text as NSString
        let atoms = try NSRegularExpression(pattern: "<\\d+/>").matches(in: paragraph.text.text, range: NSRange(location: 0, length: tagged.length))
            .map { tagged.substring(with: $0.range) }
        try #require(atoms.count == 2, "\(paragraph.text.text)")

        let output = OutputPaths.url(for: url, target: Languages.simplifiedChinese)
        try document.save(to: output, translations: [
            intro.id: "<1>摘要—</1>电堆电压等于能斯特电压减去三种损耗，见下式。",
            paragraph.id: "损耗\(atoms[0])随电流增大，而乘积 a\(atoms[1])b 在各种负荷下都很小。",
        ], options: DocumentSaveOptions(target: Languages.simplifiedChinese))

        #expect(try formulaGlyphs(output) == formulaGlyphs(url))
        let before = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
        let after = try #require(PDFDocument(url: output)?.page(at: 0)?.string)
        // The formula is left alone; the covered original stays underneath on the Mac, so the translation adds one η and one ⋅.
        #expect(before.filter { $0 == "−" }.count == 3)
        #expect(after.filter { $0 == "−" }.count == 3)
        #expect(after.filter { $0 == "η" }.count == before.filter { $0 == "η" }.count + 1)
        #expect(after.filter { $0 == "⋅" }.count == before.filter { $0 == "⋅" }.count + 1)
        #expect(containsInOrder(after, "随电流增大"))
        // The bold heading word stays bold.
        let translated = try #require(PDFDocument(url: output))
        let translatedPage = try #require(translated.page(at: 0))
        let heading = PdfDocumentFile.glyphs(of: translatedPage).first { $0.text == "摘" }
        #expect(heading.map { PdfLayout.isBoldFont($0.fontName) } == true, "\(heading?.fontName ?? "-")")
    }

    @Test func scannedPdfsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qy-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        do {
            _ = try DocumentLoader.open(url)
            Issue.record("expected an error")
        } catch let error as DocumentError {
            #expect(error.message.contains("OCR"))
        }
    }
}
