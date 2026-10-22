import Foundation

extension NSRegularExpression {
    /// All matches in the whole string.
    func allMatches(in text: String) -> [NSTextCheckingResult] {
        matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    func replaceAll(in text: String, with template: String) -> String {
        stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    func matchesAll(_ text: String) -> Bool {
        firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}

/// Reads a text file in UTF-8/UTF-16 or a legacy code page, and writes it back with the same line breaks.
struct TextFile {
    /// The content with "\n" line breaks.
    let text: String
    private let byteOrderMark: Bool
    private let utf8: Bool
    private let newline: String

    static func read(_ url: URL) throws -> TextFile {
        let data = try Data(contentsOf: url)
        var bom = false
        var utf8 = true
        var text: String
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            bom = true
            text = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if data.starts(with: [0xFF, 0xFE]) {
            bom = true
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        } else if data.starts(with: [0xFE, 0xFF]) {
            bom = true
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = decodeLegacy(data)
            utf8 = false
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return TextFile(text: text, byteOrderMark: bom, utf8: utf8, newline: newline)
    }

    /// Most non-UTF-8 files our users meet are GBK/GB 18030 (Chinese Windows); otherwise Windows-1252.
    private static func decodeLegacy(_ data: Data) -> String {
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let chinese = String(data: data, encoding: String.Encoding(rawValue: gb18030)),
           chinese.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            return chinese
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Writes UTF-8. A file that wasn't UTF-8 gets a byte order mark, so editors still recognize it.
    func write(_ text: String, to url: URL) throws {
        var data = Data()
        if byteOrderMark || !utf8 {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(Data((newline == "\n" ? text : text.replacingOccurrences(of: "\n", with: newline)).utf8))
        try data.write(to: url)
    }
}

/// Splits a line of text into words to translate and parts that must stay exactly as they are (code, URLs, tags),
/// and puts the parts back into the translation.
enum ProtectedText {
    static func split(_ text: String, keep: NSRegularExpression) -> (pieces: [InlinePiece], atoms: [String]) {
        let source = text as NSString
        var pieces: [InlinePiece] = []
        var atoms: [String] = []
        var position = 0
        for match in keep.allMatches(in: text) where match.range.length > 0 {
            if match.range.location > position {
                pieces.append(.of(source.substring(with: NSRange(location: position, length: match.range.location - position)), 0))
            }
            let value = source.substring(with: match.range)
            pieces.append(.object(atoms.count, value))
            atoms.append(value)
            position = match.range.location + match.range.length
        }
        if position < source.length {
            pieces.append(.of(source.substring(from: position), 0))
        }
        return (pieces, atoms)
    }

    /// The translation with each placeholder replaced by its original; any the model dropped are added at the end.
    static func restore(_ tagged: TaggedText, _ translation: String, _ atoms: [String]) -> String {
        var result = ""
        var used = Set<Int>()
        for piece in tagged.parse(translation) {
            if !piece.isAtom {
                result += piece.text
            } else if piece.atom < atoms.count && used.insert(piece.atom).inserted {
                result += atoms[piece.atom]
            }
        }
        for (index, atom) in atoms.enumerated() where !used.contains(index) {
            if let last = result.last, !last.isWhitespace {
                result += " "
            }
            result += atom
        }
        return result
    }
}

/// A part of a text file: kept as it is (`segment` -1), or a segment with the protected parts it contains.
struct TextPart {
    var literal: String
    var segment: Int = -1
    var atoms: [String] = []
}

let paragraphBreak = try! NSRegularExpression(pattern: "\\n[ \\t]*\\n(?:[ \\t]*\\n)*")

/// Calls `handle` for every chunk between the separators matched by `pattern`, and `gap` for every separator.
func splitKeeping(_ text: String, _ pattern: NSRegularExpression, handle: (String) -> Void, gap: (String) -> Void) {
    let source = text as NSString
    var position = 0
    for match in pattern.allMatches(in: text) {
        handle(source.substring(with: NSRange(location: position, length: match.range.location - position)))
        gap(source.substring(with: match.range))
        position = match.range.location + match.range.length
    }
    handle(source.substring(from: position))
}

/// Plain text: each paragraph (separated by blank lines) is translated on its own.
public final class PlainTextDocument: TranslatableDocument {
    private static let urlPattern = try! NSRegularExpression(
        pattern: "\\b(?:https?|ftp)://[^\\s<>\"]+[^\\s<>\".,;:!?)\\]}'，。；：！？）】]|\\b[\\w.+-]+@[\\w-]+\\.[\\w.-]+\\w")

    private let file: TextFile
    private var parts: [TextPart] = []

    public init(url: URL) throws {
        file = try TextFile.read(url)
        super.init(sourceURL: url)
        splitKeeping(file.text, paragraphBreak, handle: addParagraph, gap: { parts.append(TextPart(literal: $0)) })
    }

    private func addParagraph(_ paragraph: String) {
        let core = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranslatableDocument.hasWords(core) else {
            parts.append(TextPart(literal: paragraph))
            return
        }
        let lead = String(paragraph.prefix(while: { $0.isWhitespace }))
        let trail = String(paragraph.reversed().prefix(while: { $0.isWhitespace }).reversed())
        parts.append(TextPart(literal: lead))
        let (pieces, atoms) = ProtectedText.split(core, keep: PlainTextDocument.urlPattern)
        // A short first line on its own is most likely the title.
        let role: SegmentRole = segments.isEmpty && core.count <= 120 && !core.contains("\n") ? .title : .body
        parts.append(TextPart(literal: "", segment: addSegment(pieces, role: role).id, atoms: atoms))
        parts.append(TextPart(literal: trail))
    }

    public override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        var text = ""
        for part in parts {
            if part.segment < 0 {
                text += part.literal
            } else {
                let tagged = segments[part.segment].text
                text += ProtectedText.restore(tagged, translations[part.segment] ?? tagged.text, part.atoms).replacingOccurrences(of: "\r\n", with: "\n")
            }
        }
        try TranslatableDocument.writeAtomically(to: url) { try file.write(text, to: $0) }
    }
}

/// SubRip subtitles: numbers and timings stay, each cue's text is translated.
public final class SubtitleDocument: TranslatableDocument {
    private static let tagPattern = try! NSRegularExpression(pattern: "</?[A-Za-z][^<>]*>|\\{\\\\[^{}]*\\}")

    private let file: TextFile
    private var parts: [TextPart] = []

    public init(url: URL) throws {
        file = try TextFile.read(url)
        super.init(sourceURL: url)
        splitKeeping(file.text, paragraphBreak, handle: addCue, gap: { parts.append(TextPart(literal: $0)) })
    }

    public override var promptHint: String? {
        "The segments are consecutive subtitle cues. A sentence may run across several cues: translate each cue's own part of it, so every cue still matches its timing. Keep cues short enough to read on screen."
    }

    private func addCue(_ block: String) {
        let lines = block.components(separatedBy: "\n")
        // "12" / "00:01:02,000 --> 00:01:04,500" / text…; some files leave out the number.
        let number = lines.first?.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{FEFF}"))) ?? ""
        let header = lines.count >= 2 && lines[1].contains("-->") && Int(number) != nil ? 2
            : lines.first?.contains("-->") == true ? 1
            : -1
        let cueText = header < 0 ? "" : lines[header...].joined(separator: "\n")
        guard header >= 0, TranslatableDocument.hasWords(cueText) else {
            parts.append(TextPart(literal: block))
            return
        }
        // The line break at the very end of the file belongs after the cue.
        var core = cueText
        while let last = core.last, last == "\n" || last == " " || last == "\t" {
            core.removeLast()
        }
        parts.append(TextPart(literal: lines[..<header].joined(separator: "\n") + "\n"))
        let (pieces, atoms) = ProtectedText.split(core, keep: SubtitleDocument.tagPattern)
        parts.append(TextPart(literal: "", segment: addSegment(pieces).id, atoms: atoms))
        parts.append(TextPart(literal: String(cueText.dropFirst(core.count))))
    }

    public override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        var text = ""
        for part in parts {
            if part.segment < 0 {
                text += part.literal
                continue
            }
            let tagged = segments[part.segment].text
            let restored = ProtectedText.restore(tagged, translations[part.segment] ?? tagged.text, part.atoms)
                .replacingOccurrences(of: "\r\n", with: "\n")
            // A blank line would end the cue early.
            text += restored.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        }
        try TranslatableDocument.writeAtomically(to: url) { try file.write(text, to: $0) }
    }
}
