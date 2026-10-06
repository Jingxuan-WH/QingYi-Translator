import AppKit
import Carbon.HIToolbox
import QingYiCore

/// Gets the text the user selected in another program, via the clipboard.
enum SelectionReader {
    /// After ⌘C⌘C: returns what the user's own copy put on the clipboard, or nil when nothing new was copied.
    /// `changeCountBeforeFirstCopy` is nil when the watcher already saw the clipboard change.
    static func readDoubleCopy(changeCountBeforeFirstCopy: Int?) async -> String? {
        if let before = changeCountBeforeFirstCopy {
            if !(await waitForClipboardChange(from: before, timeout: 0.6)) {
                return nil
            }
            try? await Task.sleep(nanoseconds: 60_000_000) // let the second copy finish writing
        }
        return NSPasteboard.general.string(forType: .string)
    }

    /// After the custom hotkey: presses ⌘C in the frontmost program and returns the copied text,
    /// or nil when nothing is selected. Optionally puts the previous clipboard content back.
    /// Needs the Accessibility permission to post the key press.
    static func captureSelection(hotkey: HotkeyGesture, restoreClipboard: Bool) async -> String? {
        // Simulating ⌘C while the hotkey is still held would turn it into e.g. ⌥⌘C, so wait for the user to let go first.
        if !(await waitForKeysReleased(hotkey: hotkey, timeout: 1.5)) {
            Log.info("快捷键按住时间过长，已跳过取词")
            return nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? ClipboardSnapshot.capture() : nil
        let before = pasteboard.changeCount
        guard KeyboardSimulator.sendCommandC() else { return nil }
        if !(await waitForClipboardChange(from: before, timeout: 0.7)) {
            return nil // nothing was copied, so the clipboard is untouched
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        let text = pasteboard.string(forType: .string)
        snapshot?.restore()
        return text
    }

    private static func waitForClipboardChange(from before: Int, timeout: TimeInterval) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while NSPasteboard.general.changeCount == before {
            if ProcessInfo.processInfo.systemUptime - start > timeout {
                return false
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return true
    }

    private static func waitForKeysReleased(hotkey: HotkeyGesture, timeout: TimeInterval) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while isAnyKeyDown(hotkey) {
            if ProcessInfo.processInfo.systemUptime - start > timeout {
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private static func isAnyKeyDown(_ hotkey: HotkeyGesture) -> Bool {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        if !modifiers.isEmpty {
            return true
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hotkey.keyCode))
    }
}

enum KeyboardSimulator {
    /// Posts ⌘C to the frontmost application. Returns false when the events could not be created.
    static func sendCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// A copy of everything on the clipboard, so it can be put back after we borrow it.
final class ClipboardSnapshot {
    private var items: [[NSPasteboard.PasteboardType: Data]] = []
    private var wasEmpty = false

    static func capture() -> ClipboardSnapshot? {
        let snapshot = ClipboardSnapshot()
        let pasteboard = NSPasteboard.general
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        snapshot.wasEmpty = pasteboardItems.isEmpty
        for item in pasteboardItems {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // Promised or lazily provided data can't be read; skip it.
                if let data = item.data(forType: type) {
                    copy[type] = data
                }
            }
            if !copy.isEmpty {
                snapshot.items.append(copy)
            }
        }
        return snapshot
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if wasEmpty || items.isEmpty {
            return
        }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        if !pasteboard.writeObjects(restored) {
            Log.error("恢复剪贴板失败")
        }
    }
}
