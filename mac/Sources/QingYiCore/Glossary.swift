import Combine
import Foundation

/// Two equivalent terms. Works both ways: whichever side appears in the text is translated as the other.
/// The JSON keys match the Windows version, so a copied glossary.json loads as is.
public struct GlossaryEntry: Codable, Hashable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case target = "Target"
    }
}

/// The user's terminology, saved to glossary.json next to the settings.
public final class Glossary: ObservableObject {
    public static let maxEntries = 5000

    /// Only entries found in the text are sent, and at most this many, so a big glossary can't flood the prompt.
    public static let maxEntriesPerRequest = 80

    private static let maxTermLength = 200

    // First row of an exported or hand-made table, not a real entry.
    private static let headerRows: Set<String> = [
        "source|target", "term|translation", "source term|target term", "原文|译文", "术语|译法", "术语|译文",
    ]

    private let path: URL

    @Published public private(set) var entries: [GlossaryEntry]

    /// Changes whenever the entries do; part of the translation cache key, so edits take effect at once.
    public private(set) var version = 0

    private init(path: URL, entries: [GlossaryEntry]) {
        self.path = path
        self.entries = entries
    }

    public static func load() -> Glossary {
        let path = AppPaths.dataDirectory.appendingPathComponent("glossary.json")
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                let loaded = try AppPaths.makeDecoder().decode([GlossaryEntry].self, from: Data(contentsOf: path))
                return Glossary(path: path, entries: clean(loaded))
            } catch {
                Log.error("读取术语表失败", error)
                try? FileManager.default.removeItem(atPath: path.path + ".bak")
                try? FileManager.default.copyItem(atPath: path.path, toPath: path.path + ".bak") // keep the unreadable file
            }
        }
        return Glossary(path: path, entries: [])
    }

    @discardableResult
    public func replace(_ entries: [GlossaryEntry]) -> Bool {
        self.entries = Glossary.clean(entries)
        version += 1
        return save()
    }

    public func match(_ text: String) -> [GlossaryEntry] { Glossary.match(entries, text) }

    public static func match(_ entries: [GlossaryEntry], _ text: String) -> [GlossaryEntry] {
        var matches: [GlossaryEntry] = []
        for entry in entries where containsTerm(text, entry.source) || containsTerm(text, entry.target) {
            matches.append(entry)
            if matches.count == maxEntriesPerRequest {
                break
            }
        }
        return matches
    }

    /// Case-insensitive. A term that starts with a letter of a space-separated script must start a word,
    /// so "AI" doesn't match inside "email"; the end is left open so plurals still match.
    public static func containsTerm(_ text: String, _ term: String) -> Bool {
        guard let first = term.first else { return false }
        let needsWordStart = isSpacedWordChar(first)
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive], range: from..<text.endIndex) {
            if !needsWordStart || range.lowerBound == text.startIndex || !isSpacedWordChar(text[text.index(before: range.lowerBound)]) {
                return true
            }
            from = text.index(after: range.lowerBound)
        }
        return false
    }

    // Letters and digits of scripts that put spaces between words (Latin, Greek, Cyrillic, Arabic, Devanagari…); not CJK or Thai.
    static func isSpacedWordChar(_ c: Character) -> Bool {
        guard c.isLetter || c.isNumber, let value = c.unicodeScalars.first?.value else { return false }
        return value < 0x2E80 && !(0x0E00...0x0E7F).contains(value)
    }

    /// Trims terms, drops incomplete and duplicate entries.
    public static func clean(_ entries: [GlossaryEntry]) -> [GlossaryEntry] {
        var seen = Set<String>()
        var result: [GlossaryEntry] = []
        for entry in entries {
            let source = normalize(entry.source)
            let target = normalize(entry.target)
            if source.isEmpty || target.isEmpty || !seen.insert((source + "\u{1F}" + target).lowercased()).inserted {
                continue
            }
            result.append(GlossaryEntry(source: source, target: target))
            if result.count == maxEntries {
                break
            }
        }
        return result
    }

    static func normalize(_ term: String?) -> String {
        guard let term, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let parts = term.components(separatedBy: CharacterSet(charactersIn: "\r\n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let single = parts.joined(separator: " ")
        return single.count > maxTermLength ? String(single.prefix(maxTermLength)) : single
    }

    // ---------------- import / export ----------------

    private static let separators = ["=>", "->", "→", "⇄", "↔", "="]

    /// Reads pasted or imported lines: cells copied from Excel (tab-separated), CSV rows, or text such as
    /// "power flow = 潮流" and "power flow → 潮流". Lines without a separator are skipped.
    public static func parse(_ text: String) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        // "\r\n" is a single Character in Swift, so split on every kind of line break explicitly.
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty, let pair = splitLine(line) else { continue }
            if entries.isEmpty && headerRows.contains((pair.source + "|" + pair.target).lowercased()) {
                continue
            }
            entries.append(GlossaryEntry(source: pair.source, target: pair.target))
        }
        return entries
    }

    static func splitLine(_ line: String) -> (source: String, target: String)? {
        var parts: [String]
        if line.contains("\t") {
            parts = line.components(separatedBy: "\t")
        } else if let separator = findSeparator(line) {
            parts = [String(line[..<separator.range.lowerBound]), String(line[separator.range.upperBound...])]
        } else if line.contains(",") {
            parts = parseCsvLine(line)
        } else {
            return nil
        }
        let source = unquote(parts[0])
        let target = parts.count > 1 ? unquote(parts[1]) : ""
        return source.isEmpty || target.isEmpty ? nil : (source, target)
    }

    private static func findSeparator(_ line: String) -> (range: Range<String.Index>, length: Int)? {
        var best: (range: Range<String.Index>, length: Int)?
        for separator in separators { // longest first, so "=>" wins over "=" at the same spot
            if let range = line.range(of: separator), range.lowerBound > line.startIndex,
               best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, separator.count)
            }
        }
        return best
    }

    static func parseCsvLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(line)
        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            if quoted {
                if c != "\"" {
                    field.append(c)
                } else if i + 1 < iterator.count && iterator[i + 1] == "\"" {
                    field.append("\"")
                    i += 1
                } else {
                    quoted = false
                }
            } else if c == "\"" && field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                quoted = true
            } else if c == "," {
                fields.append(field)
                field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        fields.append(field)
        iterator.removeAll()
        return fields
    }

    private static func unquote(_ cell: String) -> String {
        var text = cell.trimmingCharacters(in: .whitespaces)
        if text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"").trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// CSV that Excel opens correctly (UTF-8 with a byte order mark when written with `writeCsv`).
    public static func toCsv(_ entries: [GlossaryEntry]) -> String {
        entries.map { quoteCsv($0.source) + "," + quoteCsv($0.target) + "\r\n" }.joined()
    }

    public static func writeCsv(to url: URL, entries: [GlossaryEntry]) throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(toCsv(entries).utf8))
        try data.write(to: url, options: [.atomic])
    }

    /// Reads a UTF-8/UTF-16 file, or one saved in GB 18030 (what Excel's plain "CSV" uses on Chinese Windows).
    public static func readFile(_ url: URL) throws -> [GlossaryEntry] {
        let data = try Data(contentsOf: url)
        var text: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            text = String(data: data, encoding: .utf8)
            if text == nil {
                let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
                text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return parse(text ?? "")
    }

    private static func quoteCsv(_ field: String) -> String {
        field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : field
    }

    private func save() -> Bool {
        do {
            try AppPaths.writeAtomically(try AppPaths.makeEncoder().encode(entries), to: path)
            return true
        } catch {
            Log.error("保存术语表失败", error)
            return false
        }
    }
}
