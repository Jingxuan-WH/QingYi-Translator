import Foundation

/// One paragraph (or block of paragraphs) of source text together with its translation.
public struct TranslationTurn: Equatable {
    public let source: String
    public let translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

/// What still needs translating after reusing the unchanged leading paragraphs of the previous translation.
public final class IncrementalPlan {
    private static let maxContextTurns = 3
    private static let maxContextChars = 4000

    /// Leading paragraphs whose translation is kept as is.
    public let reused: [TranslationTurn]

    /// The kept translation, ending with the separator that precedes the remainder.
    public let reusedTranslation: String

    /// The text that still has to be sent to the model.
    public let remainder: String

    public init(reused: [TranslationTurn], reusedTranslation: String, remainder: String) {
        self.reused = reused
        self.reusedTranslation = reusedTranslation
        self.remainder = remainder
    }

    public static func full(_ text: String) -> IncrementalPlan { IncrementalPlan(reused: [], reusedTranslation: "", remainder: text) }

    public var isFull: Bool { reused.isEmpty }

    public var nothingNew: Bool { !isFull && remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The last few reused paragraphs, sent along so the model keeps terminology consistent.
    public var context: [TranslationTurn] {
        var turns: [TranslationTurn] = []
        var chars = 0
        var i = reused.count - 1
        while i >= 0 && turns.count < IncrementalPlan.maxContextTurns {
            chars += reused[i].source.count
            if !turns.isEmpty && chars > IncrementalPlan.maxContextChars {
                break
            }
            turns.insert(reused[i], at: 0)
            i -= 1
        }
        return turns
    }
}

/// Remembers the paragraphs of the last translation so that appending text (or editing a later paragraph)
/// only sends the changed tail to the model, with the preceding paragraphs as context.
public final class IncrementalCache {
    private static let blankLine = try! NSRegularExpression(pattern: #"\r?\n[ \t]*\r?\n\s*"#)

    private var segments: [TranslationTurn] = []
    private var contextKey: String?

    public init() {}

    public func clear() {
        segments.removeAll()
        contextKey = nil
    }

    /// - Parameter contextKey: Languages, provider, model and instructions; any change forces a full translation.
    public func plan(contextKey: String, text: String) -> IncrementalPlan {
        if contextKey != self.contextKey || segments.isEmpty {
            return .full(text)
        }

        var reused: [TranslationTurn] = []
        var translation = ""
        var position = text.startIndex
        for segment in segments {
            guard text[position...].hasPrefix(segment.source),
                  let end = text.index(position, offsetBy: segment.source.count, limitedBy: text.endIndex) else { break }
            var next = end
            while next < text.endIndex && text[next].isWhitespace {
                next = text.index(after: next)
            }
            let atEnd = next == text.endIndex
            let newlines = text[end..<next].filter { $0 == "\n" || $0 == "\r\n" }.count

            // Only reuse a paragraph that is finished: text continuing on the same line, or a single
            // line break after an unfinished sentence (a soft wrap, as in text copied from a PDF),
            // means the paragraph is still being written.
            if !atEnd && (newlines == 0 || (newlines == 1 && !IncrementalCache.endsSentence(segment.source))) {
                break
            }

            reused.append(segment)
            translation += segment.translation + (newlines >= 2 ? "\n\n" : newlines == 1 ? "\n" : "")
            position = next
            if atEnd {
                break
            }
        }

        return reused.isEmpty
            ? .full(text)
            : IncrementalPlan(reused: reused, reusedTranslation: translation, remainder: String(text[position...]))
    }

    /// Records a finished translation of `plan`'s remainder (or of the whole text for a full plan).
    public func commit(contextKey: String, plan: IncrementalPlan, remainderTranslation: String) {
        var result = plan.reused
        if !plan.remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(contentsOf: IncrementalCache.split(source: plan.remainder, translation: remainderTranslation))
        }
        segments = result
        self.contextKey = contextKey
    }

    /// Splits a translated block into paragraph pairs when source and translation have the same number of
    /// paragraphs, so a later edit can reuse more of it; otherwise keeps it as one block.
    static func split(source: String, translation: String) -> [TranslationTurn] {
        let source = trimEnd(source)
        let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceParts = splitParagraphs(source)
        let translatedParts = splitParagraphs(translation)
        if sourceParts.count > 1 && sourceParts.count == translatedParts.count {
            return zip(sourceParts, translatedParts).map {
                TranslationTurn(source: trimEnd($0), translation: $1.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return [TranslationTurn(source: source, translation: translation)]
    }

    static func splitParagraphs(_ text: String) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var start = 0
        for match in blankLine.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: start))
        return parts
    }

    static func endsSentence(_ text: String) -> Bool {
        var span = Substring(trimEnd(text))
        while let last = span.last, "\"'”’)）]】」』》".contains(last) {
            span = span.dropLast()
        }
        guard let last = span.last else { return false }
        return ".!?。！？…:;：；".contains(last)
    }

    private static func trimEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
}
