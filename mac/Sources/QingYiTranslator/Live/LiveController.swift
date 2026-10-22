import AppKit
import QingYiCore
import SwiftUI

/// Owns the live transcription window, its floating captions and its global hotkey (the Mac counterpart of App.Live.cs).
/// Closing the window stops listening; the transcript stays for the next time it is opened.
@MainActor
final class LiveController: NSObject, NSWindowDelegate {
    private unowned let app: AppDelegate
    private let settings: AppSettings
    let model: LiveViewModel
    private var window: NSWindow?
    private var captions: CaptionPanel?
    private let hotkey = GlobalHotkey(id: 0x515B)
    private(set) var activeHotkey: HotkeyGesture?
    private var frameSave: DispatchWorkItem?

    init(app: AppDelegate, settings: AppSettings, glossary: Glossary) {
        self.app = app
        self.settings = settings
        model = LiveViewModel(settings: settings, glossary: glossary)
        super.init()
        model.openSettings = { [weak app] in app?.openSettings() }
        model.captionsChanged = { [weak self] previous, current in self?.showCaptions(previous, current) }
        hotkey.pressed = { [weak self] in self?.hotkeyPressed() }
    }

    var isWindowVisible: Bool { window?.isVisible == true }

    var windowForSnapshots: NSWindow? { window }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.updateCaptions()
    }

    func shutdown() {
        model.stop()
        captions?.close()
        hotkey.unregister()
    }

    // ---------------- hotkey ----------------

    /// Registers the hotkey from the settings; returns why it couldn't be, if it couldn't.
    func applyHotkey() -> String? {
        hotkey.unregister()
        activeHotkey = nil
        guard settings.live.hotkeyEnabled else { return nil }
        guard let gesture = HotkeyGesture.parse(settings.live.hotkey) else {
            return L("实时转录的快捷键设置无效，请在设置中重新设置", "The live transcription hotkey is invalid. Please set it again in Settings")
        }
        guard hotkey.register(gesture) else {
            return L("实时转录的快捷键 \(gesture) 注册失败，请在设置中更换", "The live transcription hotkey \(gesture) could not be registered. Please pick another one in Settings")
        }
        activeHotkey = gesture
        return nil
    }

    func suspendHotkey() { hotkey.unregister() }

    func resumeHotkey() {
        if let gesture = activeHotkey {
            hotkey.register(gesture)
        }
    }

    /// Starts listening (opening the window), or stops when already listening.
    private func hotkeyPressed() {
        if model.isRunning {
            model.stop()
        } else {
            show()
            model.startOrResume()
        }
    }

    // ---------------- window ----------------

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("实时转录", "Live transcription")
        window.minSize = NSSize(width: 600, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LiveView(model: model, window: { [weak window] in window }).environmentObject(Loc.shared))
        if let saved = settings.live.windowFrame, saved.width >= 400, saved.height >= 300,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)) }) {
            window.setFrame(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height), display: false)
        } else {
            window.center()
        }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        saveFrame()
        captions?.orderOut(nil)
        app.liveWindowClosed()
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }

    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }

    func windowDidChangeOcclusionState(_ notification: Notification) { model.updateCaptions() }

    private func scheduleFrameSave() {
        frameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        frameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        settings.live.windowFrame = WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        settings.save()
    }

    // ---------------- captions ----------------

    private func showCaptions(_ previous: TranscriptLine?, _ current: TranscriptLine?) {
        guard settings.live.showCaptions, let window, window.isVisible || window.isMiniaturized else {
            captions?.orderOut(nil)
            return
        }
        let panel = captions ?? makeCaptions()
        captions = panel
        panel.model.previous = previous
        panel.model.current = current
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        panel.fitHeight()
    }

    private func makeCaptions() -> CaptionPanel {
        let model = CaptionModel(fontSize: settings.live.captionFontSize)
        let panel = CaptionPanel(model: model, close: { [weak self] in
            self?.model.showCaptions = false
        }, changeSize: { [weak self, weak model] delta in
            guard let self, let model else { return }
            let size = min(max(settings.live.captionFontSize + delta, LiveSettings.minCaptionFontSize), LiveSettings.maxCaptionFontSize)
            settings.live.captionFontSize = size
            settings.save()
            model.fontSize = size
            captions?.fitHeight()
        })
        if let saved = settings.live.captionFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: saved.x + 20, y: saved.y + 20)) }) {
            panel.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
        } else {
            panel.placeAtBottom()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self, weak panel] _ in
            guard let self, let frame = panel?.frame else { return }
            MainActor.assumeIsolated {
                self.settings.live.captionFrame = WindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
                self.settings.save()
            }
        }
        return panel
    }
}
