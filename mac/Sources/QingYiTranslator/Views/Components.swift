import AppKit
import QingYiCore
import SwiftUI

// MARK: - Buttons

/// A square icon button that highlights on hover, like the Windows IconButton style.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 32
    var fontSize: CGFloat = 14
    var isOn = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(isOn ? Palette.accentText : Palette.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 8).fill(isOn ? Palette.accentSoft : hovering ? Palette.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(danger ? Palette.danger : configuration.isPressed ? Palette.accentPressed : Palette.accent))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(Palette.textPrimary)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(height: compact ? 28 : 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? Palette.pressed : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.inputLine, lineWidth: 1))
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundColor(Palette.accentText)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 12).fill(configuration.isPressed ? Palette.pressed : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.inputLine, lineWidth: 1))
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Palette.accentText)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(Palette.accentSoft))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Form pieces

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Palette.textPrimary)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 6, leading: 18, bottom: 18, trailing: 18)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line, lineWidth: 1))
    }
}

struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundColor(Palette.textPrimary).padding(.top, 12).padding(.bottom, 6)
    }
}

struct HintText: View {
    let text: String
    var color: Color = Palette.textTertiary

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundColor(color).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
    }
}

/// The text-field look of the Windows version: rounded, thin border.
struct FormFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(Palette.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.inputLine, lineWidth: 1))
    }
}

extension View {
    func formField() -> some View { modifier(FormFieldStyle()) }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.system(size: 13)).foregroundColor(Palette.textPrimary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.top, 12)
    }
}

// MARK: - Text panes

/// An NSTextView for the source and translation panes: plain text, custom insets, streamed appends,
/// and ⌘↩ / Esc forwarded to the window.
struct PaneTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var fontSize: CGFloat = Fonts.pane
    var insets = NSSize(width: 20, height: 14)
    var focusRequest = 0
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = KeyAwareTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = Palette.textPrimaryNS
        textView.insertionPointColor = Palette.textPrimaryNS
        textView.selectedTextAttributes = [.backgroundColor: Palette.selectionNS]
        textView.textContainerInset = insets
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(isEditable ? L("原文", "Source text") : L("译文", "Translation"))
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KeyAwareTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.onCommandReturn = onCommandReturn
        textView.onEscape = onEscape
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }

        let current = textView.string
        if current != text {
            coordinator.isUpdating = true
            if !isEditable, text.hasPrefix(current), let storage = textView.textStorage {
                // Streaming: append only the new piece, keeping the scroll position stable.
                let delta = String(text.dropFirst(current.count))
                storage.append(NSAttributedString(string: delta, attributes: textView.typingAttributes))
                textView.scrollToEndOfDocument(nil)
            } else {
                let selection = textView.selectedRange()
                textView.string = text
                textView.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Palette.textPrimaryNS]
                if isEditable {
                    let location = min(selection.location, (text as NSString).length)
                    textView.setSelectedRange(NSRange(location: location, length: 0))
                } else {
                    textView.scroll(.zero)
                }
            }
            coordinator.isUpdating = false
        }

        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PaneTextView
        weak var textView: NSTextView?
        var isUpdating = false
        var lastFocusRequest = 0

        init(parent: PaneTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            if parent.text != value {
                parent.text = value
            }
        }
    }
}

final class KeyAwareTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command), let onCommandReturn {
            onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscape {
            onEscape()
        } else {
            super.cancelOperation(sender)
        }
    }

    // Pasting formatted text keeps only the plain text.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// A one-line text field that forwards Return and Tab-like navigation. Plain SwiftUI TextField suffices for most forms.
struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Palette.textTertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Palette.textPrimary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.inputLine, lineWidth: 1))
    }
}

// MARK: - Dialogs

enum Dialogs {
    /// A yes/no question; true when the primary button was clicked.
    static func confirm(_ window: NSWindow?, heading: String, message: String, confirmText: String, danger: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = heading
        alert.informativeText = message
        alert.alertStyle = danger ? .warning : .informational
        let primary = alert.addButton(withTitle: confirmText)
        if danger {
            primary.hasDestructiveAction = true
        }
        alert.addButton(withTitle: L("取消", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func inform(_ window: NSWindow?, heading: String, message: String) {
        let alert = NSAlert()
        alert.messageText = heading
        alert.informativeText = message
        alert.addButton(withTitle: L("确定", "OK"))
        alert.runModal()
    }
}
