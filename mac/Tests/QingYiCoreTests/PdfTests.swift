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
        let text = (result.page(at: 0)?.string ?? "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        #expect(text.contains("GRIDCONTROL"))
        #expect(text.contains("TRANSLATEDPARAGRAPH"))
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
        #expect(text.contains("小型电网的控制"))
        #expect(text.contains("独立运行"))
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
