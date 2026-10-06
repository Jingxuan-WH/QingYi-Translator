import AppKit
import ApplicationServices

/// The Accessibility permission (System Settings → Privacy & Security → Accessibility). Without it the app
/// can still see ⌘C⌘C through the clipboard, but it can't watch keys or copy a selection for the hotkey.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to show its own "allow access" prompt (shown once per app) and opens the settings pane.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettingsPane()
    }

    static func openSettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
