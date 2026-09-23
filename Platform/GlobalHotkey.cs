using System.Windows.Interop;

namespace Translator.Platform;

/// <summary>A system-wide hotkey registered with RegisterHotKey on a hidden message-only window.</summary>
internal sealed class GlobalHotkey : IDisposable
{
    private const int HotkeyId = 0x5159;
    private const int ProbeId = 0x515A;
    private static readonly IntPtr HwndMessage = new(-3);

    private readonly HwndSource _sink;
    private bool _registered;

    public event Action? Pressed;

    public GlobalHotkey()
    {
        _sink = new HwndSource(new HwndSourceParameters("QingYiHotkeySink") { ParentWindow = HwndMessage, WindowStyle = 0 });
        _sink.AddHook(WndProc);
    }

    public bool Register(HotkeyGesture gesture)
    {
        Unregister();
        _registered = Native.RegisterHotKey(_sink.Handle, HotkeyId, gesture.NativeModifiers | Native.MOD_NOREPEAT, gesture.VirtualKey);
        return _registered;
    }

    public void Unregister()
    {
        if (!_registered)
            return;
        Native.UnregisterHotKey(_sink.Handle, HotkeyId);
        _registered = false;
    }

    /// <summary>True when no other program currently owns <paramref name="gesture"/>.</summary>
    public bool IsAvailable(HotkeyGesture gesture)
    {
        if (!Native.RegisterHotKey(_sink.Handle, ProbeId, gesture.NativeModifiers | Native.MOD_NOREPEAT, gesture.VirtualKey))
            return false;
        Native.UnregisterHotKey(_sink.Handle, ProbeId);
        return true;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && wParam.ToInt32() == HotkeyId)
        {
            handled = true;
            Pressed?.Invoke();
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Unregister();
        _sink.RemoveHook(WndProc);
        _sink.Dispose();
    }
}
