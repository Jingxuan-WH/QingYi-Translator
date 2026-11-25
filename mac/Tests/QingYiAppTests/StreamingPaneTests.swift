import AppKit
import SwiftUI
import Testing
@testable import QingYiTranslator

@MainActor
struct StreamingPaneTests {
    private final class Stream: ObservableObject {
        @Published var text = ""
        var generation = 0
    }

    private struct Host: View {
        @ObservedObject var stream: Stream
        var body: some View {
            PaneTextView(text: .constant(stream.text), isEditable: false, outputGeneration: stream.generation)
        }
    }

    @Test func appendKeepsUnicodeAndReadingPosition() throws {
        _ = NSApplication.shared
        let stream = Stream()
        let hosting = NSHostingView(rootView: Host(stream: stream))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        func refresh() {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func editor(in view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView { return editor }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        stream.text = String(repeating: "实时翻译测试。Streaming text.\n", count: 1600)
        refresh()
        let textView = try #require(editor(in: hosting))
        let scroll = try #require(textView.enclosingScrollView)
        textView.scrollToBeginningOfDocument(nil)
        refresh()
        let readingY = scroll.contentView.bounds.minY

        let pieces = ["e", "\u{301}", "👩", "\u{200D}", "💻", "继续。\n"]
        var samples: [Double] = []
        for index in 0..<180 {
            let start = ProcessInfo.processInfo.systemUptime
            stream.text += pieces[index % pieces.count]
            refresh()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        #expect(textView.string.utf8.elementsEqual(stream.text.utf8))
        #expect(abs(scroll.contentView.bounds.minY - readingY) < 2)
        samples.sort()
        print(String(format: "Long stream, 180 native updates: median %.2f ms, P95 %.2f ms, max %.2f ms",
                     samples[samples.count / 2], samples[samples.count * 95 / 100], samples.last ?? 0))

        stream.generation += 1
        stream.text = "完全不同的译文"
        refresh()
        #expect(textView.string == stream.text)
        withExtendedLifetime(window) {}
    }
}
