import Foundation

public enum SegmentRole {
    case body
    case title
    case heading
    case other
}

/// One paragraph, table cell, slide text or subtitle of a document, as sent for translation.
public final class DocumentSegment {
    public let id: Int
    public let text: TaggedText
    public let role: SegmentRole

    /// Part of a reference list; skipped unless the user wants references translated.
    public var isReference = false

    public init(id: Int, text: TaggedText, role: SegmentRole = .body) {
        self.id = id
        self.text = text
        self.role = role
    }

    public var plainText: String { TaggedText.stripTags(text.text) }
}

public struct DocumentSaveOptions {
    public var target: Language
    public var bilingualURL: URL?

    public init(target: Language, bilingualURL: URL? = nil) {
        self.target = target
        self.bilingualURL = bilingualURL
    }
}

/// Couldn't open, read or save a document; the message is shown to the user as is.
public struct DocumentError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A document opened for translation: its segments, and how to write the translated copy.
open class TranslatableDocument {
    public let sourceURL: URL
    public private(set) var segments: [DocumentSegment] = []

    /// Things the user should know, e.g. pages that are scanned images and stay untranslated.
    public var warnings: [String] = []

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    /// Extra rule for the model about this kind of document, e.g. that subtitles run across cues.
    open var promptHint: String? { nil }

    /// True for PDF, which can also be written as alternating original and translated pages.
    open var supportsBilingual: Bool { false }

    /// Writes the translated copy. `translations` maps segment ids to translated tagged text;
    /// segments without a translation keep their original text.
    open func save(to url: URL, translations: [Int: String], options: DocumentSaveOptions) throws {
        fatalError("Subclasses write their own format")
    }

    @discardableResult
    public func addSegment(_ pieces: [InlinePiece], role: SegmentRole = .body) -> DocumentSegment {
        let segment = DocumentSegment(id: segments.count, text: TaggedText.build(pieces), role: role)
        segments.append(segment)
        return segment
    }

    @discardableResult
    public func addSegment(_ text: String, role: SegmentRole = .body) -> DocumentSegment {
        addSegment([.of(text, 0)], role: role)
    }

    /// True when the text has something to translate: at least two letters, or one CJK character.
    public static func hasWords(_ text: String) -> Bool {
        var letters = 0
        for scalar in text.unicodeScalars where isLetter(scalar) {
            letters += 1
            if letters >= 2 || scalar.value >= 0x2E80 {
                return true
            }
        }
        return false
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Writes through a temporary file next to the target, so a failure never leaves a half-written document.
    static func writeAtomically(to url: URL, _ write: (URL) throws -> Void) throws {
        let temp = url.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: temp)
        do {
            try write(temp)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

public enum ReferenceSection {
    private static let headings: Set<String> = [
        "references", "reference", "bibliography", "works cited", "literature cited", "literature", "references and notes",
        "参考文献", "参考资料", "引用文献", "參考文獻", "literaturverzeichnis", "références", "bibliographie", "referencias",
    ]

    /// "References", "7. References", "VII. REFERENCES", "参考文献"…
    public static func isHeading(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == ":" || last == "：" {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return false }
        // Drop numbering such as "7.", "VII.", "A." in front.
        if let space = trimmed.firstIndex(of: " ") {
            let number = trimmed[..<space]
            let digits = number.filter { $0 != "." }
            if number.count <= 5, !digits.isEmpty, digits.allSatisfy({ $0.isNumber || "IVXLivxl".contains($0) }) {
                trimmed = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return headings.contains(trimmed.lowercased())
    }
}

/// Where the translated copy goes: next to the original, never over it.
public enum OutputPaths {
    /// "paper.pdf" → "paper.zh-Hans.pdf"; "paper.zh-Hans (2).pdf" if that exists already.
    public static func url(for source: URL, target: Language, variant: String? = nil) -> URL {
        let directory = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let stem = variant.map { "\(name).\(target.code).\($0)" } ?? "\(name).\(target.code)"
        func make(_ base: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        }
        var url = make(stem)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || url.standardizedFileURL == source.standardizedFileURL {
            url = make("\(stem) (\(n))")
            n += 1
        }
        return url
    }
}
