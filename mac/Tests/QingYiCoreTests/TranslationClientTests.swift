import Testing
import Foundation
@testable import QingYiCore

struct TranslationClientTests {
    @Test func systemPromptMentionsGlossaryAndContext() {
        let prompt = TranslationClient.buildSystemPrompt(source: nil, target: Languages.simplifiedChinese, extraInstructions: " formal ",
                                                         hasContext: true, glossary: [GlossaryEntry(source: "power flow", target: "潮流")])
        #expect(prompt.hasPrefix("You are a professional translation engine. Translate the user's text into Simplified Chinese."))
        #expect(prompt.contains("6. Earlier messages"))
        #expect(prompt.contains("- power flow = 潮流"))
        #expect(prompt.hasSuffix("Additional requirements from the user:\nformal\n"))
        let plain = TranslationClient.buildSystemPrompt(source: Languages.english, target: Languages.japanese, extraInstructions: "", hasContext: false)
        #expect(plain.contains("from English into Japanese"))
        #expect(!(plain.contains("Glossary")))
    }

    @Test func bodyIncludesOptionalParametersOnlyWhenAsked() throws {
        let preset = ProviderCatalog.get(ProviderCatalog.deepSeekId)
        let request = TranslationRequest(text: "你好", source: nil, target: Languages.english,
                                         context: [TranslationTurn(source: "a", translation: "b")])
        let full = try JSONSerialization.jsonObject(with: TranslationClient.buildBody(preset: preset, model: "deepseek-flash", extraInstructions: "",
                                                                                     request: request, includeOptional: true)) as! [String: Any]
        #expect(full["temperature"] as? Double == 1.3)
        #expect((full["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(full["stream"] as? Bool == true)
        #expect((full["messages"] as? [[String: Any]])?.count == 4)
        let bare = try JSONSerialization.jsonObject(with: TranslationClient.buildBody(preset: preset, model: "m", extraInstructions: "",
                                                                                     request: request, includeOptional: false)) as! [String: Any]
        #expect((bare["temperature"]) == nil)
        #expect((bare["thinking"]) == nil)
    }

    @Test func endpointBuilding() throws {
        #expect(try TranslationClient.buildEndpoint("https://api.deepseek.com/").absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(try TranslationClient.buildEndpoint("http://localhost:11434/v1/chat/completions").absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(throws: (any Error).self) { try TranslationClient.buildEndpoint("") }
        #expect(throws: (any Error).self) { try TranslationClient.buildEndpoint("ftp://x") }
    }

    @Test func chunkParsingAndErrors() {
        let chunk = TranslationClient.parseChunk(#"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)
        #expect(chunk.content == "你好")
        #expect((chunk.finishReason) == nil)
        #expect(TranslationClient.parseChunk(#"{"error":{"message":"bad"}}"#).error == "bad")
        #expect(TranslationClient.parseChunk("not json").content == nil)
        let error = TranslationClient.error(fromStatus: 401, body: #"{"error":{"message":"Invalid key"}}"#)
        #expect(error.needsSettings)
        #expect(error.message.contains("401"))
        #expect(error.message.contains("Invalid key"))
        #expect(!(TranslationClient.error(fromStatus: 429, body: "").needsSettings))
    }

    @Test func thinkFilter() {
        var filter = TranslationClient.LeadingThinkFilter()
        #expect(filter.feed("<th") == "")
        #expect(filter.feed("ink>thinking…</think>\n\nHello") == "Hello")
        #expect(filter.feed(" world") == " world")
        var plain = TranslationClient.LeadingThinkFilter()
        #expect(plain.feed("He") == "He")
        #expect(plain.feed("llo") == "llo")
        var short = TranslationClient.LeadingThinkFilter()
        #expect(short.feed("<") == "")
        #expect(short.flush() == "<")
    }
}
