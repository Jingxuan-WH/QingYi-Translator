import Foundation

public struct HotkeyModifiers: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1)
    public static let option = HotkeyModifiers(rawValue: 2)
    public static let control = HotkeyModifiers(rawValue: 4)
    public static let shift = HotkeyModifiers(rawValue: 8)
}

/// A global hotkey such as ⌥Q. Stored in settings as "Option+Q" so the file stays readable.
public struct HotkeyGesture: Equatable, CustomStringConvertible {
    public var modifiers: HotkeyModifiers
    /// macOS virtual key code (kVK_*).
    public var keyCode: UInt32

    public init(modifiers: HotkeyModifiers, keyCode: UInt32) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// Must include ⌘, ⌥ or ⌃ (function keys may stand alone), so it never steals ordinary typing.
    public var isValid: Bool {
        guard keyName != nil else { return false }
        return !modifiers.intersection([.command, .option, .control]).isEmpty || isFunctionKey
    }

    public var isFunctionKey: Bool { keyName?.range(of: #"^F\d{1,2}$"#, options: .regularExpression) != nil }

    public var keyName: String? { HotkeyGesture.keyNames[keyCode] }

    /// Carbon modifier bits for RegisterEventHotKey.
    public var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= 0x100 }   // cmdKey
        if modifiers.contains(.shift) { value |= 0x200 }     // shiftKey
        if modifiers.contains(.option) { value |= 0x800 }    // optionKey
        if modifiers.contains(.control) { value |= 0x1000 }  // controlKey
        return value
    }

    /// Mac-style display, e.g. "⌥Q" or "⌃⇧F5".
    public var description: String { HotkeyGesture.symbols(for: modifiers) + (HotkeyGesture.displayNames[keyCode] ?? keyName ?? "?") }

    /// The form saved in settings, e.g. "Option+Q".
    public var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(keyName ?? "?")
        return parts.joined(separator: "+")
    }

    public static func symbols(for modifiers: HotkeyModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// Reads "Option+Q", "Cmd+Shift+T", "⌥Q" and the like. Nil when the text is not a valid hotkey.
    public static func parse(_ text: String?) -> HotkeyGesture? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var modifiers: HotkeyModifiers = []
        var key: UInt32?
        var tokens: [String] = []
        if text.contains("+") {
            tokens = text.split(separator: "+", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            // "Option++" means the key is "+"; keep it simple: a trailing empty token stands for "+".
            if text.hasSuffix("++") { tokens.append("+") }
        } else {
            // Symbol form such as "⌥⇧Q".
            var rest = text
            while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
                tokens.append(String(first))
                rest.removeFirst()
            }
            if !rest.isEmpty { tokens.append(rest) }
        }
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command", "⌘", "win", "windows": modifiers.insert(.command)
            case "option", "opt", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "shift", "⇧": modifiers.insert(.shift)
            default:
                guard key == nil, let code = keyCode(forName: token) else { return nil }
                key = code
            }
        }
        guard let keyCode = key else { return nil }
        let gesture = HotkeyGesture(modifiers: modifiers, keyCode: keyCode)
        return gesture.isValid ? gesture : nil
    }

    public static func keyCode(forName name: String) -> UInt32? {
        let wanted = name.lowercased()
        if let match = keyNames.first(where: { $0.value.lowercased() == wanted }) {
            return match.key
        }
        switch wanted {
        case "esc", "escape": return 53
        case "enter", "return": return 36
        case "backspace", "delete": return 51
        case "spacebar": return 49
        default: return nil
        }
    }

    public static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
            14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
            48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 115: "Home", 116: "PageUp", 117: "ForwardDelete",
            119: "End", 121: "PageDown", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
        ]
        let functionKeys: [UInt32: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12, 105: 13,
            107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
        ]
        for (code, number) in functionKeys { names[code] = "F\(number)" }
        return names
    }()

    private static let displayNames: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
