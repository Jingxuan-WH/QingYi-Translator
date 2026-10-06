import Foundation
import QingYiCore

/// `QingYiTranslator --translate [--to <code>] [text]`: translates the text (or stdin) with the saved settings and
/// prints the result. Handy for scripts and for testing the service connection without the window.
enum CommandLineMode {
    static func run(arguments: [String]) -> Never {
        var target: Language?
        var text: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--to", index + 1 < arguments.count {
                guard let language = Languages.find(arguments[index + 1]) else {
                    fail("Unknown language code: \(arguments[index + 1]). Known codes: \(Languages.all.map(\.code).joined(separator: ", "))")
                }
                target = language
                index += 2
            } else {
                text = (text.map { $0 + " " } ?? "") + argument
                index += 1
            }
        }
        if text == nil {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        }
        guard let input = text?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            fail("Nothing to translate. Pass the text as an argument or on stdin.")
        }

        let settings = AppSettings.load()
        Loc.shared.apply(settings.uiLanguage)
        let glossary = Glossary.load()
        let preferred = target ?? Languages.find(settings.targetLanguage) ?? Languages.simplifiedChinese
        var resolved = preferred
        if target == nil, let detected = LanguageDetector.detect(input), detected.isSameLanguage(as: preferred) {
            resolved = Languages.fallback(for: preferred)
        }
        let request = TranslationRequest(text: input, source: nil, target: resolved,
                                         glossary: settings.glossaryEnabled ? glossary.match(input) : [])
        let preset = settings.activePreset
        let config = settings.active
        let apiKey = settings.apiKey(for: settings.activeProvider)

        Task { @MainActor in
            do {
                _ = try await TranslationClient().translate(preset: preset, config: config, apiKey: apiKey,
                                                            extraInstructions: settings.extraInstructions, request: request) { piece in
                    FileHandle.standardOutput.write(Data(piece.utf8))
                }
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch let error as TranslationError {
                fail(error.message)
            } catch {
                fail("\(error)")
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
