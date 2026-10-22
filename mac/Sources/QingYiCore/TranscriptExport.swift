import Foundation

public enum TranscriptFormat: String, CaseIterable {
    case text = "txt"
    case srt
}

public enum TranscriptContent: CaseIterable {
    case original
    case translation
    case bilingual
}

/// Writes the final lines of a live transcript as plain text or SRT subtitles.
public enum TranscriptExport {
    /// A subtitle stays on screen at least this long, unless the next one starts earlier.
    public static let minCueSeconds = 0.8

    public static func build(_ lines: [TranscriptLine], format: TranscriptFormat, content: TranscriptContent) -> String {
        let cues = lines.filter(\.isFinal)
            .map { (start: $0.start, end: $0.end, text: pick($0, content)) }
            .filter { !$0.text.isEmpty }
        var output = ""
        for (index, cue) in cues.enumerated() {
            if format == .srt {
                var end = max(cue.end, cue.start + minCueSeconds)
                if index + 1 < cues.count && end > cues[index + 1].start {
                    end = max(cue.start + 0.1, cues[index + 1].start)
                }
                output += "\(index + 1)\n\(formatSrtTime(cue.start)) --> \(formatSrtTime(end))\n\(cue.text)\n\n"
            } else {
                output += "[\(formatClock(cue.start))] \(cue.text.replacingOccurrences(of: "\n", with: "\n    "))\n"
                if content == .bilingual {
                    output += "\n"
                }
            }
        }
        return output
    }

    /// "00:01:02,345", the SRT time format.
    public static func formatSrtTime(_ seconds: Double) -> String {
        let ms = Int64((max(0, seconds) * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// "01:02", or "1:01:02" past an hour.
    public static func formatClock(_ seconds: Double) -> String {
        let total = Int64(max(0, seconds))
        return total >= 3600
            ? String(format: "%lld:%02lld:%02lld", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02lld:%02lld", total / 60, total % 60)
    }

    private static func pick(_ line: TranscriptLine, _ content: TranscriptContent) -> String {
        let original = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = line.translationIsDraft ? "" : line.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        switch content {
        case .original: return original
        case .translation: return translation
        case .bilingual: return translation.isEmpty ? original : original + "\n" + translation
        }
    }
}
