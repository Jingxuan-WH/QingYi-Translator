import Testing
import Foundation
@testable import QingYiCore

struct LiveTranscriptTests {
    @Test func partialResultsAreReplacedByTheFinalOne() throws {
        let transcript = LiveTranscript()
        transcript.beginSession()
        let first = try #require(transcript.updatePartial(1, text: "hel", start: 0.5))
        let second = try #require(transcript.updatePartial(1, text: " hello wor ", start: 0.5))
        #expect(first.id == second.id)
        #expect(second.text == "hello wor")
        #expect(!second.isFinal)

        let final = try #require(transcript.finalize(1, text: "Hello, world.", start: 0.5, end: 2.25, language: "en"))
        #expect(final.id == first.id)
        #expect(final.isFinal)
        #expect(final.text == "Hello, world.")
        #expect(final.end == 2.25)
        #expect(final.language == "en")

        #expect(transcript.updatePartial(1, text: "hello wo", start: 0.5) == nil) // late partial
        #expect(transcript.lines.map(\.text) == ["Hello, world."])
    }

    @Test func emptyResultsDoNotLeaveLines() {
        let transcript = LiveTranscript()
        transcript.beginSession()
        #expect(transcript.updatePartial(1, text: "  ", start: 0) == nil)
        #expect(transcript.lines.isEmpty)
        transcript.updatePartial(2, text: "uh", start: 1)
        #expect(transcript.finalize(2, text: "", start: 1, end: 2) == nil)
        #expect(transcript.lines.isEmpty)
        transcript.updatePartial(3, text: "noise", start: 3)
        transcript.discard(3)
        #expect(transcript.lines.isEmpty)
    }

    @Test func linesStayInOrderAndDiscardKeepsFinalLines() {
        let transcript = LiveTranscript()
        transcript.beginSession()
        transcript.updatePartial(2, text: "second", start: 3)
        transcript.updatePartial(1, text: "first", start: 1)
        #expect(transcript.lines.map(\.text) == ["first", "second"])
        transcript.finalize(1, text: "First.", start: 1, end: 2)
        transcript.discard(1)
        #expect(transcript.lines.count == 2)
        #expect(transcript.finalLines.map(\.text) == ["First."])
    }

    @Test func aNewSessionContinuesAfterTheOldOne() throws {
        let transcript = LiveTranscript()
        transcript.beginSession()
        transcript.finalize(1, text: "One.", start: 0, end: 5.2)
        transcript.beginSession()
        let line = try #require(transcript.finalize(1, text: "Again.", start: 0.5, end: 1.5))
        #expect(transcript.lines.count == 2)
        #expect(line.start == 7.5)
        #expect(line.end == 8.5)
        #expect(transcript.lines[0].text == "One.")
        #expect(line.id != transcript.lines[0].id)

        transcript.clear()
        transcript.beginSession()
        #expect(transcript.finalize(1, text: "Fresh.", start: 1, end: 2)?.start == 1)
    }

    @Test func translationsAreStoredOnTheLine() throws {
        let transcript = LiveTranscript()
        transcript.beginSession()
        let line = try #require(transcript.finalize(1, text: "a b", start: 0, end: 1))
        transcript.setTranslation(id: line.id, "甲", draft: false, translating: true)
        transcript.setTranslation(id: line.id, "甲乙", draft: false, translating: false)
        let stored = try #require(transcript.line(id: line.id))
        #expect(stored.translation == "甲乙")
        #expect(!stored.isTranslating)
        #expect(stored.isFinal)
    }
}

struct LiveTranslationContextTests {
    @Test func keepsTheLastFewTurns() {
        let context = LiveTranslationContext()
        for i in 1...5 {
            context.add(source: "s\(i)", translation: "t\(i)")
        }
        context.add(source: " ", translation: "ignored")
        #expect(context.turns.map(\.source) == ["s3", "s4", "s5"])
        context.clear()
        #expect(context.turns.isEmpty)
    }

    @Test func staysWithinTheCharacterBudget() {
        let context = LiveTranslationContext()
        context.add(source: String(repeating: "a", count: 900), translation: "x")
        context.add(source: String(repeating: "b", count: 900), translation: "y")
        #expect(context.turns.map(\.translation) == ["y"])
        context.add(source: String(repeating: "c", count: 2000), translation: "z")
        #expect(context.turns.map(\.translation) == ["z"]) // the latest is kept even when too long
    }

    @Test func instructionsAndLanguages() {
        #expect(LiveTranslationContext.buildInstructions(" ") == LiveTranslationContext.instructions)
        #expect(LiveTranslationContext.buildInstructions(" formal ").hasPrefix("formal\n"))
        let zh = Languages.simplifiedChinese
        #expect(LiveTranslationContext.resolveLanguages("今天我们讨论潮流计算", source: nil, preferredTarget: zh).target == Languages.english)
        #expect(LiveTranslationContext.resolveLanguages("Today we talk about power flow", source: nil, preferredTarget: zh).target == zh)
        let fixed = LiveTranslationContext.resolveLanguages("whatever", source: Languages.english, preferredTarget: Languages.english)
        #expect(fixed.promptSource == Languages.english)
        #expect(fixed.target == zh)
    }
}

struct LanguageArbiterTests {
    private let zh = Languages.simplifiedChinese
    private let en = Languages.english

    @Test func higherConfidenceWins() {
        let picked = LanguageArbiter.pick([
            RecognitionCandidate(language: zh, text: "今天我们讲潮流计算", confidence: 0.82),
            RecognitionCandidate(language: en, text: "Jin tian women", confidence: 0.31),
        ], previous: nil)
        #expect(picked?.language == zh)
    }

    @Test func latinTextFromTheChineseRecognizerMeansEnglish() {
        let picked = LanguageArbiter.pick([
            RecognitionCandidate(language: zh, text: "today we talk about power flow", confidence: 0.7),
            RecognitionCandidate(language: en, text: "Today we talk about power flow.", confidence: 0.6),
        ], previous: zh)
        #expect(picked?.language == en)
    }

    @Test func closeCallsKeepThePreviousLanguage() {
        let candidates = [
            RecognitionCandidate(language: zh, text: "好的", confidence: 0.5),
            RecognitionCandidate(language: en, text: "Ok", confidence: 0.53),
        ]
        #expect(LanguageArbiter.pick(candidates, previous: zh)?.language == zh)
        #expect(LanguageArbiter.pick(candidates, previous: en)?.language == en)
    }

    @Test func withoutConfidencesTheScriptDecides() {
        let chinese = [
            RecognitionCandidate(language: zh, text: "我们开始上课", confidence: nil),
            RecognitionCandidate(language: en, text: "Well, can she shall come", confidence: nil),
        ]
        #expect(LanguageArbiter.pick(chinese, previous: nil)?.language == zh)
        let english = [
            RecognitionCandidate(language: zh, text: "Let's get started", confidence: nil),
            RecognitionCandidate(language: en, text: "Let's get started.", confidence: nil),
        ]
        #expect(LanguageArbiter.pick(english, previous: zh)?.language == en)
    }

    @Test func emptyResultsAreIgnored() {
        #expect(LanguageArbiter.pick([RecognitionCandidate(language: zh, text: " ", confidence: 0.9)], previous: nil) == nil)
        #expect(LanguageArbiter.pick([
            RecognitionCandidate(language: zh, text: "", confidence: 0.9),
            RecognitionCandidate(language: en, text: "Hi", confidence: 0.2),
        ], previous: zh)?.language == en)
        #expect(SpeechLocales.languages(for: "auto") == [zh, en])
        #expect(SpeechLocales.languages(for: "ja") == [Languages.japanese])
        #expect(SpeechLocales.identifier(for: zh) == "zh-CN")
    }
}

struct TranscriptExportTests {
    private func sample() -> LiveTranscript {
        let transcript = LiveTranscript()
        transcript.beginSession()
        for (utterance, text, start, end, translation, draft) in [
            (1, "Hello everyone.", 1.2, 2.0, "大家好。", false),
            (2, "Today: power flow.", 2.5, 5.75, "今天讲潮流。", false),
            (3, "No translation yet.", 6.0, 7.5, "草稿", true),
        ] {
            let line = transcript.finalize(utterance, text: text, start: start, end: end)!
            transcript.setTranslation(id: line.id, translation, draft: draft, translating: false)
        }
        transcript.updatePartial(4, text: "still talking", start: 8)
        return transcript
    }

    @Test func timeFormats() {
        #expect(TranscriptExport.formatSrtTime(0) == "00:00:00,000")
        #expect(TranscriptExport.formatSrtTime(3661.2346) == "01:01:01,235")
        #expect(TranscriptExport.formatSrtTime(-3) == "00:00:00,000")
        #expect(TranscriptExport.formatClock(65.9) == "01:05")
        #expect(TranscriptExport.formatClock(3725) == "1:02:05")
    }

    @Test func bilingualSrt() {
        let srt = TranscriptExport.build(sample().lines, format: .srt, content: .bilingual)
        #expect(srt == "1\n00:00:01,200 --> 00:00:02,000\nHello everyone.\n大家好。\n\n"
            + "2\n00:00:02,500 --> 00:00:05,750\nToday: power flow.\n今天讲潮流。\n\n"
            + "3\n00:00:06,000 --> 00:00:07,500\nNo translation yet.\n\n")
    }

    @Test func translationOnlySkipsUntranslatedLinesAndRenumbers() {
        let srt = TranscriptExport.build(sample().lines, format: .srt, content: .translation)
        #expect(srt == "1\n00:00:01,200 --> 00:00:02,000\n大家好。\n\n2\n00:00:02,500 --> 00:00:05,750\n今天讲潮流。\n\n")
    }

    @Test func shortCuesAreStretchedWithoutOverlapping() {
        let transcript = LiveTranscript()
        transcript.beginSession()
        transcript.finalize(1, text: "Hi.", start: 1.0, end: 1.1)
        transcript.finalize(2, text: "Yes.", start: 1.5, end: 1.6)
        transcript.finalize(3, text: "Ok.", start: 4.0, end: 4.1)
        let srt = TranscriptExport.build(transcript.lines, format: .srt, content: .original)
        #expect(srt.contains("00:00:01,000 --> 00:00:01,500"))
        #expect(srt.contains("00:00:01,500 --> 00:00:02,300"))
        #expect(srt.contains("00:00:04,000 --> 00:00:04,800"))
    }

    @Test func plainText() {
        #expect(TranscriptExport.build(sample().lines, format: .text, content: .original)
            == "[00:01] Hello everyone.\n[00:02] Today: power flow.\n[00:06] No translation yet.\n")
        #expect(TranscriptExport.build(sample().lines, format: .text, content: .bilingual)
            == "[00:01] Hello everyone.\n    大家好。\n\n[00:02] Today: power flow.\n    今天讲潮流。\n\n[00:06] No translation yet.\n\n")
    }

    @Test func liveSettingsRoundTripAndDefaults() throws {
        var settings = LiveSettings()
        settings.audioSource = "nonsense"
        settings.captionFontSize = 200
        settings.normalize()
        #expect(settings.audioSource == LiveSettings.sourceMicrophone)
        #expect(settings.captionFontSize == LiveSettings.maxCaptionFontSize)

        let decoded = try JSONDecoder().decode(LiveSettings.self, from: Data(#"{"audioSource":"both","translatePartials":true}"#.utf8))
        #expect(decoded.audioSource == LiveSettings.sourceBoth)
        #expect(decoded.translatePartials)
        #expect(decoded.targetLanguage == Languages.simplifiedChinese.code)
        let again = try JSONDecoder().decode(LiveSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again == decoded)
    }
}
