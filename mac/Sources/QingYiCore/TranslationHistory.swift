import Combine
import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var time: Date
    public var sourceText: String
    public var translatedText: String

    /// Language code of the source (chosen or detected); nil when unknown.
    public var sourceLanguage: String?

    public var targetLanguage: String

    /// Provider and model that produced the translation, e.g. "DeepSeek · deepseek-flash".
    public var engine: String

    public init(time: Date, sourceText: String, translatedText: String, sourceLanguage: String?, targetLanguage: String, engine: String) {
        self.time = time
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engine = engine
    }

    // Same keys as the Windows version, so a copied history.json loads as is.
    enum CodingKeys: String, CodingKey {
        case time = "Time"
        case sourceText = "SourceText"
        case translatedText = "TranslatedText"
        case sourceLanguage = "SourceLanguage"
        case targetLanguage = "TargetLanguage"
        case engine = "Engine"
    }

    public var id: String { "\(time.timeIntervalSinceReferenceDate)|\(sourceText.hashValue)|\(targetLanguage)" }

    public var languagePairText: String {
        let from = Languages.find(sourceLanguage)?.localName ?? L("自动检测", "Auto-detected")
        let to = Languages.find(targetLanguage)?.localName ?? targetLanguage
        return "\(from) → \(to)"
    }

    public var timeText: String {
        let calendar = Calendar.current
        let clock = HistoryEntry.format(time, "HH:mm")
        if calendar.isDateInToday(time) {
            return L("今天 \(clock)", "Today \(clock)")
        }
        if calendar.isDateInYesterday(time) {
            return L("昨天 \(clock)", "Yesterday \(clock)")
        }
        if calendar.component(.year, from: time) == calendar.component(.year, from: Date()) {
            return L(HistoryEntry.format(time, "M月d日 HH:mm"), HistoryEntry.format(time, "MMM d, HH:mm"))
        }
        return L(HistoryEntry.format(time, "yyyy年M月d日"), HistoryEntry.format(time, "MMM d, yyyy"))
    }

    public var sourcePreview: String { HistoryEntry.preview(sourceText) }

    public var translationPreview: String { HistoryEntry.preview(translatedText) }

    private static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// The most recent translations, newest first, saved to history.json in the data folder.
public final class TranslationHistory: ObservableObject {
    public static let capacity = 100
    private static let maxStoredChars = 50_000
    private static let editSessionWindow: TimeInterval = 3 * 60

    private let path: URL

    @Published public private(set) var entries: [HistoryEntry]

    private init(path: URL, entries: [HistoryEntry]) {
        self.path = path
        self.entries = Array(entries.prefix(TranslationHistory.capacity))
    }

    public static func load() -> TranslationHistory {
        let path = AppPaths.dataDirectory.appendingPathComponent("history.json")
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                return TranslationHistory(path: path, entries: try AppPaths.makeDecoder().decode([HistoryEntry].self, from: Data(contentsOf: path)))
            } catch {
                Log.error("读取翻译历史失败", error)
            }
        }
        return TranslationHistory(path: path, entries: [])
    }

    public func record(_ entry: HistoryEntry) {
        if entry.sourceText.count > TranslationHistory.maxStoredChars || entry.translatedText.count > TranslationHistory.maxStoredChars {
            return
        }

        // Replace instead of adding when the same text was translated again, or when this is the next
        // step of the text being typed or edited (each pause while typing produces a translation).
        var replaced = entries.firstIndex { $0.sourceText == entry.sourceText && $0.targetLanguage == entry.targetLanguage }
        if replaced == nil, let latest = entries.first,
           entry.time.timeIntervalSince(latest.time) < TranslationHistory.editSessionWindow,
           TranslationHistory.isSameEditSession(latest.sourceText, entry.sourceText) {
            replaced = 0
        }
        if let index = replaced {
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        while entries.count > TranslationHistory.capacity {
            entries.removeLast()
        }
        save()
    }

    public func remove(_ entry: HistoryEntry) {
        if let index = entries.firstIndex(of: entry) {
            entries.remove(at: index)
            save()
        }
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    /// True when `b` looks like an edit of `a` (text appended, deleted or changed in place).
    static func isSameEditSession(_ a: String, _ b: String) -> Bool {
        let a = Array(a.trimmingCharacters(in: .whitespacesAndNewlines))
        let b = Array(b.trimmingCharacters(in: .whitespacesAndNewlines))
        let shorter = min(a.count, b.count)
        if shorter == 0 {
            return false
        }
        var prefix = 0
        while prefix < shorter && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return Double(prefix + suffix) >= Double(shorter) * 0.6
    }

    private func save() {
        do {
            try AppPaths.writeAtomically(try AppPaths.makeEncoder().encode(entries), to: path)
        } catch {
            Log.error("保存翻译历史失败", error)
        }
    }
}
