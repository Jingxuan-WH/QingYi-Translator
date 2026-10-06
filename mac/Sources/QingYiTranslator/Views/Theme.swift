import AppKit
import QingYiCore
import SwiftUI

/// The palette of the Windows version, resolved per appearance so SwiftUI switches it with dark mode.
enum Palette {
    static let accent = dynamic(0x4F5BD5, 0x5A66E0)
    static let accentHover = dynamic(0x4450C6, 0x6772E6)
    static let accentPressed = dynamic(0x3943AC, 0x4C57CC)
    static let accentText = dynamic(0x4F5BD5, 0x9AA3F5)
    static let accentSoft = dynamic(0xEDEFFC, 0x2B3056)
    static let window = dynamic(0xF3F5F9, 0x17191F)
    static let surface = dynamic(0xFFFFFF, 0x20232B)
    static let output = dynamic(0xF7F8FB, 0x1C1F26)
    static let line = dynamic(0xE2E6ED, 0x2F333D)
    static let inputLine = dynamic(0xD3D9E2, 0x3A3F4B)
    static let inputHoverLine = dynamic(0xB9C1CD, 0x4B5160)
    static let hover = dynamic(0xEEF1F6, 0x2A2E38)
    static let pressed = dynamic(0xE2E6EE, 0x333845)
    static let textPrimary = dynamic(0x1E2430, 0xE6E8EE)
    static let textSecondary = dynamic(0x5F6878, 0xA7ADBA)
    static let textTertiary = dynamic(0x98A0AE, 0x767D8C)
    static let error = dynamic(0xD13B3B, 0xF06A6A)
    static let errorText = dynamic(0x9A2B2B, 0xF4A7A7)
    static let errorSoft = dynamic(0xFCEFEF, 0x3A2327)
    static let danger = dynamic(0xD13B3B, 0xC94545)
    static let warning = dynamic(0xD99A00, 0xE0A82E)
    static let success = dynamic(0x1E9E5A, 0x3CC47C)
    static let backdrop = dynamic(0x1E2430, 0x000000, lightAlpha: 0.16, darkAlpha: 0.45)
    static let shadow = dynamic(0x1E2430, 0x000000, lightAlpha: 0.08, darkAlpha: 0.5)

    static let textPrimaryNS = dynamicNS(0x1E2430, 0xE6E8EE)
    static let selectionNS = dynamicNS(0x4F5BD5, 0x7C87F2, lightAlpha: 0.25, darkAlpha: 0.35)

    static func dynamic(_ light: Int, _ dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: dynamicNS(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(_ light: Int, _ dark: Int, lightAlpha: Double = 1, darkAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? nsColor(dark, darkAlpha) : nsColor(light, lightAlpha)
        }
    }

    private static func nsColor(_ hex: Int, _ alpha: Double) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Switches the whole app between light, dark and "follow the system".
enum ThemeManager {
    static func apply(_ setting: String?) {
        switch setting {
        case AppSettings.themeLight: NSApp.appearance = NSAppearance(named: .aqua)
        case AppSettings.themeDark: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

enum Fonts {
    static let pane: CGFloat = 17
    static let ui: CGFloat = 13
}
