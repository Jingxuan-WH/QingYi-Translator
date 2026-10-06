import AppKit
import QingYiCore
import SwiftUI

/// A field that records a key combination: click it, press the keys. Esc cancels, ⌫ clears.
struct HotkeyRecorder: NSViewRepresentable {
    var text: String
    var onFocusChange: (Bool) -> Void
    var onModifiers: (HotkeyModifiers) -> Void
    var onGesture: (HotkeyGesture) -> Void
    var onClear: () -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onFocusChange = onFocusChange
        field.onModifiers = onModifiers
        field.onGesture = onGesture
        field.onClear = onClear
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.onFocusChange = onFocusChange
        field.onModifiers = onModifiers
        field.onGesture = onGesture
        field.onClear = onClear
        field.text = text
    }
}

final class RecorderField: NSView {
    var onFocusChange: ((Bool) -> Void)?
    var onModifiers: ((HotkeyModifiers) -> Void)?
    var onGesture: ((HotkeyGesture) -> Void)?
    var onClear: (() -> Void)?

    var text = "" {
        didSet { needsDisplay = true }
    }

    private var monitor: Any?
    private var focused = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 30) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        focused = true
        onFocusChange?(true)
        // A local monitor sees the keys before the menu bar does, so ⌘-combinations can be recorded.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.focused, event.window == self.window else { return event }
            return self.handle(event) ? nil : event
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        focused = false
        onFocusChange?(false)
        return true
    }

    private static func modifiers(of event: NSEvent) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    /// True when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = RecorderField.modifiers(of: event)
        if event.type == .flagsChanged {
            onModifiers?(modifiers)
            return false
        }
        let keyCode = UInt32(event.keyCode)
        if modifiers.isEmpty && (keyCode == 53 || keyCode == 48) { // Esc, Tab
            window?.makeFirstResponder(nil)
            return true
        }
        if modifiers.isEmpty && (keyCode == 51 || keyCode == 117) { // ⌫, ⌦
            onClear?()
            return true
        }
        if [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(event.keyCode) { // modifier keys and fn
            return true
        }
        onGesture?(HotkeyGesture(modifiers: modifiers, keyCode: keyCode))
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        Palette.dynamicNS(0xFFFFFF, 0x20232B).setFill()
        path.fill()
        (focused ? Palette.dynamicNS(0x4F5BD5, 0x9AA3F5) : Palette.dynamicNS(0xD3D9E2, 0x3A3F4B)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = text.isEmpty ? L("点击后按下组合键", "Click, then press the keys") : text
        let color = text.isEmpty ? Palette.dynamicNS(0x98A0AE, 0x767D8C) : Palette.textPrimaryNS
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2, width: bounds.width, height: size.height), withAttributes: attributes)
    }
}
