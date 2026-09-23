using System.Runtime.InteropServices;

namespace Translator.Platform;

internal static class KeyboardSimulator
{
    /// <summary>Stamped on injected input so our own keyboard hook can ignore it.</summary>
    public static readonly UIntPtr InjectionTag = new(0x51595452);

    // An unassigned virtual key. Tapping it while Alt/Win is held stops the later
    // Alt/Win release from opening the window menu or the Start menu.
    private const int MaskKey = 0xE8;

    public static void TapMaskKey() => Send(Key(MaskKey, up: false), Key(MaskKey, up: true));

    public static bool SendCtrlC() => Send(
        Key(Native.VK_CONTROL, up: false),
        Key(Native.VK_C, up: false),
        Key(Native.VK_C, up: true),
        Key(Native.VK_CONTROL, up: true));

    private static bool Send(params Native.INPUT[] inputs) =>
        Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>()) == inputs.Length;

    private static Native.INPUT Key(int vk, bool up) => new()
    {
        type = Native.INPUT_KEYBOARD,
        U = new Native.InputUnion
        {
            ki = new Native.KEYBDINPUT
            {
                wVk = (ushort)vk,
                wScan = (ushort)Native.MapVirtualKey((uint)vk, 0),
                dwFlags = up ? Native.KEYEVENTF_KEYUP : 0,
                dwExtraInfo = InjectionTag,
            },
        },
    };
}
