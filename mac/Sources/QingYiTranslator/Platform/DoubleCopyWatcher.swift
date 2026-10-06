import AppKit
import QingYiCore

/// Detects DeepL-style "⌘C ⌘C": two copies in quick succession.
///
/// With the Accessibility permission the keyboard is watched directly, like the Windows version.
/// Without it the clipboard is polled instead: two clipboard changes with the same text within
/// half a second can only come from the user pressing ⌘C twice. The user's own ⌘C does the copying,
/// so nothing is simulated and nothing is typed on their behalf.
final class DoubleCopyWatcher {
    enum Mode { case keyboard, clipboard }

    private static let maxInterval: TimeInterval = 0.5
    private static let minInterval: TimeInterval = 0.06 // two writes closer than this are one copy operation writing twice
    private static let pollInterval: TimeInterval = 0.1

    /// Called on the main thread. The argument is the clipboard change count before the first ⌘C (keyboard mode),
    /// or nil when the text is already on the clipboard (clipboard mode).
    private let onTriggered: (Int?) -> Void

    private var monitor: Any?
    private var timer: Timer?
    private(set) var mode: Mode?

    // Keyboard mode.
    private var firstCopyTime: TimeInterval = 0
    private var changeCountBeforeFirstCopy = 0

    // Clipboard mode.
    private var lastChangeCount = 0
    private var lastChangeTime: TimeInterval = 0
    private var lastText: String?

    init(onTriggered: @escaping (Int?) -> Void) {
        self.onTriggered = onTriggered
    }

    var isRunning: Bool { mode != nil }

    /// The mode that `start()` would use right now.
    static var preferredMode: Mode { Accessibility.isTrusted ? .keyboard : .clipboard }

    func start() {
        let wanted = DoubleCopyWatcher.preferredMode
        if mode == wanted {
            return
        }
        stop()
        mode = wanted
        switch wanted {
        case .keyboard:
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                self?.onKeyDown(event)
            }
            if monitor == nil {
                mode = nil
                Log.error("无法监听键盘事件")
            }
        case .clipboard:
            lastChangeCount = NSPasteboard.general.changeCount
            lastText = nil
            let timer = Timer(timeInterval: DoubleCopyWatcher.pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        timer?.invalidate()
        timer = nil
        mode = nil
        firstCopyTime = 0
    }

    // ---------------- keyboard mode ----------------

    private func onKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 8 { // C
            if event.isARepeat {
                return
            }
            guard flags == [.command] else {
                firstCopyTime = 0
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if firstCopyTime != 0 && now - firstCopyTime <= DoubleCopyWatcher.maxInterval {
                firstCopyTime = 0
                let before = changeCountBeforeFirstCopy
                DispatchQueue.main.async { self.onTriggered(before) }
            } else {
                firstCopyTime = now
                changeCountBeforeFirstCopy = NSPasteboard.general.changeCount
            }
        } else if !DoubleCopyWatcher.isModifierKey(event.keyCode) {
            firstCopyTime = 0 // any other key breaks the sequence
        }
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode) // ⌘ ⇧ ⌥ ⌃ (both sides) and fn
    }

    // ---------------- clipboard mode ----------------

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        let delta = count - lastChangeCount
        lastChangeCount = count
        let now = ProcessInfo.processInfo.systemUptime

        // Copies made inside this app (the copy button, ⌘C in the panes) must not open the window again.
        if NSApp.isActive || delta != 1 {
            lastText = nil
            return
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            lastText = nil
            return
        }
        let interval = now - lastChangeTime
        if let previous = lastText, previous == text, interval >= DoubleCopyWatcher.minInterval, interval <= DoubleCopyWatcher.maxInterval {
            lastText = nil
            onTriggered(nil)
        } else {
            lastText = text
            lastChangeTime = now
        }
    }
}
