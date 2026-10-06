import Testing
import Foundation
@testable import QingYiCore

struct UpdateAndHotkeyTests {
    @Test func parseRelease() throws {
        let json = """
        {"tag_name":"v9.9.9","html_url":"https://github.com/Jingxuan-WH/QingYi-Translator/releases/tag/v9.9.9","body":"## Notes\\n- a",
         "published_at":"2026-10-01T12:00:00Z","draft":false,"prerelease":false,
         "assets":[{"name":"Translator.exe","browser_download_url":"https://github.com/Jingxuan-WH/QingYi-Translator/releases/download/v9.9.9/Translator.exe","size":1},
                   {"name":"QingYiTranslator-mac.zip","browser_download_url":"https://github.com/Jingxuan-WH/QingYi-Translator/releases/download/v9.9.9/QingYiTranslator-mac.zip","size":12345,"digest":"sha256:abc"}]}
        """
        let release = try #require(try UpdateService.parseRelease(Data(json.utf8)))
        #expect(release.version == SemanticVersion(9, 9, 9))
        #expect(release.size == 12345)
        #expect(release.sha256 == "abc")
        #expect((release.publishedAt) != nil)
        #expect(UpdateService.isNewer(release))

        let untrusted = json.replacingOccurrences(of: "https://github.com/Jingxuan-WH/QingYi-Translator/releases/download/v9.9.9/QingYiTranslator-mac.zip", with: "https://evil.example/x.zip")
        #expect((try UpdateService.parseRelease(Data(untrusted.utf8))) == nil)
        #expect((try UpdateService.parseRelease(Data(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8))) == nil)
    }

    @Test func versions() {
        #expect(SemanticVersion.parse("v0.3.0") == SemanticVersion(0, 3, 0))
        #expect(SemanticVersion.parse("1.2") == SemanticVersion(1, 2, 0))
        #expect(SemanticVersion.parse("2.0.1-beta") == SemanticVersion(2, 0, 1))
        #expect((SemanticVersion.parse("latest")) == nil)
        #expect(SemanticVersion(0, 3, 1) > SemanticVersion(0, 3, 0))
    }

    @Test func hotkeyGestureRoundTrip() throws {
        let gesture = try #require(HotkeyGesture.parse("Option+Q"))
        #expect(gesture.description == "⌥Q")
        #expect(gesture.storageString == "Option+Q")
        #expect(gesture.keyCode == 12)
        #expect(HotkeyGesture.parse("⌃⇧F5")?.storageString == "Control+Shift+F5")
        #expect(HotkeyGesture.parse("cmd+shift+t")?.description == "⇧⌘T")
        #expect((HotkeyGesture.parse("Shift+Q")) == nil) // would steal typing
        #expect((HotkeyGesture.parse("F6")) != nil)
        #expect((HotkeyGesture.parse("Option+Nope")) == nil)
        #expect((HotkeyGesture.parse("")) == nil)
    }

    @Test func historyEditSession() {
        #expect(TranslationHistory.isSameEditSession("Hello world", "Hello world and more"))
        #expect(!(TranslationHistory.isSameEditSession("Hello", "Completely different")))
    }

    @Test func settingsRoundTripAndDefaults() throws {
        let settings = AppSettings()
        settings.hotkey = "Command+Shift+T"
        settings.targetLanguage = "ja"
        let data = try AppPaths.makeEncoder().encode(settings)
        let loaded = try AppPaths.makeDecoder().decode(AppSettings.self, from: data)
        #expect(loaded.hotkey == "Command+Shift+T")
        #expect(loaded.targetLanguage == "ja")
        let partial = try AppPaths.makeDecoder().decode(AppSettings.self, from: Data(#"{"theme":"dark","unknown":1}"#.utf8))
        #expect(partial.theme == "dark")
        #expect(partial.doubleCopyEnabled)
        #expect(partial.hotkey == AppSettings.defaultHotkey)
    }

    @Test func windowsDateFormatParses() throws {
        let json = #"[{"Time":"2026-09-24T10:12:13.1234567","SourceText":"a","TranslatedText":"b","SourceLanguage":null,"TargetLanguage":"zh-Hans","Engine":"x"}]"#
        let entries = try AppPaths.makeDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].languagePairText.contains("→") == true)
    }
}
