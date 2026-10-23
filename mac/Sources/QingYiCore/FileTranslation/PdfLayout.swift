import Foundation

/// One character on a PDF page, in PDF user space (origin bottom left, y up). `color` is 0xRRGGBB.
public struct PdfGlyph: Equatable {
    public var text: String
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double
    public var fontSize: Double
    public var fontName: String
    public var color: Int

    public init(_ text: String, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ fontSize: Double, _ fontName: String, _ color: Int = 0) {
        self.text = text
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.fontSize = fontSize
        self.fontName = fontName
        self.color = color
    }

    var centerY: Double { (y0 + y1) / 2 }
    var height: Double { y1 - y0 }
    var isBold: Bool { PdfLayout.isBoldFont(fontName) }
}

/// A line of text within one column.
public final class PdfLine {
    public let glyphs: [PdfGlyph]
    public let x0: Double
    public let x1: Double
    public let y0: Double
    public let y1: Double
    public var fontSize: Double = 0
    public var bold = false
    /// Which row of the page the line came from; lines of one row were split at wide gaps.
    var row = 0
    /// Shares its row with other text on the same side of the column gap: a table cell, a label, an equation number.
    var tabular = false
    /// A line of a display formula; it is left as it is and never joins a paragraph.
    var formula = false

    init(_ glyphs: [PdfGlyph], row: Int) {
        self.glyphs = glyphs
        self.row = row
        x0 = glyphs.map(\.x0).min() ?? 0
        x1 = glyphs.map(\.x1).max() ?? 0
        y0 = glyphs.map(\.y0).min() ?? 0
        y1 = glyphs.map(\.y1).max() ?? 0
    }
}

/// One character of an inline formula or sub/superscript: its offset from the object's left end and the line's baseline.
public struct PdfAtomGlyph: Equatable {
    public var text: String
    public var dx: Double
    public var dy: Double
    public var fontSize: Double
    public var fontName: String
}

/// An inline formula or a sub/superscript as it was drawn, so the translation can draw it the same way.
public struct PdfAtom: Equatable {
    public var width: Double
    public var glyphs: [PdfAtomGlyph]
}

/// A paragraph (or heading, caption, table cell…) found on a page.
public final class PdfBlock {
    public private(set) var lines: [PdfLine] = []
    public private(set) var x0 = Double.greatestFiniteMagnitude
    public private(set) var x1 = -Double.greatestFiniteMagnitude
    public private(set) var y0 = Double.greatestFiniteMagnitude
    public private(set) var y1 = -Double.greatestFiniteMagnitude
    public var fontSize: Double = 0
    public var bold = false
    public var italic = false
    public var serif = false
    public var color = 0
    public var centered = false
    public var justified = false
    public var isFormula = false
    /// How far the first line starts right of the others (a paragraph indent); 0 for single lines.
    public var firstLineIndent: Double = 0
    /// Distance between the baselines of two lines; for a single line, 1.2 × the font size.
    public var linePitch: Double = 0
    /// The text with inline formulas and sub/superscripts as objects (their text is kept). Text pieces have a style:
    /// 1 when bold, 2 when italic, 3 when both, otherwise 0.
    public var pieces: [InlinePiece] = []
    /// The objects among `pieces`, by object number, with their characters' positions.
    public var atoms: [Int: PdfAtom] = [:]
    /// The page's background behind the text, 0xRRGGBB; used to cover the original text.
    public var background = 0xFFFFFF

    public var text: String { pieces.map(\.text).joined() }
    public var wordsText: String { pieces.filter { !$0.isAtom }.map(\.text).joined() }

    func replaceLines(_ replacement: [PdfLine]) {
        lines = []
        x0 = .greatestFiniteMagnitude
        x1 = -.greatestFiniteMagnitude
        y0 = .greatestFiniteMagnitude
        y1 = -.greatestFiniteMagnitude
        for line in replacement {
            add(line)
        }
    }

    func add(_ line: PdfLine) {
        lines.append(line)
        x0 = min(x0, line.x0)
        x1 = max(x1, line.x1)
        y0 = min(y0, line.y0)
        y1 = max(y1, line.y1)
    }
}

/// Finds lines, columns, paragraphs and formulas among the characters of a PDF page. The PDF only knows where
/// each character is drawn; this rebuilds the reading structure: rows by vertical position, superscripts folded
/// into their line, rows split at column gaps, lines stacked into paragraphs by spacing, indentation and font,
/// then ordered by column. The same steps and thresholds as Core/FileTranslation/PdfLayout.cs on Windows.
public enum PdfLayout {
    private static let mathFonts = ["cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msam", "msbm", "math", "symbol", "mtextra", "mt extra",
                                    "stix", "euclid", "esint", "rsfs", "wasy", "lmmi", "lmsy", "mtmi", "mtsy", "mathematicalpi", "eufm",
                                    "eusm", "bbold", "dsrom"]
    private static let serifHints = ["times", "serif", "roman", "minion", "garamond", "georgia", "cambria", "palatino", "book", "cmr",
                                     "lmroman", "nimbusrom", "termes", "pagella", "song", "ming", "mincho", "kai", "fang", "batang",
                                     "charter", "century", "baskerville", "utopia", "stixtwo", "libertine", "sabon", "caslon", "bodoni",
                                     "simsun", "stsong", "fzss"]
    private static let bullets: Set<Character> = ["•", "·", "▪", "▫", "◦", "●", "○", "■", "□", "♦", "◆", "➢", "➤", "►", "▶", "✓", "✔", "-", "–", "—", "*"]
    private static let mathSymbols: Set<Character> = ["∂", "∇", "∞", "√", "∑", "∏", "∫", "±", "×", "÷", "≤", "≥", "≠", "≈", "→", "←", "↔", "⇒", "⇔"]
    private static let relations: Set<Character> = ["=", "<", ">", "≤", "≥", "≈", "≠", "≡", "∝", "≪", "≫", "→", "←", "⇒", "⇔", "↔", "∈", "∉", "⊂", "⊆"]
    private static let operators: Set<Character> = ["+", "−", "×", "÷", "·", "±", "∓", "/", "^", "*"]

    public static func isBoldFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("bold") || lower.contains("black") || lower.contains("heavy") || lower.contains("semibold")
            || lower.contains("demi") || lower.hasSuffix(",b") || lower.contains("-bd") || lower.contains("cmbx")
            || (lower.contains("medi") && !lower.contains("medium")) || lower.contains("heiti") || lower.contains("simhei")
    }

    public static func isItalicFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("italic") || lower.contains("oblique") || lower.contains("-it") || lower.contains("cmti") || lower.hasSuffix(",i")
    }

    public static func isSerifFont(_ name: String) -> Bool {
        let lower = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        if lower.contains("sans") || lower.contains("arial") || lower.contains("helvetica") || lower.contains("gothic") || lower.contains("hei") {
            return false
        }
        return serifHints.contains { lower.contains($0) }
    }

    public static func isMathGlyph(_ glyph: PdfGlyph) -> Bool {
        var font = glyph.fontName.lowercased()
        // Subset prefixes such as "ABCDEF+CMMI10" keep the real name after the plus sign.
        if let plus = font.firstIndex(of: "+") {
            font = String(font[font.index(after: plus)...])
        }
        if mathFonts.contains(where: { font.contains($0) }) {
            return true
        }
        for c in glyph.text {
            guard let scalar = c.unicodeScalars.first else { continue }
            let v = scalar.value
            if (0x2200...0x22FF).contains(v) || (0x27C0...0x27EF).contains(v) || (0x2980...0x2AFF).contains(v) || (0x0391...0x03C9).contains(v)
                || mathSymbols.contains(c) || v > 0xFFFF {
                return true // v > 0xFFFF: mathematical alphanumerics (U+1D400…) and other symbols outside the basic plane
            }
        }
        return false
    }

    static func isCjk(_ c: Character?) -> Bool {
        guard let v = c?.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFF00...0xFFEF).contains(v) || (0x3000...0x303F).contains(v)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Finds the text blocks of one page, in reading order.
    public static func analyze(_ pageGlyphs: [PdfGlyph], pageWidth: Double, pageHeight: Double) -> [PdfBlock] {
        let glyphs = clean(pageGlyphs, width: pageWidth, height: pageHeight)
        guard !glyphs.isEmpty else { return [] }
        let bodySize = median(glyphs.map(\.fontSize))
        let rows = buildRows(glyphs)
        var lines = splitRows(rows)
        let gutter = findGutter(lines, pageWidth: pageWidth)
        if let gutter {
            lines = lines.flatMap { splitAtGutter($0, gutter) }
        }
        var groups: [String: [PdfLine]] = [:]
        for line in lines {
            let side = gutter.map { line.x1 <= $0 ? -1 : line.x0 >= $0 ? 1 : 0 } ?? 0
            groups["\(line.row)|\(side)", default: []].append(line)
        }
        for group in groups.values {
            if group.count > 1 {
                for line in group {
                    line.tabular = true
                }
            }
            // Display formulas, with or without an equation number such as "(1)" further right on their row.
            let numbers = group.filter(isEquationNumber)
            for line in group where !numbers.contains(where: { $0 === line }) {
                line.formula = looksLikeFormula(line, numbered: numbers.contains { $0.x0 > line.x1 })
            }
            for number in numbers {
                number.formula = group.contains { $0.formula && $0.x1 < number.x0 }
            }
        }
        let blocks = buildBlocks(lines)
        for block in blocks {
            describe(block, pageWidth: pageWidth)
        }
        return order(blocks, gutter: gutter, bodySize: bodySize)
    }

    /// Drops spaces, empty boxes and characters drawn twice on top of each other (a common fake-bold trick).
    private static func clean(_ glyphs: [PdfGlyph], width: Double, height: Double) -> [PdfGlyph] {
        var result: [PdfGlyph] = []
        var seen: [String: [PdfGlyph]] = [:]
        for glyph in glyphs {
            if glyph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || glyph.x1 <= glyph.x0 || glyph.y1 <= glyph.y0 || glyph.fontSize <= 0.5 {
                continue
            }
            if glyph.x1 < -10 || glyph.x0 > width + 10 || glyph.y1 < -10 || glyph.y0 > height + 10 {
                continue
            }
            let near = 0.15 * glyph.fontSize
            if seen[glyph.text, default: []].contains(where: { abs($0.x0 - glyph.x0) < near && abs($0.y0 - glyph.y0) < near }) {
                continue
            }
            seen[glyph.text, default: []].append(glyph)
            result.append(glyph)
        }
        return result
    }

    /// Groups characters whose vertical centers agree, then folds superscripts and subscripts into the row they belong to.
    private static func buildRows(_ glyphs: [PdfGlyph]) -> [[PdfGlyph]] {
        // Characters of one line share a centre (their boxes span the font's height); lines are a font size or more apart.
        let sorted = glyphs.sorted { $0.centerY != $1.centerY ? $0.centerY > $1.centerY : $0.x0 < $1.x0 }
        var rows: [[PdfGlyph]] = []
        var current: [PdfGlyph] = []
        var previous: PdfGlyph?
        for glyph in sorted {
            if let previous, !current.isEmpty, previous.centerY - glyph.centerY <= 0.3 * max(previous.fontSize, glyph.fontSize) {
                current.append(glyph)
            } else {
                if !current.isEmpty {
                    rows.append(current)
                }
                current = [glyph]
            }
            previous = glyph
        }
        if !current.isEmpty {
            rows.append(current)
        }

        // A glyph clearly smaller than a neighbouring row, overlapping it vertically and close to one of its
        // glyphs horizontally, is a superscript or subscript of that row (citations¹, x_i).
        let rowSize = rows.map { median($0.map(\.fontSize)) }
        for r in rows.indices {
            for i in stride(from: rows[r].count - 1, through: 0, by: -1) {
                let glyph = rows[r][i]
                for q in max(0, r - 2)...min(rows.count - 1, r + 2) {
                    if q == r || rows[q].isEmpty || rowSize[q] < glyph.fontSize * 1.15 {
                        continue
                    }
                    let top = min(glyph.y1, rows[q].map(\.y1).max()!)
                    let bottom = max(glyph.y0, rows[q].map(\.y0).min()!)
                    if top - bottom < 0.3 * glyph.height {
                        continue
                    }
                    let reach = 1.5 * rowSize[q]
                    if !rows[q].contains(where: { glyph.x0 - $0.x1 < reach && $0.x0 - glyph.x1 < reach }) {
                        continue
                    }
                    rows[q].append(glyph)
                    rows[r].remove(at: i)
                    break
                }
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    /// Splits each row where the horizontal gap is wider than a word space: columns, table cells, side notes.
    private static func splitRows(_ rows: [[PdfGlyph]]) -> [PdfLine] {
        var lines: [PdfLine] = []
        for (r, row) in rows.enumerated() {
            let ordered = row.sorted { $0.x0 < $1.x0 }
            let size = median(ordered.map(\.fontSize))
            var current: [PdfGlyph] = []
            var right = -Double.greatestFiniteMagnitude
            for glyph in ordered {
                if !current.isEmpty && glyph.x0 - right > 1.0 * size {
                    lines.append(PdfLine(current, row: r))
                    current = []
                    right = -Double.greatestFiniteMagnitude
                }
                current.append(glyph)
                right = max(right, glyph.x1)
            }
            if !current.isEmpty {
                lines.append(PdfLine(current, row: r))
            }
        }
        for line in lines {
            let text = line.glyphs.filter { !isMathGlyph($0) }
            line.fontSize = text.isEmpty ? line.glyphs[0].fontSize : median(text.map(\.fontSize))
            line.bold = line.glyphs.filter(\.isBold).count * 2 > line.glyphs.count
        }
        return lines
    }

    /// The gap between two columns: an x position in the middle of the page that few lines cross while many
    /// lines lie entirely on either side of it.
    private static func findGutter(_ lines: [PdfLine], pageWidth: Double) -> Double? {
        let body = lines.filter { $0.glyphs.count >= 8 }
        guard body.count >= 6 else { return nil }
        var best: Double?
        var bestCrossing = Int.max
        var x = pageWidth * 0.3
        while x <= pageWidth * 0.7 {
            var crossing = 0, left = 0, right = 0
            for line in body {
                if line.x1 <= x {
                    left += 1
                } else if line.x0 >= x {
                    right += 1
                } else {
                    crossing += 1
                }
            }
            // Titles, abstracts and wide figures cross the gap on some pages, so allow a share of crossing lines.
            let count = Double(body.count)
            if Double(left) >= count * 0.25 && Double(right) >= count * 0.25 && Double(crossing) <= count * 0.2
                && (crossing < bestCrossing || (crossing == bestCrossing && best.map { abs(x - pageWidth / 2) < abs($0 - pageWidth / 2) } == true)) {
                bestCrossing = crossing
                best = x
            }
            x += 1
        }
        return best
    }

    /// A line that runs across the column gap with a space at the gap is two lines (narrow gutters).
    private static func splitAtGutter(_ line: PdfLine, _ gutter: Double) -> [PdfLine] {
        if line.x0 >= gutter || line.x1 <= gutter {
            return [line]
        }
        let left = line.glyphs.filter { ($0.x0 + $0.x1) / 2 < gutter }
        let right = line.glyphs.filter { ($0.x0 + $0.x1) / 2 >= gutter }
        guard !left.isEmpty, !right.isEmpty, right.map(\.x0).min()! - left.map(\.x1).max()! >= 0.3 * line.fontSize else { return [line] }
        return [left, right].map {
            let part = PdfLine($0, row: line.row)
            part.fontSize = line.fontSize
            part.bold = line.bold
            return part
        }
    }

    /// "(1)", "(2a)", "(3.12)", "(A.1)": the number of a display formula.
    private static func isEquationNumber(_ line: PdfLine) -> Bool {
        let text = line.glyphs.sorted { $0.x0 < $1.x0 }.map(\.text).joined()
        return text.range(of: #"^\((?:[A-Z]\.?)?\d{1,3}(?:[.\-]\d{1,3})*[a-z]?\)$"#, options: .regularExpression) != nil
    }

    /// A line of a display formula: a relation sign with symbols, sub/superscripts or operators around it and
    /// (next to) no ordinary words, or anything mathematical in front of an equation number.
    private static func looksLikeFormula(_ line: PdfLine, numbered: Bool) -> Bool {
        let glyphs = line.glyphs.sorted { $0.x0 < $1.x0 }
        let text = glyphs.filter { !isMathGlyph($0) }
        // The full size: sub/superscripts may outnumber the characters they belong to.
        let size = (text.isEmpty ? glyphs : text).map(\.fontSize).max() ?? 0
        let math = glyphs.filter(isMathGlyph).count
        let relationCount = glyphs.filter { $0.text.contains(where: relations.contains) }.count
        let operatorCount = glyphs.filter { $0.text.contains(where: operators.contains) }.count
        var scripts = 0, words = 0, letters = 0
        var inScript = false
        for i in 0...glyphs.count {
            var plainLetter = false
            if i < glyphs.count {
                let glyph = glyphs[i]
                let small = glyph.fontSize < 0.85 * size
                if small && !inScript {
                    scripts += 1
                }
                inScript = small
                plainLetter = !small && !isMathGlyph(glyph) && glyph.text.allSatisfy(\.isLetter)
                if plainLetter && letters > 0 && glyph.x0 - glyphs[i - 1].x1 > 0.15 * size {
                    words += letters >= 4 ? 1 : 0
                    letters = 0
                }
            }
            // Ordinary words: four or more full-size letters in a row (variables are single letters, functions short).
            if !plainLetter {
                words += letters >= 4 ? 1 : 0
                letters = 0
            } else {
                letters += glyphs[i].text.count
            }
        }
        if words >= 3 {
            return false
        }
        let symbols = math + scripts + operatorCount
        if numbered {
            return relationCount + symbols >= 1
        }
        return relationCount >= 1 && ((symbols >= 2 && words == 0) || (symbols >= 4 && words <= 1))
    }

    private static func startsWithBullet(_ line: PdfLine) -> Bool {
        let text = Array(line.glyphs.prefix(4).map(\.text).joined())
        guard let first = text.first else { return false }
        if bullets.contains(first) {
            return true
        }
        // "1.", "2)", "(a)", "[3]", "a)"
        var i = 0
        if first == "(" || first == "[" {
            i += 1
        }
        let start = i
        while i < text.count && (text[i].isNumber || (i == start && text[i].isLetter && text.count > i + 1 && !text[i + 1].isLetter)) {
            i += 1
        }
        return i > start && i < text.count && [".", ")", "]"].contains(text[i]) && !(i + 1 < text.count && text[i + 1].isNumber)
    }

    /// Stacks lines into paragraphs: close below each other, overlapping horizontally, same size and weight.
    private static func buildBlocks(_ lines: [PdfLine]) -> [PdfBlock] {
        var blocks: [PdfBlock] = []
        let sorted = lines.sorted { $0.y1 != $1.y1 ? $0.y1 > $1.y1 : $0.x0 < $1.x0 }
        for line in sorted {
            var target: PdfBlock?
            var bestGap = Double.greatestFiniteMagnitude
            for block in blocks {
                let last = block.lines[block.lines.count - 1]
                let size = max(block.fontSize, line.fontSize)
                let gap = last.y0 - line.y1
                if gap < -0.4 * size || gap > 0.9 * size {
                    continue
                }
                if abs(line.fontSize - block.fontSize) > 0.1 * block.fontSize || line.bold != block.bold {
                    continue
                }
                // Table cells and labels sit next to other text on the same row; they don't continue each other.
                // Nor do formulas and the text around them.
                if line.tabular || last.tabular || line.formula != last.formula {
                    continue
                }
                let overlap = min(block.x1, line.x1) - max(block.x0, line.x0)
                if overlap < 0.5 * min(block.x1 - block.x0, line.x1 - line.x0) {
                    continue
                }
                // A new paragraph: an indented first line after lines that start at the margin, or a list item.
                let margin = block.x0
                if block.lines.count >= 2 && line.x0 - margin > 0.8 * line.fontSize && last.x0 - margin < 0.3 * line.fontSize {
                    continue
                }
                if startsWithBullet(line) {
                    continue
                }
                if gap < bestGap {
                    bestGap = gap
                    target = block
                }
            }
            if target == nil {
                let block = PdfBlock()
                block.fontSize = line.fontSize
                block.bold = line.bold
                blocks.append(block)
                target = block
            }
            target!.add(line)
        }
        return blocks
    }

    /// Text, inline formulas, font, colour and alignment of a block.
    private static func describe(_ block: PdfBlock, pageWidth: Double) {
        let glyphs = block.lines.flatMap(\.glyphs)
        let math = glyphs.filter(isMathGlyph).count
        let letters = glyphs.filter { !isMathGlyph($0) && $0.text.contains(where: \.isLetter) }.count
        block.isFormula = block.lines.allSatisfy(\.formula) || Double(math) >= 0.4 * Double(glyphs.count) || (math > 0 && letters <= 3)
        var textGlyphs = glyphs.filter { !isMathGlyph($0) }
        if textGlyphs.isEmpty {
            textGlyphs = [glyphs[0]]
        }
        block.fontSize = median(textGlyphs.map(\.fontSize))
        block.bold = textGlyphs.filter(\.isBold).count * 2 > textGlyphs.count
        block.italic = textGlyphs.filter { isItalicFont($0.fontName) }.count * 2 > textGlyphs.count
        block.serif = textGlyphs.filter { isSerifFont($0.fontName) }.count * 2 > textGlyphs.count
        var colors: [Int: Int] = [:]
        var firstSeen: [Int] = []
        for glyph in textGlyphs {
            if colors[glyph.color] == nil {
                firstSeen.append(glyph.color)
            }
            colors[glyph.color, default: 0] += 1
        }
        block.color = firstSeen.max { colors[$0]! < colors[$1]! } ?? 0

        let lines = block.lines
        // Measured on characters of the line's own size, so superscripts don't skew it.
        func middle(_ line: PdfLine) -> Double {
            let own = line.glyphs.filter { abs($0.fontSize - line.fontSize) <= 0.1 * line.fontSize }.map(\.centerY)
            return own.isEmpty ? line.glyphs[0].centerY : median(own)
        }
        block.linePitch = lines.count >= 2
            ? min(max((middle(lines[0]) - middle(lines[lines.count - 1])) / Double(lines.count - 1), 0.9 * block.fontSize), 2.5 * block.fontSize)
            : 1.2 * block.fontSize

        let x0 = block.x0, x1 = block.x1, width = x1 - x0
        if lines.count >= 2 {
            let indent = lines[0].x0 - x0
            if indent > 0.5 * block.fontSize && indent < 4 * block.fontSize {
                block.firstLineIndent = indent
            }
            let symmetric = lines.allSatisfy { abs(($0.x0 - x0) - (x1 - $0.x1)) < 2.5 }
            block.centered = symmetric && lines.contains { $0.x1 - $0.x0 < width - 6 }
            // With two lines the first one defines the right edge, so it takes three to tell.
            block.justified = !block.centered && lines.count >= 3
                && Double(lines.dropLast().filter { x1 - $0.x1 < 2.0 }.count) >= 0.7 * Double(lines.count - 1)
        } else {
            block.centered = abs((x0 + x1) / 2 - pageWidth / 2) < pageWidth * 0.03 && width < pageWidth * 0.7
        }
        var atoms: [Int: PdfAtom] = [:]
        block.pieces = buildPieces(lines, atoms: &atoms)
        block.atoms = atoms
    }

    /// The block's text: spaces where the gap between characters is wide, hyphenation at line ends undone, bold and
    /// italic text as styles, and inline formulas and sub/superscripts as objects that keep their characters' positions.
    private static func buildPieces(_ lines: [PdfLine], atoms: inout [Int: PdfAtom]) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        var text = ""
        var style = 0
        var word: [PdfGlyph] = [] // the characters of the word at the end of text
        var formula: [PdfGlyph] = []
        var formulaText = ""
        var baseline = 0.0
        var last: Character?

        func flushText() {
            if !text.isEmpty {
                pieces.append(.of(text, style))
            }
            text = ""
            word = []
        }

        func flushFormula() {
            guard let first = formula.first else { return }
            flushText()
            let x0 = first.x0
            let atom = atoms.count
            atoms[atom] = PdfAtom(width: formula.map(\.x1).max()! - x0, glyphs: formula.map {
                PdfAtomGlyph(text: $0.text, dx: $0.x0 - x0, dy: $0.y0 + 0.25 * $0.fontSize - baseline, fontSize: $0.fontSize, fontName: $0.fontName)
            })
            let value = formulaText
            pieces.append(.object(atom, value.trimmingCharacters(in: .whitespaces)))
            formula = []
            formulaText = ""
            if value.hasSuffix(" ") {
                text += " "
            }
        }

        func startFormula(takeWord: Bool) {
            // A subscript or superscript takes the short word it is attached to: V + cell, x + 2.
            let taken = takeWord && (1...2).contains(word.count) ? word : []
            text.removeLast(taken.reduce(0) { $0 + $1.text.count })
            flushText()
            for glyph in taken {
                formula.append(glyph)
                formulaText += glyph.text
            }
        }

        func space() {
            word = []
            if !formula.isEmpty {
                formulaText += " "
            } else if let end = text.last, end != " " {
                text += " "
            } else if text.isEmpty && !pieces.isEmpty {
                text += " "
            }
        }

        for (l, line) in lines.enumerated() {
            let glyphs = line.glyphs.sorted { $0.x0 < $1.x0 }
            let size = line.fontSize
            if l > 0, let first = glyphs.first?.text.first {
                // An inline formula ends with its line, so its characters keep their places relative to each other.
                flushFormula()
                // "trans-" + "lation" → "translation"; CJK lines join without a space.
                if last == "-" && first.isLowercase && text.count > 1 && text.dropLast().last?.isLetter == true {
                    text.removeLast()
                } else if !(isCjk(last) && isCjk(first)) {
                    space()
                }
                word = []
            }
            let mainSize = glyphs.filter { abs($0.fontSize - size) <= 0.1 * size }.map { $0.y0 + 0.25 * $0.fontSize }
            baseline = mainSize.isEmpty ? glyphs[0].y0 + 0.25 * glyphs[0].fontSize : median(mainSize)
            for (i, glyph) in glyphs.enumerated() {
                if i > 0 {
                    let gap = glyph.x0 - glyphs[i - 1].x1
                    if gap > 0.15 * size && !(isCjk(glyphs[i - 1].text.last) && isCjk(glyph.text.first)) {
                        space()
                    }
                }
                let math = isMathGlyph(glyph)
                let script = glyph.fontSize < 0.85 * size && !isCjk(glyph.text.first)
                if math || script {
                    if formula.isEmpty {
                        startFormula(takeWord: script && !math)
                    }
                    formula.append(glyph)
                    formulaText += glyph.text
                } else if !formula.isEmpty && !glyph.text.contains(where: \.isLetter) && glyph.text != "," && glyph.text != "." {
                    // Plain digits and symbols right after a formula symbol (x², f(x) = …) keep the formula together.
                    formula.append(glyph)
                    formulaText += glyph.text
                } else {
                    flushFormula()
                    let glyphStyle = (glyph.isBold ? 1 : 0) | (isItalicFont(glyph.fontName) ? 2 : 0)
                    if glyphStyle != style {
                        // A space left over from before takes the new style rather than becoming a piece of its own.
                        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            flushText()
                        }
                        style = glyphStyle
                    }
                    text += glyph.text
                    word.append(glyph)
                }
                last = glyph.text.last
            }
        }
        flushFormula()
        flushText()
        if let end = pieces.last, !end.isAtom {
            var trimmed = end.text
            while trimmed.last?.isWhitespace == true {
                trimmed.removeLast()
            }
            pieces[pieces.count - 1] = .of(trimmed, end.style)
        }
        return pieces
    }

    /// Reading order: blocks spanning both columns cut the page into bands; in each band the left column comes first.
    private static func order(_ blocks: [PdfBlock], gutter: Double?, bodySize: Double) -> [PdfBlock] {
        guard let g = gutter else {
            let unit = max(1, bodySize * 0.5)
            return blocks.sorted {
                let a = ($0.y1 / unit).rounded(), b = ($1.y1 / unit).rounded()
                return a != b ? a > b : $0.x0 < $1.x0
            }
        }
        var result: [PdfBlock] = []
        var band: [PdfBlock] = []
        func flushBand() {
            result += band.filter { $0.x1 <= g + 1 }.sorted { $0.y1 > $1.y1 }
            result += band.filter { $0.x1 > g + 1 }.sorted { $0.y1 > $1.y1 }
            band = []
        }
        for block in blocks.sorted(by: { $0.y1 > $1.y1 }) {
            if block.x0 < g - 1 && block.x1 > g + 1 {
                flushBand()
                result.append(block)
            } else {
                band.append(block)
            }
        }
        flushBand()
        return result
    }
}
