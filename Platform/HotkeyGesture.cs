using System.Windows.Input;

namespace Translator.Platform;

/// <summary>A global hotkey such as "Alt+Q". Stored in settings as its display string.</summary>
internal readonly record struct HotkeyGesture(ModifierKeys Modifiers, Key Key)
{
    private static readonly Key[] SymbolKeys =
    [
        Key.Space, Key.Enter, Key.Escape, Key.OemTilde, Key.OemMinus, Key.OemPlus, Key.OemComma, Key.OemPeriod,
        Key.OemQuestion, Key.OemSemicolon, Key.OemQuotes, Key.OemOpenBrackets, Key.OemCloseBrackets, Key.OemPipe,
    ];

    // ModifierKeys uses the same bit values as RegisterHotKey's MOD_ALT/MOD_CONTROL/MOD_SHIFT/MOD_WIN.
    public uint NativeModifiers => (uint)Modifiers;

    public uint VirtualKey => (uint)KeyInterop.VirtualKeyFromKey(Key);

    /// <summary>Must include Ctrl, Alt or Win (function keys may stand alone), so it never steals ordinary typing.</summary>
    public bool IsValid =>
        Key != Key.None && !IsModifierKey(Key)
        && ((Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) != 0 || Key is >= Key.F1 and <= Key.F24);

    public static bool IsModifierKey(Key key) => key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
        or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin or Key.System;

    public static string FormatModifiers(ModifierKeys modifiers)
    {
        var parts = new List<string>(4);
        if (modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        return string.Join("+", parts);
    }

    public override string ToString()
    {
        string modifiers = FormatModifiers(Modifiers);
        return modifiers.Length == 0 ? KeyName(Key) : $"{modifiers}+{KeyName(Key)}";
    }

    public static bool TryParse(string? text, out HotkeyGesture gesture)
    {
        gesture = default;
        if (string.IsNullOrWhiteSpace(text))
            return false;

        var modifiers = ModifierKeys.None;
        var key = Key.None;
        foreach (string part in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl" or "control": modifiers |= ModifierKeys.Control; break;
                case "alt": modifiers |= ModifierKeys.Alt; break;
                case "shift": modifiers |= ModifierKeys.Shift; break;
                case "win" or "windows": modifiers |= ModifierKeys.Windows; break;
                default:
                    if (key != Key.None || !TryParseKey(part, out key))
                        return false;
                    break;
            }
        }

        gesture = new HotkeyGesture(modifiers, key);
        return gesture.IsValid;
    }

    private static string KeyName(Key key) => key switch
    {
        >= Key.D0 and <= Key.D9 => ((char)('0' + (key - Key.D0))).ToString(),
        >= Key.NumPad0 and <= Key.NumPad9 => $"Num{key - Key.NumPad0}",
        Key.Space => "Space",
        Key.Enter => "Enter",
        Key.Escape => "Esc",
        Key.OemTilde => "`",
        Key.OemMinus => "-",
        Key.OemPlus => "=",
        Key.OemComma => ",",
        Key.OemPeriod => ".",
        Key.OemQuestion => "/",
        Key.OemSemicolon => ";",
        Key.OemQuotes => "'",
        Key.OemOpenBrackets => "[",
        Key.OemCloseBrackets => "]",
        Key.OemPipe => "\\",
        _ => key.ToString(),
    };

    private static bool TryParseKey(string name, out Key key)
    {
        if (name.Length == 1 && char.IsAsciiDigit(name[0]))
        {
            key = Key.D0 + (name[0] - '0');
            return true;
        }
        foreach (Key symbol in SymbolKeys)
        {
            if (string.Equals(KeyName(symbol), name, StringComparison.OrdinalIgnoreCase))
            {
                key = symbol;
                return true;
            }
        }
        // Reject purely numeric names: Enum.TryParse would accept them as raw enum values.
        return Enum.TryParse(name, ignoreCase: true, out key) && key != Key.None && !name.All(char.IsAsciiDigit);
    }
}
