import AppKit
import SwiftUI
import Testing
@testable import QingYiTranslator

@MainActor
@Suite(.serialized)
struct PaneTextViewTests {
    @Test func pendingNativeEditSurvivesTranslationRefresh() throws {
        let fixture = try EditorFixture()
        // An input method can change native storage before the delegate publishes
        // the committed text. A redraw in that interval must not restore the old binding.
        fixture.editor.textStorage?.append(NSAttributedString(string: " new input"))
        fixture.model.output = "翻译已完成"
        fixture.refresh()
        #expect(fixture.editor.string == "Hello. new input")
        fixture.editor.didChangeText()
        fixture.refresh()
        #expect(fixture.model.source == "Hello. new input")
    }

    @Test func twoEditsBeforeNextRedrawKeepPendingNativeText() throws {
        let fixture = try EditorFixture()
        fixture.editor.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.editor.textStorage?.append(NSAttributedString(string: "B"))
        fixture.model.output = "刷新译文"
        fixture.refresh()
        #expect(fixture.editor.string == "Hello.AB")
        fixture.editor.didChangeText()
        #expect(fixture.model.source == "Hello.AB")
    }

    @Test func typingSurvivesTranslationRefreshes() throws {
        let fixture = try EditorFixture()
        for character in " Continue typing while translation streams." {
            fixture.editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            fixture.model.output += "译"
            fixture.refresh()
        }
        #expect(fixture.editor.string == "Hello. Continue typing while translation streams.")
        #expect(fixture.model.source == fixture.editor.string)
    }

    @Test func markedTextSurvivesTranslationRefresh() throws {
        let fixture = try EditorFixture()
        fixture.editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.editor.hasMarkedText())
        let composing = fixture.editor.string
        fixture.model.output = "翻译已完成"
        fixture.refresh()
        #expect(fixture.editor.string == composing)
        #expect(fixture.editor.hasMarkedText())
        fixture.editor.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.refresh()
        #expect(fixture.model.source == "Hello.拼")
        #expect(fixture.editor.string == fixture.model.source)
    }

    @Test func uncommittedMarkedTextSurvivesTranslationRefresh() throws {
        let fixture = try EditorFixture()
        // Simulate an input method that doesn't publish its composition to the
        // model until the candidate is committed.
        let delegate = fixture.editor.delegate
        fixture.editor.delegate = nil
        fixture.editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.editor.delegate = delegate
        #expect(fixture.model.source == "Hello.")
        fixture.model.output = "翻译已完成"
        fixture.refresh()
        #expect(fixture.editor.string == "Hello.pin")
        #expect(fixture.editor.hasMarkedText())
        fixture.editor.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.refresh()
        #expect(fixture.model.source == "Hello.拼")
    }

    @Test func explicitSourceReplacementStillWorks() throws {
        let fixture = try EditorFixture()
        fixture.model.source = "Text from history"
        fixture.refresh()
        #expect(fixture.editor.string == "Text from history")
        fixture.model.source = ""
        fixture.refresh()
        #expect(fixture.editor.string.isEmpty)
    }
}

@MainActor
private final class EditorModel: ObservableObject {
    @Published var source = "Hello."
    @Published var output = ""
}

private struct EditorHost: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack {
            PaneTextView(text: $model.source, isEditable: true)
            Text(model.output)
        }
    }
}

@MainActor
private final class EditorFixture {
    let model = EditorModel()
    let window: NSWindow
    let hosting: NSHostingView<EditorHost>
    let editor: NSTextView

    init() throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        hosting = NSHostingView(rootView: EditorHost(model: model))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        editor = try #require(Self.findEditor(in: hosting))
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    func refresh() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        hosting.layoutSubtreeIfNeeded()
    }

    private static func findEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }
}
