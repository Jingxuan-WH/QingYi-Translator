import Foundation

/// Tidies recognized text (the counterpart of Core/SpeechText.cs).
public enum SpeechText {
    private static let fullWidth: [Character: Character] = [",": "，", "?": "？", "!": "！", ":": "：", ";": "；"]

    /// Recognizers sometimes write ASCII commas and question marks in Chinese; Chinese text uses the full-width forms
    /// (and no spaces around them). Marks between Latin letters or digits, as in "3,000", "10:30" or "Hello, world", stay.
    public static func useChinesePunctuation(_ text: String) -> String {
        guard text.contains(where: { fullWidth[$0] != nil }) else { return text }
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let mark = fullWidth[character],
               !(isLatin(neighbor(characters, index, -1)) && isLatin(neighbor(characters, index, 1))) {
                while result.last == " " {
                    result.removeLast()
                }
                result.append(mark)
                while index + 1 < characters.count && characters[index + 1] == " " {
                    index += 1
                }
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    // The nearest character that isn't a space.
    private static func neighbor(_ characters: [Character], _ index: Int, _ step: Int) -> Character? {
        var at = index + step
        while at >= 0 && at < characters.count {
            if characters[at] != " " {
                return characters[at]
            }
            at += step
        }
        return nil
    }

    private static func isLatin(_ character: Character?) -> Bool {
        guard let character, character.isASCII else { return false }
        return character.isLetter || character.isNumber || "/.%-_@".contains(character)
    }
}

/// Notices a microphone that has delivered nothing but silence since listening started: muted, an input volume of
/// zero, or a permission that no longer applies after an update (macOS then hands the app silence). A real microphone
/// always picks up some noise, so once anything was heard it stays quiet for the session. Not thread-safe.
public final class SilenceWatch {
    /// Meter levels (0–1, as shown in the window) at or below this are digital silence.
    public static let threshold: Float = 0.0004

    private let seconds: Double
    private var since: Double?
    private var heard = false
    private var reported = false

    public init(seconds: Double = 8) {
        self.seconds = seconds
    }

    /// True once, when the level has stayed at or below `threshold` for the whole time.
    public func update(level: Float, now: Double) -> Bool {
        if heard || reported {
            return false
        }
        if level > SilenceWatch.threshold {
            heard = true
            return false
        }
        let start = since ?? now
        since = start
        guard now - start >= seconds else { return false }
        reported = true
        return true
    }

    /// Starts over, e.g. when the devices are opened again.
    public func reset() {
        since = nil
        heard = false
        reported = false
    }
}
