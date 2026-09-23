using System.Runtime.InteropServices;
using Translator.Core;

namespace Translator.Platform;

/// <summary>
/// Detects DeepL-style "Ctrl+C+C": two Ctrl+C presses in quick succession.
/// The user's own Ctrl+C does the copying, so nothing is simulated. The low-level hook
/// runs on a dedicated thread so a busy UI thread can never delay system-wide typing.
/// </summary>
internal sealed class DoubleCopyHook : IDisposable
{
    private const int MaxIntervalMs = 500;

    // Called on the hook thread with the clipboard sequence number captured before the first Ctrl+C.
    private readonly Action<uint> _onTriggered;
    private Native.LowLevelKeyboardProc? _proc;
    private Thread? _thread;
    private uint _threadId;
    private IntPtr _hook;

    // Only touched on the hook thread.
    private bool _cIsDown;
    private long _firstCopyTick;
    private uint _sequenceBeforeFirstCopy;

    public DoubleCopyHook(Action<uint> onTriggered) => _onTriggered = onTriggered;

    public bool IsRunning => _thread is not null;

    public bool Start()
    {
        if (_thread is not null)
            return true;

        using var ready = new ManualResetEventSlim();
        var thread = new Thread(() => Run(ready)) { IsBackground = true, Name = "Ctrl+C+C hook" };
        thread.Start();
        ready.Wait(TimeSpan.FromSeconds(3));
        if (_hook == IntPtr.Zero)
        {
            thread.Join(500);
            return false;
        }
        _thread = thread;
        return true;
    }

    public void Stop()
    {
        if (_thread is null)
            return;
        Native.PostThreadMessage(_threadId, Native.WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
        _thread.Join(1000);
        _thread = null;
    }

    public void Dispose() => Stop();

    private void Run(ManualResetEventSlim ready)
    {
        _threadId = Native.GetCurrentThreadId();
        _proc = HookProc;
        _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
        int error = Marshal.GetLastWin32Error();
        ready.Set();
        if (_hook == IntPtr.Zero)
        {
            Log.Error($"安装键盘钩子失败，错误码 {error}");
            return;
        }

        while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessage(ref msg);
        }

        Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    private IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            try
            {
                OnKey((int)wParam, Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam));
            }
            catch (Exception ex)
            {
                Log.Error("键盘钩子处理异常", ex);
            }
        }
        return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void OnKey(int message, Native.KBDLLHOOKSTRUCT key)
    {
        // Ignore the Ctrl+C that we inject ourselves for the other hotkey.
        if (key.dwExtraInfo == KeyboardSimulator.InjectionTag)
            return;

        bool down = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
        bool up = message is Native.WM_KEYUP or Native.WM_SYSKEYUP;

        if (key.vkCode == Native.VK_C)
        {
            if (up)
            {
                _cIsDown = false;
                return;
            }
            if (!down || _cIsDown)
                return; // auto-repeat while C is held
            _cIsDown = true;

            bool ctrlOnly = Native.IsKeyDown(Native.VK_CONTROL)
                && !Native.IsKeyDown(Native.VK_MENU)
                && !Native.IsKeyDown(Native.VK_LWIN)
                && !Native.IsKeyDown(Native.VK_RWIN);
            if (!ctrlOnly)
            {
                _firstCopyTick = 0;
                return;
            }

            long now = Environment.TickCount64;
            if (_firstCopyTick != 0 && now - _firstCopyTick <= MaxIntervalMs)
            {
                _firstCopyTick = 0;
                _onTriggered(_sequenceBeforeFirstCopy);
            }
            else
            {
                _firstCopyTick = now;
                _sequenceBeforeFirstCopy = Native.GetClipboardSequenceNumber();
            }
        }
        else if (down && !IsModifier(key.vkCode))
        {
            _firstCopyTick = 0; // any other key breaks the sequence
        }
    }

    private static bool IsModifier(uint vk) => vk is Native.VK_SHIFT or Native.VK_CONTROL or Native.VK_MENU
        or Native.VK_LSHIFT or Native.VK_RSHIFT or Native.VK_LCONTROL or Native.VK_RCONTROL
        or Native.VK_LMENU or Native.VK_RMENU or Native.VK_LWIN or Native.VK_RWIN;
}
