import Foundation

public enum AppPaths {
    /// True when TRANSLATOR_DATA_DIR points somewhere else, e.g. for a test copy running next to the real one.
    public static let usesCustomDataDirectory: Bool = {
        guard let custom = ProcessInfo.processInfo.environment["TRANSLATOR_DATA_DIR"] else { return false }
        return !custom.isEmpty
    }()

    /// ~/Library/Application Support/QingYiTranslator, or TRANSLATOR_DATA_DIR when set (used for testing).
    public static let dataDirectory: URL = {
        if let custom = ProcessInfo.processInfo.environment["TRANSLATOR_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("QingYiTranslator", isDirectory: true)
    }()

    static var settingsFile: URL { dataDirectory.appendingPathComponent("settings.json") }

    /// Writes `data` to `url` through a temporary file, so a crash never leaves a half-written file behind.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(JSONDates.format(date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = JSONDates.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(text)")
            }
            return date
        }
        return decoder
    }
}

/// ISO-8601 dates; also reads the local-time format the Windows version writes ("2026-09-24T10:12:13.1234567").
enum JSONDates {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let local: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func format(_ date: Date) -> String { withFraction.string(from: date) }

    static func parse(_ text: String) -> Date? {
        if let date = withFraction.date(from: text) ?? plain.date(from: text) {
            return date
        }
        // Local time without a zone, optionally with a fraction of any length.
        let trimmed = text.split(separator: ".", maxSplits: 1).first.map(String.init) ?? text
        return local.date(from: trimmed)
    }
}

/// What the user configured for one provider. Request details (temperature, thinking switches) come from its preset.
/// The API key lives in the Keychain, see `AppSettings.apiKey(for:)`.
public struct ProviderConfig: Codable, Equatable {
    public var baseUrl: String = ""
    public var model: String = ""

    public init(baseUrl: String = "", model: String = "") {
        self.baseUrl = baseUrl
        self.model = model
    }

    public static func fromPreset(_ preset: ProviderPreset) -> ProviderConfig {
        ProviderConfig(baseUrl: preset.baseUrl, model: preset.defaultModel)
    }
}

public struct WindowFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public final class AppSettings: Codable {
    public static let themeSystem = "system"
    public static let themeLight = "light"
    public static let themeDark = "dark"
    public static let defaultHotkey = "Option+Q"

    public var activeProvider = ProviderCatalog.deepSeekId
    public var providerConfigs: [String: ProviderConfig] = [:]
    public var extraInstructions = ""

    /// "auto" or a language code.
    public var sourceLanguage = Languages.autoCode

    /// The language the user wants translations in; text already in it goes to `Languages.fallback(for:)`.
    public var targetLanguage = Languages.simplifiedChinese.code

    public var incrementalTranslation = true
    public var saveHistory = true
    public var glossaryEnabled = true

    /// Interface language: "system", "zh" or "en".
    public var uiLanguage = Loc.systemCode

    /// "system", "light" or "dark".
    public var theme = AppSettings.themeSystem

    public var doubleCopyEnabled = true
    public var hotkeyEnabled = true
    public var hotkey = AppSettings.defaultHotkey

    public var autoTranslate = true
    public var restoreClipboard = true
    public var closeToMenuBar = true
    public var launchAtLogin = false
    public var topmost = false
    public var menuBarTipShown = false
    public var accessibilityHintShown = false
    public var mainWindowFrame: WindowFrame?

    public var autoCheckUpdates = true
    public var lastUpdateCheck: Date?

    /// Tag of a release the user chose to skip; it is no longer announced.
    public var skippedUpdateVersion: String?

    /// Tag of the last release announced with a notification, so each one is announced only once.
    public var notifiedUpdateVersion: String?

    /// API keys the Keychain refused to store (it can be locked or damaged). The settings file is readable by this user only.
    public var fallbackApiKeys: [String: String] = [:]

    public init() {}

    public var activePreset: ProviderPreset { ProviderCatalog.get(activeProvider) }

    public var active: ProviderConfig { provider(activeProvider) }

    public func provider(_ id: String) -> ProviderConfig {
        if let config = providerConfigs[id] {
            return config
        }
        let config = ProviderConfig.fromPreset(ProviderCatalog.get(id))
        providerConfigs[id] = config
        return config
    }

    // ---------------- API keys ----------------

    private static var keyCache: [String: String] = [:]
    private static let keyLock = NSLock()

    /// The provider's API key from the Keychain (or the fallback store), "" when none is saved.
    public func apiKey(for provider: String) -> String {
        AppSettings.keyLock.lock()
        defer { AppSettings.keyLock.unlock() }
        if let cached = AppSettings.keyCache[provider] {
            return cached
        }
        var key = ""
        do {
            key = try Keychain.read(account: provider) ?? ""
        } catch {
            Log.error("读取钥匙串中的 API Key 失败（\(provider)）", error)
        }
        if key.isEmpty, let fallback = fallbackApiKeys[provider] {
            key = fallback
        }
        AppSettings.keyCache[provider] = key
        return key
    }

    /// Stores the key in the Keychain; if that fails it is kept in the settings file instead. Call `save()` afterwards.
    public func setApiKey(_ key: String, for provider: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.keyLock.lock()
        defer { AppSettings.keyLock.unlock() }
        AppSettings.keyCache[provider] = trimmed
        do {
            if trimmed.isEmpty {
                try Keychain.delete(account: provider)
            } else {
                try Keychain.write(trimmed, account: provider)
            }
            fallbackApiKeys.removeValue(forKey: provider)
        } catch {
            Log.error("无法把 API Key 保存到钥匙串，改为保存在设置文件中（\(provider)）", error)
            if trimmed.isEmpty {
                fallbackApiKeys.removeValue(forKey: provider)
            } else {
                fallbackApiKeys[provider] = trimmed
            }
        }
    }

    // ---------------- persistence ----------------

    public static func load() -> AppSettings {
        let url = AppPaths.settingsFile
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let settings = try AppPaths.makeDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
                settings.normalize()
                return settings
            } catch {
                Log.error("读取设置失败，将使用默认设置", error)
            }
        }
        let settings = AppSettings()
        settings.normalize()
        return settings
    }

    @discardableResult
    public func save() -> Bool {
        do {
            try AppPaths.writeAtomically(try AppPaths.makeEncoder().encode(self), to: AppPaths.settingsFile)
            return true
        } catch {
            Log.error("保存设置失败", error)
            return false
        }
    }

    private func normalize() {
        if !ProviderCatalog.all.contains(where: { $0.id == activeProvider }) {
            activeProvider = ProviderCatalog.deepSeekId
        }
        for preset in ProviderCatalog.all {
            _ = provider(preset.id)
        }
        if sourceLanguage != Languages.autoCode && Languages.find(sourceLanguage) == nil {
            sourceLanguage = Languages.autoCode
        }
        if Languages.find(targetLanguage) == nil {
            targetLanguage = Languages.simplifiedChinese.code
        }
        if uiLanguage != Loc.chineseCode && uiLanguage != Loc.englishCode {
            uiLanguage = Loc.systemCode
        }
        if theme != AppSettings.themeLight && theme != AppSettings.themeDark {
            theme = AppSettings.themeSystem
        }
    }

    // ---------------- Codable (every field optional in the file, so old files keep loading) ----------------

    private enum CodingKeys: String, CodingKey {
        case activeProvider, providerConfigs, extraInstructions, sourceLanguage, targetLanguage
        case incrementalTranslation, saveHistory, glossaryEnabled, uiLanguage, theme
        case doubleCopyEnabled, hotkeyEnabled, hotkey, autoTranslate, restoreClipboard, closeToMenuBar
        case launchAtLogin, topmost, menuBarTipShown, accessibilityHintShown, mainWindowFrame
        case autoCheckUpdates, lastUpdateCheck, skippedUpdateVersion, notifiedUpdateVersion, fallbackApiKeys
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil ?? fallback }
        activeProvider = read(.activeProvider, activeProvider)
        providerConfigs = read(.providerConfigs, providerConfigs)
        extraInstructions = read(.extraInstructions, extraInstructions)
        sourceLanguage = read(.sourceLanguage, sourceLanguage)
        targetLanguage = read(.targetLanguage, targetLanguage)
        incrementalTranslation = read(.incrementalTranslation, incrementalTranslation)
        saveHistory = read(.saveHistory, saveHistory)
        glossaryEnabled = read(.glossaryEnabled, glossaryEnabled)
        uiLanguage = read(.uiLanguage, uiLanguage)
        theme = read(.theme, theme)
        doubleCopyEnabled = read(.doubleCopyEnabled, doubleCopyEnabled)
        hotkeyEnabled = read(.hotkeyEnabled, hotkeyEnabled)
        hotkey = read(.hotkey, hotkey)
        autoTranslate = read(.autoTranslate, autoTranslate)
        restoreClipboard = read(.restoreClipboard, restoreClipboard)
        closeToMenuBar = read(.closeToMenuBar, closeToMenuBar)
        launchAtLogin = read(.launchAtLogin, launchAtLogin)
        topmost = read(.topmost, topmost)
        menuBarTipShown = read(.menuBarTipShown, menuBarTipShown)
        accessibilityHintShown = read(.accessibilityHintShown, accessibilityHintShown)
        mainWindowFrame = try? c.decodeIfPresent(WindowFrame.self, forKey: .mainWindowFrame)
        autoCheckUpdates = read(.autoCheckUpdates, autoCheckUpdates)
        lastUpdateCheck = try? c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        skippedUpdateVersion = try? c.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
        notifiedUpdateVersion = try? c.decodeIfPresent(String.self, forKey: .notifiedUpdateVersion)
        fallbackApiKeys = read(.fallbackApiKeys, fallbackApiKeys)
    }
}
