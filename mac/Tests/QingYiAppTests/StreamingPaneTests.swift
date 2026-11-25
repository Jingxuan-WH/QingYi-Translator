import AppKit
import QuartzCore
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
        // On macOS 15 an offscreen NSHostingView may schedule representable updates for
        // the next run-loop turn. layoutSubtreeIfNeeded alone does not deliver them.
        func awaitNativeLength(_ length: Int) throws {
            let deadline = Date(timeIntervalSinceNow: 1)
            while textView.textStorage?.length != length && Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
                refresh()
            }
            try #require(textView.textStorage?.length == length)
        }
        var expectedLength = stream.text.utf16.count
        try awaitNativeLength(expectedLength)
        let scroll = try #require(textView.enclosingScrollView)
        textView.scrollToBeginningOfDocument(nil)
        refresh()
        let readingY = scroll.contentView.bounds.minY

        let pieces = ["e", "\u{301}", "👩", "\u{200D}", "💻", "继续。\n"]
        var samples: [Double] = []
        for index in 0..<180 {
            let start = ProcessInfo.processInfo.systemUptime
            let chunk = pieces[index % pieces.count]
            stream.text += chunk
            expectedLength += chunk.utf16.count
            refresh()
            try awaitNativeLength(expectedLength)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        #expect(textView.string.utf8.elementsEqual(stream.text.utf8))
        #expect(abs(scroll.contentView.bounds.minY - readingY) < 2)
        samples.sort()
        print(String(format: "Long stream, 180 native updates: median %.2f ms, P95 %.2f ms, max %.2f ms",
                     samples[samples.count / 2], samples[samples.count * 95 / 100], samples.last ?? 0))

        // Opt in locally with QINGYI_FRAME_PROBE=1 to exercise actual window
        // display-link callbacks without opening a window during normal CI.
        if #available(macOS 14, *), ProcessInfo.processInfo.environment["QINGYI_FRAME_PROBE"] == "1" {
            window.title = "QingYi · Streaming performance"
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            let probe = DisplayProbe()
            var intervals: [Double] = []
            var updateCosts: [Double] = []
            var scrollOnly: [Double] = []
            var lastTick: Double?
            var frames = 0
            probe.update = {
                let now = CACurrentMediaTime()
                if let previous = lastTick {
                    if (10..<190).contains(frames) { scrollOnly.append(1000 * (now - previous)) }
                    if frames >= 200 { intervals.append(1000 * (now - previous)) }
                }
                lastTick = now
                if frames >= 190 { stream.text += pieces[frames % pieces.count] }
                textView.scroll(NSPoint(x: 0, y: CGFloat(frames % 190) * 2))
                refresh()
                if frames >= 200 { updateCosts.append((CACurrentMediaTime() - now) * 1000) }
                frames += 1
            }
            let link = window.displayLink(target: probe, selector: #selector(DisplayProbe.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            let timeout = Date().addingTimeInterval(12)
            while frames < 380 && Date() < timeout {
                _ = RunLoop.current.run(mode: .default, before: timeout)
            }
            link.invalidate()
            try #require(intervals.count >= 120 && scrollOnly.count >= 120)
            scrollOnly.sort()
            print(String(format: "Scroll-only baseline: %d frames, median %.2f ms, P95 %.2f ms, max %.2f ms", scrollOnly.count, scrollOnly[scrollOnly.count/2], scrollOnly[scrollOnly.count*95/100], scrollOnly.last ?? 0))
            intervals.sort()
            updateCosts.sort()
            let missed = intervals.filter { $0 > 25 }.count
            print(String(format: "Visible window display link: %d frames, median %.2f ms, P95 %.2f ms, max %.2f ms, %d over 25 ms; update work P95 %.2f ms",
                         intervals.count, intervals[intervals.count/2], intervals[intervals.count*95/100], intervals.last ?? 0,
                         missed, updateCosts[updateCosts.count*95/100]))
        }

        stream.generation += 1
        stream.text = "完全不同的译文"
        refresh()
        try awaitNativeLength(stream.text.utf16.count)
        #expect(textView.string == stream.text)
        withExtendedLifetime(window) {}
    }
}

@MainActor
private final class DisplayProbe: NSObject {
    var update: () -> Void = {}
    @objc func tick() { update() }
}
