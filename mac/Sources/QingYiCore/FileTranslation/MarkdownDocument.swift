import Foundation

/// Markdown: headings, paragraphs, list items, quotes and table cells are translated; code blocks, math blocks,
/// front matter, HTML blocks and link definitions stay as they are. Inside the text, code spans, inline math,
/// URLs and HTML tags are kept exactly.
public final class MarkdownDocument: TranslatableDocument {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let inlineKeep = regex([
        "(?<t>`+)(?:(?!\\k<t>).)+?\\k<t>(?!`)",                              // `code`
        "\\$\\$[^$]+\\$\\$",                                                  // $$math$$ within a line
        "(?<![\\\\\\w$])\\$(?=[^\\s$])[^$\\n]*?[^\\s\\\\$]\\$(?![\\w$])",     // $math$
        "<!--.*?-->",
        "<(?:https?|ftp|mailto):[^<>\\s]+>",                                 // <https://…>
        "</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>]*)?/?>",                          // <br>, <sup>…
        "(?<=\\])\\((?:[^()\\s]|\\([^()\\s]*\\))*(?:\\s+(?:\"[^\"]*\"|'[^']*'))?\\s*\\)", // ](url "title")
        "(?<=\\])\\[[^\\]]*\\]",                                              // [text][ref]
        "\\[\\^[^\\]]+\\]",                                                   // [^1]
        "\\{#[^}\\s]*\\}",                                                    // {#heading-id}
        "\\b(?:https?|ftp)://[^\\s<>()\\[\\]]*[^\\s<>()\\[\\].,;:!?'\"]",     // bare URL
    ].joined(separator: "|"))

    private static let fence = regex("^(\\s{0,3})(`{3,}|~{3,})")
    private static let atxHeading = regex("^(\\s{0,3}#{1,6})([ \\t]+)(.*?)([ \\t]+#+[ \\t]*)?$")
    private static let setextUnderline = regex("^\\s{0,3}(=+|-+)\\s*$")
    private static let rule = regex("^\\s{0,3}([-*_])(?:\\s*\\1){2,}\\s*$")
    private static let listItem = regex("^(\\s*(?:[-*+]|\\d{1,9}[.)])[ \\t]+(?:\\[[ xX]\\][ \\t]+)?)(.*)$")
    private static let quote = regex("^(\\s{0,3}>[ \\t]?(?:>[ \\t]?)*)(.*)$")
    private static let htmlBlock = regex(
        "^\\s{0,3}(?:<!--|</?(?:address|article|aside|blockquote|center|details|dialog|div|dl|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|iframe|li|main|nav|ol|p|picture|pre|script|section|style|summary|table|tbody|td|tfoot|th|thead|tr|ul|video)(?:[\\s/>]|$)|</?[A-Za-z][A-Za-z0-9-]*(?:\\s[^<>]*)?/?>\\s*$)",
        [.caseInsensitive])
    private static let linkDefinition = regex("^\\s{0,3}\\[[^\\]]+\\]:\\s*\\S")
    private static let tableSeparator = regex("^\\s*\\|?\\s*:?-+:?\\s*(?:\\|\\s*:?-+:?\\s*)*\\|?\\s*$")
    private static let unescapedPipe = regex("(?<!\\\\)\\|")

    private enum Part {
        case literal(String)
        /// One or more lines of translated text; the first line gets `first`, the others `next`.
        case block(segment: Int, first: String, next: String, suffix: String, atoms: [String])
        case row([TextPart])
    }

    private let file: TextFile
    private var parts: [Part] = []
    private var titleSeen = false

    public init(url: URL) throws {
        file = try TextFile.read(url)
        super.init(sourceURL: url)
        parse(file.text.components(separatedBy: "\n"))
    }

    public override var promptHint: String? {
        "The segments are Markdown. Keep emphasis markers (**, *, _, ~~), link brackets and other Markdown syntax around the corresponding translated words."
    }

    private static func match(_ pattern: NSRegularExpression, _ line: String) -> [String]? {
        let source = line as NSString
        guard let result = pattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return nil }
        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : source.substring(with: range)
        }
    }

    private static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    private func parse(_ lines: [String]) {
        var i = 0
        // YAML front matter.
        if lines.count > 1 && lines[0].trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }) {
            while i <= end {
                parts.append(.literal(lines[i]))
                i += 1
            }
        }

        var previousBlank = true
        var inList = false
        while i < lines.count {
            let line = lines[i]
            let trimmedStart = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if MarkdownDocument.isBlank(line) {
                parts.append(.literal(line))
                previousBlank = true
                i += 1
                continue
            }

            if let fence = MarkdownDocument.match(MarkdownDocument.fence, line) {
                let marker = fence[2]
                parts.append(.literal(line))
                i += 1
                while i < lines.count {
                    parts.append(.literal(lines[i]))
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if trimmed.count >= marker.count && trimmed.allSatisfy({ $0 == marker.first! }) {
                        break
                    }
                }
            } else if trimmedStart.hasPrefix("$$") {
                // A math block runs until the line that ends with $$ (possibly the same one).
                let rest = String(trimmedStart.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                parts.append(.literal(line))
                i += 1
                if !rest.hasSuffix("$$") {
                    while i < lines.count {
                        parts.append(.literal(lines[i]))
                        let ends = lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("$$")
                        i += 1
                        if ends {
                            break
                        }
                    }
                }
            } else if previousBlank && !inList && MarkdownDocument.isIndentedCode(line) {
                while i < lines.count && (MarkdownDocument.isBlank(lines[i]) || MarkdownDocument.isIndentedCode(lines[i])) {
                    parts.append(.literal(lines[i]))
                    i += 1
                }
            } else if trimmedStart.hasPrefix("<!--") {
                // A comment runs to the line that closes it.
                while i < lines.count {
                    parts.append(.literal(lines[i]))
                    let closes = lines[i].contains("-->")
                    i += 1
                    if closes {
                        break
                    }
                }
            } else if MarkdownDocument.htmlBlock.matchesAll(line) || MarkdownDocument.rule.matchesAll(line) || MarkdownDocument.linkDefinition.matchesAll(line) {
                // Other HTML blocks run to the next blank line.
                let html = MarkdownDocument.htmlBlock.matchesAll(line)
                parts.append(.literal(line))
                i += 1
                while html && i < lines.count && !MarkdownDocument.isBlank(lines[i]) {
                    parts.append(.literal(lines[i]))
                    i += 1
                }
            } else if line.contains("|") && i + 1 < lines.count && MarkdownDocument.tableSeparator.matchesAll(lines[i + 1]) && lines[i + 1].contains("-") {
                addRow(lines[i])
                parts.append(.literal(lines[i + 1]))
                i += 2
                while i < lines.count && !MarkdownDocument.isBlank(lines[i]) && lines[i].contains("|") {
                    addRow(lines[i])
                    i += 1
                }
            } else if let heading = MarkdownDocument.match(MarkdownDocument.atxHeading, line) {
                let title = heading[1].trimmingCharacters(in: .whitespaces) == "#" && !titleSeen
                addBlock(heading[3], first: heading[1] + heading[2], next: "", suffix: heading[4], role: title ? .title : .heading)
                inList = false
                i += 1
            } else if let quote = MarkdownDocument.match(MarkdownDocument.quote, line) {
                let prefix = quote[1]
                var content: [String] = []
                while i < lines.count, !MarkdownDocument.isBlank(lines[i]), let next = MarkdownDocument.match(MarkdownDocument.quote, lines[i]) {
                    content.append(next[2])
                    i += 1
                }
                addBlock(content.joined(separator: "\n"), first: prefix, next: prefix, suffix: "", role: .body)
            } else if let item = MarkdownDocument.match(MarkdownDocument.listItem, line) {
                let prefix = item[1]
                var content = [item[2]]
                i += 1
                while i < lines.count && !MarkdownDocument.isBlank(lines[i]) && !startsBlock(lines[i]) {
                    content.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                addBlock(content.joined(separator: "\n"), first: prefix, next: String(repeating: " ", count: (prefix as NSString).length), suffix: "", role: .body)
                inList = true
            } else {
                // A paragraph, or a setext heading (a line underlined with === or ---).
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                var content = [line.trimmingCharacters(in: .whitespaces)]
                i += 1
                while i < lines.count && !MarkdownDocument.isBlank(lines[i]) && !startsBlock(lines[i])
                        && !MarkdownDocument.setextUnderline.matchesAll(lines[i]) {
                    content.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                if i < lines.count && MarkdownDocument.setextUnderline.matchesAll(lines[i]) && content.count == 1 {
                    let title = lines[i].trimmingCharacters(in: .whitespaces).first == "=" && !titleSeen
                    addBlock(content[0], first: indent, next: indent, suffix: "", role: title ? .title : .heading)
                    parts.append(.literal(lines[i]))
                    i += 1
                } else {
                    addBlock(content.joined(separator: "\n"), first: indent, next: indent, suffix: "", role: .body)
                }
                if indent.isEmpty {
                    inList = false
                }
            }
            previousBlank = false
        }
    }

    private static func isIndentedCode(_ line: String) -> Bool { line.hasPrefix("    ") || line.hasPrefix("\t") }

    private func startsBlock(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        return MarkdownDocument.fence.matchesAll(line) || MarkdownDocument.atxHeading.matchesAll(line) || MarkdownDocument.quote.matchesAll(line)
            || MarkdownDocument.listItem.matchesAll(line) || MarkdownDocument.rule.matchesAll(line) || MarkdownDocument.htmlBlock.matchesAll(line)
            || trimmed.hasPrefix("$$") || trimmed.hasPrefix("|")
    }

    private func addBlock(_ content: String, first: String, next: String, suffix: String, role: SegmentRole) {
        guard TranslatableDocument.hasWords(MarkdownDocument.inlineKeep.replaceAll(in: content, with: " ")) else {
            parts.append(.literal(first + content.replacingOccurrences(of: "\n", with: "\n" + next) + suffix))
            return
        }
        if role == .title {
            titleSeen = true
        }
        let (pieces, atoms) = ProtectedText.split(content, keep: MarkdownDocument.inlineKeep)
        parts.append(.block(segment: addSegment(pieces, role: role).id, first: first, next: next, suffix: suffix, atoms: atoms))
    }

    private func addRow(_ line: String) {
        var cells: [TextPart] = []
        var current = ""
        var code = false
        func flush(separator: Bool) {
            let cell = current
            current = ""
            let core = cell.trimmingCharacters(in: .whitespaces)
            if TranslatableDocument.hasWords(MarkdownDocument.inlineKeep.replaceAll(in: core, with: " ")) {
                let lead = String(cell.prefix(while: { $0 == " " || $0 == "\t" }))
                let trail = String(cell.dropFirst(lead.count + core.count))
                let (pieces, atoms) = ProtectedText.split(core, keep: MarkdownDocument.inlineKeep)
                cells.append(TextPart(literal: lead))
                cells.append(TextPart(literal: "", segment: addSegment(pieces, role: .other).id, atoms: atoms))
                cells.append(TextPart(literal: trail))
            } else {
                cells.append(TextPart(literal: cell))
            }
            if separator {
                cells.append(TextPart(literal: "|"))
            }
        }
        var previous: Character?
        for c in line {
            if c == "`" {
                code.toggle()
            }
            if c == "|" && !code && previous != "\\" {
                flush(separator: true)
            } else {
                current.append(c)
            }
            previous = c
        }
        flush(separator: false)
        parts.append(.row(cells))
    }

    private func translated(_ segment: Int, _ atoms: [String], _ translations: [Int: String]) -> String {
        let tagged = segments[segment].text
        return ProtectedText.restore(tagged, translations[segment] ?? tagged.text, atoms).replacingOccurrences(of: "\r\n", with: "\n")
    }

    public override func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        var lines: [String] = []
        for part in parts {
            switch part {
            case .literal(let line):
                lines.append(line)
            case let .block(segment, first, next, suffix, atoms):
                // Blank lines inside a block would end it (and break a list or quote).
                var translatedLines = translated(segment, atoms, translations).components(separatedBy: "\n")
                    .filter { !MarkdownDocument.isBlank($0) }
                if translatedLines.isEmpty {
                    translatedLines = [""]
                }
                for (index, text) in translatedLines.enumerated() {
                    lines.append((index == 0 ? first : next) + text.trimmingCharacters(in: .whitespaces)
                                 + (index == translatedLines.count - 1 ? suffix : ""))
                }
            case .row(let cells):
                var text = ""
                for cell in cells {
                    if cell.segment < 0 {
                        text += cell.literal
                    } else {
                        let value = translated(cell.segment, cell.atoms, translations).replacingOccurrences(of: "\n", with: " ")
                        text += MarkdownDocument.unescapedPipe.replaceAll(in: value, with: "\\\\|")
                    }
                }
                lines.append(text)
            }
        }
        try TranslatableDocument.writeAtomically(to: url) { try file.write(lines.joined(separator: "\n"), to: $0) }
    }
}
