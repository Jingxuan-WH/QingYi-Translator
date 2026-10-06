import AppKit
import SwiftUI

struct MenuEntry {
    let title: String
    let isSelected: Bool
    let isSeparator: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        isSeparator = false
        self.action = action
    }

    static let separator = MenuEntry(separator: ())

    private init(separator: Void) {
        title = ""
        isSelected = false
        isSeparator = true
        action = {}
    }
}

/// The bold language pickers of the language bar: a label with a chevron that pops up a native menu.
/// (SwiftUI's Menu rearranges its label on macOS, so this is drawn by hand.)
struct LanguageMenuButton: NSViewRepresentable {
    var title: String
    var entries: [MenuEntry]
    var accessibilityLabel: String

    func makeNSView(context: Context) -> LanguageMenuControl {
        let control = LanguageMenuControl()
        control.title = title
        control.entries = entries
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }

    func updateNSView(_ control: LanguageMenuControl, context: Context) {
        control.title = title
        control.entries = entries
        control.setAccessibilityLabel(accessibilityLabel)
    }
}

final class LanguageMenuControl: NSView {
    var title = "" {
        didSet {
            if title != oldValue {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    var entries: [MenuEntry] = []

    private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var textSize: NSSize { (title as NSString).size(withAttributes: [.font: font]) }

    override var intrinsicContentSize: NSSize { NSSize(width: 10 + ceil(textSize.width) + 6 + 12 + 10, height: 32) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Palette.dynamicNS(0xEEF1F6, 0x2A2E38).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let size = textSize
        let textRect = NSRect(x: 10, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        (title as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: Palette.textPrimaryNS])

        // Chevron
        let chevron = NSBezierPath()
        let x = 10 + size.width + 6
        let midY = bounds.midY
        chevron.move(to: NSPoint(x: x, y: midY + 2.5))
        chevron.line(to: NSPoint(x: x + 5, y: midY - 2.5))
        chevron.line(to: NSPoint(x: x + 10, y: midY + 2.5))
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        Palette.dynamicNS(0x5F6878, 0xA7ADBA).setStroke()
        chevron.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = entry.isSelected ? .on : .off
            menu.addItem(item)
        }
        hovering = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    override func accessibilityValue() -> Any? { title }

    override func accessibilityPerformPress() -> Bool {
        mouseDown(with: NSEvent())
        return true
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard entries.indices.contains(sender.tag) else { return }
        entries[sender.tag].action()
    }
}
