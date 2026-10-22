import Combine
import Foundation

/// One utterance of a live transcript with its translation.
public struct TranscriptLine: Identifiable, Equatable {
    public let session: Int
    public let utterance: Int
    /// Seconds from the start of the transcript.
    public var start: Double
    public var end: Double
    /// Recognized text; while `isFinal` is false it may still change.
    public var text = ""
    public var isFinal = false
    /// Language code of the recognizer that produced the text, when known.
    public var language: String?
    public var translation = ""
    /// The translation is of a partial result and will be replaced.
    public var translationIsDraft = false
    public var isTranslating = false

    public init(session: Int, utterance: Int, start: Double) {
        self.session = session
        self.utterance = utterance
        self.start = start
        end = start
    }

    public var id: Int { session << 32 | utterance }

    public var timeText: String { TranscriptExport.formatClock(start) }
}

/// The lines of a live transcript. Recognizers report partial results that are later replaced by a final one;
/// lines are keyed by utterance, so a late partial never overwrites a final result and an utterance that turns
/// out to be empty disappears again. Use from the main thread only.
public final class LiveTranscript: ObservableObject {
    @Published public private(set) var lines: [TranscriptLine] = []

    private var session = 0
    private var offset = 0.0

    public init() {}

    public var finalLines: [TranscriptLine] { lines.filter(\.isFinal) }

    /// Call before feeding a new recognition session, whose utterance numbers and times start again from zero;
    /// its lines continue after the existing ones.
    public func beginSession() {
        session += 1
        offset = lines.isEmpty ? 0 : (lines.map { max($0.end, $0.start) }.max()! + 1).rounded(.up)
    }

    /// - Parameter start: Seconds from the start of the current session.
    @discardableResult
    public func updatePartial(_ utterance: Int, text: String, start: Double) -> TranscriptLine? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = indexOf(utterance)
        if index == nil {
            if text.isEmpty {
                return nil
            }
            index = insert(utterance, start: start)
        } else if lines[index!].isFinal {
            return nil // a late partial result; the final one wins
        }
        lines[index!].text = text
        return lines[index!]
    }

    /// Records the final text; returns nil (and removes the partial line) when nothing was recognized.
    @discardableResult
    public func finalize(_ utterance: Int, text: String, start: Double, end: Double, language: String? = nil) -> TranscriptLine? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = indexOf(utterance)
        if text.isEmpty {
            if let existing, !lines[existing].isFinal {
                lines.remove(at: existing)
            }
            return nil
        }
        let index = existing ?? insert(utterance, start: start)
        var line = lines[index]
        line.start = start + offset
        line.end = max(end, start) + offset
        line.text = text
        line.language = language
        line.isFinal = true
        lines[index] = line
        return line
    }

    public func discard(_ utterance: Int) {
        if let index = indexOf(utterance), !lines[index].isFinal {
            lines.remove(at: index)
        }
    }

    public func line(_ utterance: Int) -> TranscriptLine? { indexOf(utterance).map { lines[$0] } }

    public func line(id: Int) -> TranscriptLine? { lines.last { $0.id == id } }

    /// Sets the translation shown under a line (streamed pieces arrive one by one).
    public func setTranslation(id: Int, _ translation: String, draft: Bool, translating: Bool) {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
        var line = lines[index]
        line.translation = translation
        line.translationIsDraft = draft
        line.isTranslating = translating
        if line != lines[index] {
            lines[index] = line
        }
    }

    public func clear() {
        lines.removeAll()
        offset = 0
    }

    private func indexOf(_ utterance: Int) -> Int? {
        for index in lines.indices.reversed() {
            let line = lines[index]
            if line.session == session && line.utterance == utterance {
                return index
            }
            if line.session < session {
                break
            }
        }
        return nil
    }

    // Lines stay in utterance order even if a recognizer reports out of order.
    private func insert(_ utterance: Int, start: Double) -> Int {
        var index = lines.count
        while index > 0 && lines[index - 1].session == session && lines[index - 1].utterance > utterance {
            index -= 1
        }
        lines.insert(TranscriptLine(session: session, utterance: utterance, start: start + offset), at: index)
        return index
    }
}

/// The sentences translated just before, sent along with each new one so the translation stays coherent.
public final class LiveTranslationContext {
    public static let maxTurns = 3
    public static let maxChars = 1500

    /// Appended to the user's own extra instructions for live translation.
    public static let instructions =
        "The text comes from live speech recognition: it may contain recognition errors, filler words or missing punctuation. " +
        "Translate what the speaker means, naturally and concisely."

    private var stored: [TranslationTurn] = []

    public init() {}

    public func add(source: String, translation: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.isEmpty else { return }
        stored.append(TranslationTurn(source: source, translation: translation))
        if stored.count > LiveTranslationContext.maxTurns {
            stored.removeFirst(stored.count - LiveTranslationContext.maxTurns)
        }
    }

    /// The most recent turns, oldest first, within `maxChars` (at least one).
    public var turns: [TranslationTurn] {
        var result: [TranslationTurn] = []
        var chars = 0
        for turn in stored.reversed() {
            chars += turn.source.count + turn.translation.count
            if !result.isEmpty && chars > LiveTranslationContext.maxChars {
                break
            }
            result.insert(turn, at: 0)
        }
        return result
    }

    public func clear() { stored.removeAll() }

    public static func buildInstructions(_ user: String) -> String {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? instructions : trimmed + "\n" + instructions
    }

    /// Like the main window: speech already in the chosen target language goes to the fallback (Chinese → English,
    /// anything else → Chinese). With automatic detection the model is left to identify the source itself.
    public static func resolveLanguages(_ text: String, source: Language?, preferredTarget: Language) -> (promptSource: Language?, target: Language) {
        let spoken = source ?? LanguageDetector.detect(text)
        let target = spoken.map { $0.isSameLanguage(as: preferredTarget) } == true ? Languages.fallback(for: preferredTarget) : preferredTarget
        return (source, target)
    }
}

/// The result one recognizer produced for an utterance.
public struct RecognitionCandidate: Equatable {
    public let language: Language
    public let text: String
    /// 0–1, or nil when the recognizer doesn't report it.
    public let confidence: Double?

    public init(language: Language, text: String, confidence: Double?) {
        self.language = language
        self.text = text
        self.confidence = confidence
    }
}

/// Speech recognition on the Mac needs a language up front. For "detect automatically" a Chinese and an English
/// recognizer both listen, and for each utterance this picks the more plausible result.
public enum LanguageArbiter {
    /// The recognizers that listen when the source language is detected automatically.
    public static let autoLanguages = [Languages.simplifiedChinese, Languages.english]

    public static func pick(_ candidates: [RecognitionCandidate], previous: Language?) -> RecognitionCandidate? {
        let usable = candidates.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard usable.count > 1 else { return usable.first }
        return usable.max { score($0, previous: previous, among: usable) < score($1, previous: previous, among: usable) }
    }

    static func score(_ candidate: RecognitionCandidate, previous: Language?, among all: [RecognitionCandidate]) -> Double {
        let han = hanShare(candidate.text)
        // Without confidences, judge by what the Chinese recognizer wrote: mostly Chinese characters mean Chinese speech.
        let chineseShare = all.first { $0.language.isChinese }.map { hanShare($0.text) } ?? han
        var score = candidate.confidence ?? (candidate.language.isChinese ? chineseShare : 1 - chineseShare)
        // The Chinese recognizer writes English speech in Latin letters; then the English recognizer did better.
        if candidate.language.isChinese && han < 0.2 && all.contains(where: { !$0.language.isChinese }) {
            score -= 0.3
        }
        if let previous, candidate.language.isSameLanguage(as: previous) {
            score += 0.05 // don't flip-flop on a close call
        }
        return score
    }

    /// Share of CJK characters among the letters of the text.
    static func hanShare(_ text: String) -> Double {
        var han = 0
        var letters = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                han += 1
            }
        }
        return letters == 0 ? 0 : Double(han) / Double(letters)
    }
}

public enum SpeechLocales {
    /// The regional variant the system speech recognizers expect for each language.
    public static func identifier(for language: Language) -> String {
        switch language.code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "pt": return "pt-BR"
        case "it": return "it-IT"
        case "ru": return "ru-RU"
        case "ar": return "ar-SA"
        case "vi": return "vi-VN"
        case "th": return "th-TH"
        case "id": return "id-ID"
        case "tr": return "tr-TR"
        case "nl": return "nl-NL"
        case "pl": return "pl-PL"
        case "hi": return "hi-IN"
        default: return language.code
        }
    }

    /// Recognizers to run for a source-language setting ("auto" listens for Chinese and English).
    public static func languages(for setting: String) -> [Language] {
        if let language = Languages.find(setting) {
            return [language]
        }
        return LanguageArbiter.autoLanguages
    }
}
