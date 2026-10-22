import Foundation

/// Settings of live transcription, stored in settings.json under "live".
public struct LiveSettings: Codable, Equatable {
    public static let sourceMicrophone = "microphone"
    public static let sourceSystem = "system"
    public static let sourceBoth = "both"
    public static let minCaptionFontSize = 12.0
    public static let maxCaptionFontSize = 48.0

    /// "microphone", "system" (what the Mac is playing) or "both".
    public var audioSource = LiveSettings.sourceMicrophone

    /// Core Audio UID of the microphone; nil follows the system default.
    public var microphoneId: String?

    /// "auto" (Chinese or English) or a language code.
    public var sourceLanguage = Languages.autoCode

    public var targetLanguage = Languages.simplifiedChinese.code

    /// Also translate the still-changing partial text (costs more requests).
    public var translatePartials = false

    public var showCaptions = false
    public var captionFontSize = 20.0
    public var captionFrame: WindowFrame?
    public var windowFrame: WindowFrame?

    public var hotkeyEnabled = false
    public var hotkey = "Control+Option+L"

    public init() {}

    public mutating func normalize() {
        if audioSource != LiveSettings.sourceSystem && audioSource != LiveSettings.sourceBoth {
            audioSource = LiveSettings.sourceMicrophone
        }
        if sourceLanguage != Languages.autoCode && Languages.find(sourceLanguage) == nil {
            sourceLanguage = Languages.autoCode
        }
        if Languages.find(targetLanguage) == nil {
            targetLanguage = Languages.simplifiedChinese.code
        }
        captionFontSize = captionFontSize.isFinite
            ? min(max(captionFontSize, LiveSettings.minCaptionFontSize), LiveSettings.maxCaptionFontSize) : 20
    }

    // Every field optional in the file, so older and newer files keep loading.
    private enum CodingKeys: String, CodingKey {
        case audioSource, microphoneId, sourceLanguage, targetLanguage, translatePartials
        case showCaptions, captionFontSize, captionFrame, windowFrame, hotkeyEnabled, hotkey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback }
        audioSource = read(.audioSource, audioSource)
        microphoneId = try? c.decodeIfPresent(String.self, forKey: .microphoneId)
        sourceLanguage = read(.sourceLanguage, sourceLanguage)
        targetLanguage = read(.targetLanguage, targetLanguage)
        translatePartials = read(.translatePartials, translatePartials)
        showCaptions = read(.showCaptions, showCaptions)
        captionFontSize = read(.captionFontSize, captionFontSize)
        captionFrame = try? c.decodeIfPresent(WindowFrame.self, forKey: .captionFrame)
        windowFrame = try? c.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
        hotkeyEnabled = read(.hotkeyEnabled, hotkeyEnabled)
        hotkey = read(.hotkey, hotkey)
    }
}
