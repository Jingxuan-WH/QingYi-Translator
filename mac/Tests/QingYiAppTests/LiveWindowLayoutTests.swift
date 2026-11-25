import AppKit
import QingYiCore
import SwiftUI
import Testing
@testable import QingYiTranslator

@MainActor
struct LiveWindowLayoutTests {
    @Test func longPermissionBannerKeepsTranscriptVisibleInSmallestWindow() throws {
        _ = NSApplication.shared
        let settings = AppSettings()
        settings.live.audioSource = LiveSettings.sourceBoth
        let model = LiveViewModel(settings: settings, glossary: Glossary.load())
        model.reportMicrophoneSilence()
        _ = model.transcript.finalize(1, text: "A line to keep visible", start: 0, end: 1)

        let controller = NSHostingController(rootView: LiveView(model: model, window: { nil }).environmentObject(Loc.shared))
        let size = CGSize(width: 390, height: 420)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(size)
        defer { window.orderOut(nil) }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }

        let deadline = Date().addingTimeInterval(1)
        var regions: [NSScrollView] = []
        repeat {
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            regions = scrollViews(in: controller.view)
            if regions.count == 2, regions.allSatisfy({ $0.documentView != nil && $0.bounds.height > 0 }) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline

        // The single transcript row fits its viewport. Only the controls and
        // permission message should need scrolling, leaving room to read on.
        let transcript = try #require(regions.first { ($0.documentView?.frame.height ?? 0) <= $0.bounds.height })
        let header = try #require(regions.first { ($0.documentView?.frame.height ?? 0) > $0.bounds.height })
        #expect(transcript.bounds.height >= 76)
        #expect(header.bounds.height < 240)
    }
}
