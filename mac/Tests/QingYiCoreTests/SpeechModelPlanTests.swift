import Testing
@testable import QingYiCore

struct SpeechModelPlanTests {
    @Test func onlyAnInstalledModelIsReady() {
        #expect(SpeechModelPlan.action(for: .installed) == .ready)
        #expect(SpeechModelPlan.action(for: .supported) == .download)
        #expect(SpeechModelPlan.action(for: .downloading) == .download)
        #expect(SpeechModelPlan.action(for: .unsupported) == .unsupported)
    }

    @Test func reservationsAreOnlyReleasedWhenTheLimitIsReached() {
        // Room left, or the needed locales are reserved already.
        #expect(SpeechModelPlan.reservationsToRelease(reserved: ["ja-JP"], needed: ["zh-CN", "en-US"], maximum: 5).isEmpty)
        #expect(SpeechModelPlan.reservationsToRelease(reserved: ["zh-CN", "en-US", "ja-JP", "ko-KR", "fr-FR"],
                                                      needed: ["zh-CN", "en-US"], maximum: 5).isEmpty)
        // Full: give up just enough of the ones not needed now.
        #expect(SpeechModelPlan.reservationsToRelease(reserved: ["ja-JP", "ko-KR", "zh-CN", "fr-FR", "de-DE"],
                                                      needed: ["zh-CN", "en-US"], maximum: 5) == ["ja-JP"])
        #expect(SpeechModelPlan.reservationsToRelease(reserved: ["ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"],
                                                      needed: ["zh-CN", "en-US"], maximum: 5) == ["ja-JP", "ko-KR"])
        // Never the ones still needed, even if that isn't enough.
        #expect(SpeechModelPlan.reservationsToRelease(reserved: ["zh-CN"], needed: ["zh-CN", "en-US"], maximum: 1).isEmpty)
    }

    @Test func aDownloadThatDidNotHelpIsNotOfferedAgain() {
        #expect(SpeechModelPlan.stillMissing(["zh-Hans"], afterDownloading: ["zh-Hans"]) == ["zh-Hans"])
        #expect(SpeechModelPlan.stillMissing(["en"], afterDownloading: ["zh-Hans"]).isEmpty)
        #expect(SpeechModelPlan.stillMissing(["zh-Hans", "en"], afterDownloading: []).isEmpty)
    }

    @Test func localeKeysIgnoreScriptAndCase() {
        #expect(SpeechModelPlan.key(languageCode: "zh", region: "CN") == SpeechModelPlan.key(languageCode: "ZH", region: "cn"))
        #expect(SpeechModelPlan.key(languageCode: "zh", region: "CN") != SpeechModelPlan.key(languageCode: "zh", region: "TW"))
        #expect(SpeechModelPlan.key(languageCode: "en", region: nil) == "en")
    }
}
