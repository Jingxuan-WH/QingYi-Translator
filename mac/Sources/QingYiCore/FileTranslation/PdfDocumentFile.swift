import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// A PDF with real text (not a scan). PDFKit reports where every character is; `PdfLayout` turns them into
/// paragraphs. The translated copy redraws each page with CoreGraphics, covers each translated paragraph in
/// its background colour and sets the translation into the same box with CoreText (shrunk to fit), so figures,
/// vector graphics, table rules and formulas stay untouched. Links, bookmarks and page rotation are restored
/// with PDFKit afterwards.
public final class PdfDocumentFile: TranslatableDocument {
    private var blocks: [(page: Int, block: PdfBlock, segment: Int)] = []

    public init(url: URL) throws {
        super.init(sourceURL: url)
        let document = try PdfDocumentFile.open(url)
        var allBlocks: [(page: Int, block: PdfBlock)] = []
        var glyphCount = 0, imagePages = 0, rotated = 0
        var scannedPages: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let glyphs = PdfDocumentFile.glyphs(of: page)
            glyphCount += glyphs.count
            if glyphs.count < 20, let cgPage = page.pageRef, PdfDocumentFile.hasImages(cgPage) {
                imagePages += 1
                scannedPages.append(index + 1)
            }
            if glyphs.isEmpty {
                continue
            }
            if page.rotation != 0 {
                // Turned pages (landscape tables) keep their original text.
                rotated += 1
                continue
            }
            let box = page.bounds(for: .mediaBox)
            // The layout works from the page's corner; PDFKit reports positions in user space.
            let shifted = glyphs.map { glyph -> PdfGlyph in
                var moved = glyph
                moved.x0 -= box.minX
                moved.x1 -= box.minX
                moved.y0 -= box.minY
                moved.y1 -= box.minY
                return moved
            }
            for block in PdfLayout.analyze(shifted, pageWidth: box.width, pageHeight: box.height) {
                PdfDocumentFile.shift(block, dx: box.minX, dy: box.minY)
                allBlocks.append((index, block))
            }
        }
        let pages = document.pageCount
        if pages > 0 && ((glyphCount < 30 * pages && imagePages * 2 >= pages) || glyphCount == 0) {
            throw DocumentError(L(
                "这是扫描版 PDF（页面是图片，没有可提取的文字），暂不支持。可以先用 WPS、Adobe Acrobat 等软件做文字识别（OCR），再翻译识别后的文件。",
                "This is a scanned PDF (its pages are images without text), which isn’t supported. Run text recognition (OCR) on it first, e.g. in Adobe Acrobat, then translate the result."))
        }
        if !scannedPages.isEmpty {
            let list = scannedPages.prefix(8).map(String.init).joined(separator: ", ") + (scannedPages.count > 8 ? "…" : "")
            warnings.append(L("第 \(list) 页是扫描图片，没有翻译。", "Page \(list) is a scanned image and wasn’t translated."))
        }
        if rotated > 0 {
            warnings.append(L("\(rotated) 个旋转过的页面（例如横向表格）保留了原文。", "\(rotated) rotated page(s) (e.g. landscape tables) kept their original text."))
        }
        addSegments(allBlocks)
    }

    public override var supportsBilingual: Bool { true }

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError(L("无法打开这个 PDF，它可能已损坏。", "This PDF can’t be opened; it may be damaged."))
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw DocumentError(L("这个 PDF 设置了打开密码，请先去掉密码再翻译。", "This PDF is password-protected. Please remove the password first."))
        }
        return document
    }

    /// Moves a block found in page-corner coordinates back into user space.
    private static func shift(_ block: PdfBlock, dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let lines = block.lines.map { line -> PdfLine in
            let moved = PdfLine(line.glyphs.map { glyph -> PdfGlyph in
                var g = glyph
                g.x0 += dx
                g.x1 += dx
                g.y0 += dy
                g.y1 += dy
                return g
            }, row: line.row)
            moved.fontSize = line.fontSize
            moved.bold = line.bold
            return moved
        }
        block.replaceLines(lines)
    }

    // ---------------- reading ----------------

    /// One character as PDFKit reports it, before its box is rebuilt from the line's baseline.
    private struct RawChar {
        var text: String
        var box: CGRect
        var points: Double // the font size in the text attributes; 0 when there are none
        var fontName: String
        var color: Int
        var spaceAfter = false
        var breakBefore = false
    }

    /// The characters of a page with their boxes, font and colour. Spaces stay out; the gaps between words show them.
    /// Text, box and font come from the same one-character selection: `page.string` can contain characters that
    /// `characterBounds(at:)` doesn't count, which would give every following character its neighbour's box.
    /// PDFKit reports either the font's full height or just the ink of each letter, so the boxes are rebuilt from
    /// each line's baseline (a sub/superscript's own) and font size, as on Windows: [baseline − 0.25 × size, baseline + 0.8 × size].
    static func glyphs(of page: PDFPage) -> [PdfGlyph] {
        var chars: [RawChar] = []
        var pendingBreak = false
        for index in 0..<page.numberOfCharacters {
            guard let selection = page.selection(for: NSRange(location: index, length: 1)), let value = selection.string, !value.isEmpty else { continue }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if value.contains(where: \.isNewline) {
                    pendingBreak = true
                }
                if !chars.isEmpty {
                    chars[chars.count - 1].spaceAfter = true
                }
                continue
            }
            let box = selection.bounds(for: page)
            guard !box.isNull, !box.isInfinite, box.width > 0, box.height > 0 else { continue }
            var points = 0.0
            var fontName = ""
            var color = 0
            if let attributed = selection.attributedString, attributed.length > 0 {
                if let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    fontName = font.fontName
                    points = Double(font.pointSize)
                }
                if let foreground = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                   let rgb = foreground.usingColorSpace(.sRGB) {
                    color = (Int(rgb.redComponent * 255) << 16) | (Int(rgb.greenComponent * 255) << 8) | Int(rgb.blueComponent * 255)
                }
            }
            chars.append(RawChar(text: value, box: box, points: points, fontName: fontName, color: color, breakBefore: pendingBreak))
            pendingBreak = false
        }

        // Runs of characters on one line, in PDFKit's order: a new run after a line break, when the text jumps back
        // to the left, or when the next character no longer overlaps the run vertically.
        var runs: [Range<Int>] = []
        var start = 0
        var top = -Double.greatestFiniteMagnitude, bottom = Double.greatestFiniteMagnitude
        for i in chars.indices {
            let box = chars[i].box
            if i > start {
                let previous = chars[i - 1].box
                let jumpsBack = box.minX < previous.maxX - max(box.height, previous.height)
                if chars[i].breakBefore || jumpsBack || Double(box.minY) >= top || Double(box.maxY) <= bottom {
                    runs.append(start..<i)
                    start = i
                    top = -Double.greatestFiniteMagnitude
                    bottom = Double.greatestFiniteMagnitude
                }
            }
            top = max(top, Double(box.maxY))
            bottom = min(bottom, Double(box.minY))
        }
        if start < chars.count {
            runs.append(start..<chars.count)
        }

        var result: [PdfGlyph] = []
        var spaceAfter: [Bool] = []
        // The ink of most letters and digits sits on the baseline; descenders and punctuation don't.
        func flat(_ char: RawChar) -> Bool {
            char.text.unicodeScalars.allSatisfy { TranslatableDocument.isLetter($0) || CharacterSet.decimalDigits.contains($0) }
                && !char.text.contains(where: { "gjpqyQβγζημξρςφχψ".contains($0) })
        }
        for run in runs {
            let line = Array(chars[run])
            let heights = line.map { Double($0.box.height) }
            let tallest = heights.max()!
            // The font size from the attributes, unless the text was scaled by its matrix (size 1 drawn at 10): 0 then.
            let sizes = line.map { $0.points > 0 && $0.points >= 0.6 * Double($0.box.height) ? $0.points : 0 }
            let mainSize = sizes.max()!
            // Full-size characters share the line's baseline; sub/superscripts keep their own.
            let isMain = sizes.map { mainSize == 0 || $0 >= 0.85 * mainSize }
            let main = line.indices.filter { isMain[$0] }
            let mainHeights = main.map { heights[$0] }
            let mainBottoms = main.map { Double(line[$0].box.minY) }
            // Boxes of the font's full height are all alike; ink boxes vary with the letters.
            let fullHeight = main.count >= 2 && mainHeights.max()! - mainHeights.min()! < 0.03 * mainHeights.max()!
                && mainBottoms.max()! - mainBottoms.min()! < 0.03 * mainHeights.max()!
            let flatMain = main.filter { flat(line[$0]) }
            let bottoms = (flatMain.isEmpty ? main : flatMain).map { Double(line[$0].box.minY) }.sorted()
            let lineBaseline = bottoms[bottoms.count / 2]
            for (i, char) in line.enumerated() {
                let size = sizes[i] > 0 ? sizes[i] : fullHeight ? heights[i] * 0.9 : isMain[i] ? tallest * 1.1 : heights[i] * 1.5
                let bottom = Double(char.box.minY)
                let baseline = fullHeight ? bottom + 0.2 * heights[i] : isMain[i] ? lineBaseline : bottom + (flat(char) ? 0 : 0.2 * size)
                let box = char.box
                result.append(PdfGlyph(char.text, Double(box.minX), baseline - 0.25 * size, Double(box.maxX), baseline + 0.8 * size,
                                       size, char.fontName, char.color))
                spaceAfter.append(char.spaceAfter)
            }
        }

        // Letters of one word touch: close small gaps that tight character boxes leave, so they don't read as spaces.
        for i in result.indices.dropLast() where !spaceAfter[i] {
            let next = result[i + 1]
            let gap = next.x0 - result[i].x1
            if gap > 0 && gap < 0.3 * result[i].fontSize && abs(next.centerY - result[i].centerY) < 0.5 * result[i].fontSize {
                result[i].x1 = next.x0
            }
        }
        return result
    }

    /// True when the page draws images (used to recognise scanned pages).
    static func hasImages(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return false }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let streamDictionary = CGPDFStreamGetDictionary(stream) {
                var name: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(streamDictionary, "Subtype", &name), let name, String(cString: name) == "Image" {
                    found = true
                    return false
                }
            }
            return true
        }, nil)
        return found
    }

    private func addSegments(_ all: [(page: Int, block: PdfBlock)]) {
        let text = all.filter { !$0.block.isFormula && TranslatableDocument.hasWords($0.block.wordsText) }
        guard !text.isEmpty else { return }
        // The size of most of the text, weighted by length.
        var sizes: [Double] = []
        for item in text {
            sizes += Array(repeating: (item.block.fontSize * 10).rounded() / 10, count: max(1, item.block.wordsText.count / 20))
        }
        sizes.sort()
        let body = sizes[sizes.count / 2]
        let largestOnFirstPage = text.filter { $0.page == 0 }.map(\.block.fontSize).max() ?? 0

        var inReferences = false
        var titleFound = false
        for (page, block) in text {
            let words = block.wordsText
            let shortText = block.lines.count <= 2 && words.count <= 120
            var role = SegmentRole.body
            if !titleFound && page == 0 && block.fontSize >= body * 1.3 && block.fontSize >= largestOnFirstPage - 0.1 && shortText {
                role = .title
                titleFound = true
            } else if shortText && (block.fontSize >= body * 1.12 || (block.bold && block.lines.count == 1 && !words.trimmingCharacters(in: .whitespaces).hasSuffix("."))) {
                role = .heading
            }
            let segment = addSegment(block.pieces, role: role)
            blocks.append((page, block, segment.id))
            if ReferenceSection.isHeading(words) {
                inReferences = true
                continue
            }
            if inReferences && role != .body {
                inReferences = false
            }
            segment.isReference = inReferences
        }
    }

    // ---------------- writing ----------------

    public override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        let document = try PdfDocumentFile.open(sourceURL)
        try TranslatableDocument.writeAtomically(to: url) { temp in
            guard let context = CGContext(temp as CFURL, mediaBox: nil, nil) else {
                throw DocumentError(L("无法创建 PDF 文件。", "Couldn’t create the PDF file."))
            }
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let cgPage = page.pageRef else { continue }
                var box = cgPage.getBoxRect(.cropBox)
                let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(info)
                context.drawPDFPage(cgPage)
                let items = blocks.filter { $0.page == index && translations[$0.segment] != nil }
                if !items.isEmpty {
                    let background = PdfDocumentFile.backgroundSampler(cgPage, box: box)
                    for (_, block, segment) in items {
                        if let background {
                            block.background = PdfDocumentFile.backgroundColor(around: block, sampler: background)
                        }
                        PdfDocumentFile.draw(block, translation: segments[segment].text.parse(translations[segment]!), target: options.target, in: context)
                    }
                }
                context.endPDFPage()
            }
            context.closePDF()
            PdfDocumentFile.restoreStructure(of: temp, from: document)
        }
        if let bilingual = options.bilingualURL {
            saveBilingual(translated: url, to: bilingual)
        }
    }

    /// Covers the original lines and sets the translation into the paragraph's box, shrinking the font until it fits.
    /// Bold and italic text keep their style, Latin text in a CJK translation gets a Latin font, and objects (inline
    /// formulas, sub/superscripts) are drawn character by character as they were.
    private static func draw(_ block: PdfBlock, translation: [InlinePiece], target: Language, in context: CGContext) {
        let hasContent = translation.contains {
            $0.isAtom ? block.atoms[$0.atom] != nil : !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasContent else { return }

        // Cover the original lines (slightly larger than the characters, for accents and anti-aliasing).
        context.setFillColor(cgColor(block.background))
        for line in block.lines {
            let pad = 0.08 * line.fontSize
            context.fill(CGRect(x: line.x0 - 0.6, y: line.y0 - pad, width: line.x1 - line.x0 + 1.2, height: line.y1 - line.y0 + 2 * pad))
        }

        let width = block.x1 - block.x0
        let height = block.y1 - block.y0
        let pitchRatio = block.linePitch / block.fontSize
        let minimum = max(block.fontSize * 0.5, min(block.fontSize, 4))
        var size = block.fontSize
        while true {
            let string = attributedText(translation, block: block, target: target, size: size, pitch: pitchRatio * size)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                   CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            // The first line needs about one font size of height; each further line one pitch.
            let allowed = height + 0.15 * size + (pitchRatio * size - size)
            if Double(fit.height) <= allowed || size * 0.95 < minimum {
                let frameHeight = max(Double(fit.height), allowed) + 1
                let top = block.y1 + 0.15 * size
                let rect = CGRect(x: block.x0, y: top - frameHeight, width: width, height: frameHeight)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
                context.saveGState()
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                drawAtoms(in: frame, rect: rect, block: block, scale: size / block.fontSize, context: context)
                context.restoreGState()
                return
            }
            size *= 0.95
        }
    }

    /// Marks the placeholder of an object in the attributed text; the value is the object number.
    private static let atomKey = NSAttributedString.Key("QingYiAtom")

    /// The size of an object's placeholder, for CoreText's line layout.
    private final class AtomBox {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat

        init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
        }
    }

    private static func placeholder(width: Double, size: Double) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { pointer in
            Unmanaged<AtomBox>.fromOpaque(pointer).release()
        }, getAscent: { pointer in
            Unmanaged<AtomBox>.fromOpaque(pointer).takeUnretainedValue().ascent
        }, getDescent: { pointer in
            Unmanaged<AtomBox>.fromOpaque(pointer).takeUnretainedValue().descent
        }, getWidth: { pointer in
            Unmanaged<AtomBox>.fromOpaque(pointer).takeUnretainedValue().width
        })
        let box = AtomBox(width: CGFloat(width), ascent: CGFloat(0.8 * size), descent: CGFloat(0.25 * size))
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())
    }

    private static func attributedText(_ translation: [InlinePiece], block: PdfBlock, target: Language, size: Double, pitch: Double) -> CFAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = block.centered ? .center : block.justified ? .justified : .left
        style.firstLineHeadIndent = block.firstLineIndent
        style.minimumLineHeight = pitch
        style.maximumLineHeight = pitch
        style.lineBreakMode = .byWordWrapping
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let common: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(block.color),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        let all = translation.filter { !$0.isAtom }.map(\.text).joined()
        let main = font(for: target, text: all, serif: block.serif, bold: block.bold, italic: block.italic, size: size)
        let cjkTarget = ["zh-Hans", "zh-Hant", "ja", "ko"].contains(target.code)
        let formulas = Dictionary(block.pieces.filter(\.isAtom).map { ($0.atom, $0.text) }, uniquingKeysWith: { first, _ in first })
        let result = NSMutableAttributedString()
        for piece in translation {
            if piece.isAtom, let atom = block.atoms[piece.atom] {
                var attributes = common
                attributes[fontKey] = main
                attributes[atomKey] = piece.atom
                if let delegate = placeholder(width: atom.width * size / block.fontSize, size: size) {
                    attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
                }
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
                continue
            }
            let text = piece.isAtom ? formulas[piece.atom] ?? "" : piece.text
            let bold = piece.style & 1 != 0 || (piece.isAtom && block.bold)
            let italic = piece.style & 2 != 0 || (piece.isAtom && block.italic)
            let targetFont = font(for: target, text: text, serif: block.serif, bold: bold, italic: italic, size: size)
            let latinFont = font(for: Languages.english, text: "", serif: block.serif, bold: bold, italic: italic, size: size)
            // Runs of Latin and other characters: in a CJK translation, Latin letters, digits and symbols get a Latin font
            // (CJK fonts draw them as stiff half-width forms); CoreText falls back for characters a font lacks.
            var run = ""
            var runIsLatin = false
            func flush() {
                guard !run.isEmpty else { return }
                var attributes = common
                attributes[fontKey] = runIsLatin ? latinFont : targetFont
                result.append(NSAttributedString(string: run, attributes: attributes))
                run = ""
            }
            for character in text {
                let latin = cjkTarget && isLatin(character) && !(character.isWhitespace && !runIsLatin)
                if latin != runIsLatin {
                    flush()
                    runIsLatin = latin
                }
                run.append(character)
            }
            flush()
        }
        return result as CFAttributedString
    }

    /// Latin, Greek and Cyrillic letters, digits and symbols, apart from the punctuation CJK text sets at its own width.
    private static func isLatin(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        if [0x2014, 0x2026, 0x2018, 0x2019, 0x201C, 0x201D, 0xB7].contains(value) {
            return false
        }
        return value < 0x0530 || (0x1E00...0x1FFF).contains(value) || (0x2000...0x2BFF).contains(value)
    }

    /// Draws each object's characters where its placeholder ended up, at their original offsets and sizes (scaled with the paragraph).
    private static func drawAtoms(in frame: CTFrame, rect: CGRect, block: PdfBlock, scale: Double, context: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let number = attributes[atomKey.rawValue] as? Int, let atom = block.atoms[number] else { continue }
                let range = CTRunGetStringRange(run)
                for k in 0..<range.length {
                    let offset = CTLineGetOffsetForStringIndex(line, range.location + k, nil)
                    let x = Double(rect.minX + origins[index].x + offset)
                    let baseline = Double(rect.minY + origins[index].y)
                    for glyph in atom.glyphs where !glyph.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        let glyphFont = font(for: Languages.english, text: "", serif: block.serif || PdfLayout.isSerifFont(glyph.fontName),
                                             bold: PdfLayout.isBoldFont(glyph.fontName), italic: PdfLayout.isItalicFont(glyph.fontName),
                                             size: max(glyph.fontSize * scale, 1))
                        let attributes: [NSAttributedString.Key: Any] = [
                            NSAttributedString.Key(kCTFontAttributeName as String): glyphFont,
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(block.color),
                        ]
                        let text = CTLineCreateWithAttributedString(NSAttributedString(string: glyph.text, attributes: attributes) as CFAttributedString)
                        context.textPosition = CGPoint(x: x + glyph.dx * scale, y: baseline + glyph.dy * scale)
                        CTLineDraw(text, context)
                    }
                }
            }
        }
    }

    /// System fonts for the target language: 宋体/苹方 for Chinese, Hiragino for Japanese, Apple's Korean fonts,
    /// Times New Roman / Helvetica Neue otherwise. CoreText falls back to other fonts for characters they lack.
    static func font(for target: Language, text: String, serif: Bool, bold: Bool, italic: Bool, size: Double) -> CTFont {
        let hasCjk = text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        let family: String
        switch target.code {
        case "zh-Hans": family = serif ? "Songti SC" : "PingFang SC"
        case "zh-Hant": family = serif ? "Songti TC" : "PingFang TC"
        case "ja": family = serif ? "Hiragino Mincho ProN" : "Hiragino Sans"
        case "ko": family = serif ? "AppleMyungjo" : "Apple SD Gothic Neo"
        default: family = hasCjk ? (serif ? "Songti SC" : "PingFang SC") : (serif ? "Times New Roman" : "Helvetica Neue")
        }
        let base = CTFontCreateWithName(family as CFString, CGFloat(size), nil)
        var traits = CTFontSymbolicTraits()
        if bold {
            traits.insert(.traitBold)
        }
        if italic {
            traits.insert(.traitItalic)
        }
        guard !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, traits, traits) else { return base }
        return styled
    }

    private static func cgColor(_ rgb: Int) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// Renders the page once at 72 dpi and returns a function that reads a pixel's colour at a point in user space.
    private static func backgroundSampler(_ page: CGPDFPage, box: CGRect) -> ((Double, Double) -> Int?)? {
        let width = Int(box.width.rounded(.up)), height = Int(box.height.rounded(.up))
        guard width > 0, height > 0, width * height < 25_000_000, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.translateBy(x: -box.minX, y: -box.minY)
        bitmap.drawPDFPage(page)
        guard let data = bitmap.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return { x, y in
            _ = bitmap // keeps the pixel memory alive
            let px = Int(x - Double(box.minX)), py = Int(y - Double(box.minY))
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            let offset = ((height - 1 - py) * width + px) * 4 // memory starts with the top row
            return (Int(pixels[offset]) << 16) | (Int(pixels[offset + 1]) << 8) | Int(pixels[offset + 2])
        }
    }

    /// The most common colour just outside the block's lines: the background the text sits on.
    private static func backgroundColor(around block: PdfBlock, sampler: (Double, Double) -> Int?) -> Int {
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        func sample(_ x: Double, _ y: Double) {
            guard let color = sampler(x, y) else { return }
            let r = (color >> 16) & 0xFF, g = (color >> 8) & 0xFF, b = color & 0xFF
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let entry = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (entry.count + 1, entry.r + r, entry.g + g, entry.b + b)
        }
        for line in block.lines {
            let pad = 0.2 * line.fontSize + 1.5
            var x = line.x0
            while x <= line.x1 {
                sample(x, line.y1 + pad)
                sample(x, line.y0 - pad)
                x += 3
            }
            var y = line.y0
            while y <= line.y1 {
                sample(line.x0 - pad, y)
                sample(line.x1 + pad, y)
                y += 2
            }
        }
        guard let best = counts.values.max(by: { $0.count < $1.count }), best.count > 0 else { return 0xFFFFFF }
        return ((best.r / best.count) << 16) | ((best.g / best.count) << 8) | (best.b / best.count)
    }

    /// CoreGraphics drops what isn't page content; put back page rotation, links and the bookmarks by page number.
    private static func restoreStructure(of url: URL, from original: PDFDocument) {
        guard let output = PDFDocument(url: url) else { return }
        var changed = false
        for index in 0..<min(output.pageCount, original.pageCount) {
            guard let page = output.page(at: index), let source = original.page(at: index) else { continue }
            if source.rotation != 0 {
                page.rotation = source.rotation
                changed = true
            }
            for annotation in source.annotations where annotation.type == "Link" {
                let link = PDFAnnotation(bounds: annotation.bounds, forType: .link, withProperties: nil)
                if let target = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                    link.url = target
                } else if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                          let mapped = map(destination, from: original, to: output) {
                    link.destination = mapped
                } else {
                    continue
                }
                page.addAnnotation(link)
                changed = true
            }
        }
        if let root = original.outlineRoot {
            output.outlineRoot = copyOutline(root, from: original, to: output)
            changed = true
        }
        guard changed else { return }
        let rewritten = url.appendingPathExtension("structure")
        if output.write(to: rewritten) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: rewritten)
        } else {
            try? FileManager.default.removeItem(at: rewritten)
        }
    }

    private static func map(_ destination: PDFDestination, from original: PDFDocument, to output: PDFDocument) -> PDFDestination? {
        guard let page = destination.page, let target = output.page(at: original.index(for: page)) else { return nil }
        return PDFDestination(page: target, at: destination.point)
    }

    private static func copyOutline(_ item: PDFOutline, from original: PDFDocument, to output: PDFDocument) -> PDFOutline {
        let copy = PDFOutline()
        copy.label = item.label
        if let destination = item.destination {
            copy.destination = map(destination, from: original, to: output)
        }
        for index in 0..<item.numberOfChildren {
            if let child = item.child(at: index) {
                copy.insertChild(copyOutline(child, from: original, to: output), at: copy.numberOfChildren)
            }
        }
        copy.isOpen = item.isOpen
        return copy
    }

    /// Original and translated pages alternating, for checking the translation side by side.
    private func saveBilingual(translated: URL, to url: URL) {
        guard let original = PDFDocument(url: sourceURL), let translation = PDFDocument(url: translated) else {
            warnings.append(L("双语对照版没能生成。", "The bilingual version couldn’t be created."))
            return
        }
        if original.isLocked {
            _ = original.unlock(withPassword: "")
        }
        let both = PDFDocument()
        for index in 0..<translation.pageCount {
            if index < original.pageCount, let page = original.page(at: index)?.copy() as? PDFPage {
                both.insert(page, at: both.pageCount)
            }
            if let page = translation.page(at: index)?.copy() as? PDFPage {
                both.insert(page, at: both.pageCount)
            }
        }
        do {
            try TranslatableDocument.writeAtomically(to: url) { temp in
                if !both.write(to: temp) {
                    throw DocumentError(L("无法写入文件。", "Couldn’t write the file."))
                }
            }
        } catch {
            Log.error("生成双语对照 PDF 失败", error)
            warnings.append(L("双语对照版没能生成：\(error.localizedDescription)", "The bilingual version couldn’t be created: \(error.localizedDescription)"))
        }
    }
}
