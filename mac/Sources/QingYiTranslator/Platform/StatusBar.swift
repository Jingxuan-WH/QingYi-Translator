import AppKit
import QingYiCore

/// The menu bar item: a click opens the window, a right-click (or ⌃-click) shows the menu.
final class StatusBar {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let openItem: NSMenuItem
    private let settingsItem: NSMenuItem
    private let quitItem: NSMenuItem

    var openRequested: (() -> Void)?
    var settingsRequested: (() -> Void)?
    var quitRequested: (() -> Void)?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        openItem = NSMenuItem(title: "", action: #selector(open), keyEquivalent: "")
        settingsItem = NSMenuItem(title: "", action: #selector(settings), keyEquivalent: "")
        quitItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "")
        for menuItem in [openItem, settingsItem, quitItem] {
            menuItem.target = self
        }
        openItem.attributedTitle = nil
        menu.addItem(openItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        if let button = item.button {
            button.image = StatusBar.makeIcon()
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateTexts()
    }

    func updateTexts() {
        openItem.title = L("显示主窗口", "Show window")
        settingsItem.title = L("设置…", "Settings…")
        quitItem.title = L("退出轻译", "Quit QingYi Translator")
        item.button?.toolTip = L("轻译", "QingYi Translator")
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            openRequested?()
        }
    }

    @objc private func open() { openRequested?() }
    @objc private func settings() { settingsRequested?() }
    @objc private func quit() { quitRequested?() }

    /// A template image of the "译" glyph, so it follows the menu bar's light and dark looks.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            NSColor.black.setFill()
            path.fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
            let text = NSAttributedString(string: "译", attributes: attributes)
            let textSize = text.size()
            text.draw(in: NSRect(x: 0, y: (rect.height - textSize.height) / 2 - 0.5, width: rect.width, height: textSize.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}
