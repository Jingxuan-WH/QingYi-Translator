using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Translator.Core;

namespace Translator.Platform;

internal static class WindowUtil
{
    /// <summary>
    /// Colors the native title bar (Windows 11) so it blends with the window content, optionally hiding the
    /// caption text and icon. <paramref name="dark"/> also switches the caption buttons to their dark look (Windows 10 too).
    /// </summary>
    public static void StyleCaption(Window window, Color caption, Color text, bool dark, bool hideTitle)
    {
        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
            return;

        int useDark = dark ? 1 : 0;
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDark, sizeof(int));
        int captionRef = ToColorRef(caption);
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_CAPTION_COLOR, ref captionRef, sizeof(int));
        int textRef = ToColorRef(text);
        Native.DwmSetWindowAttribute(hwnd, Native.DWMWA_TEXT_COLOR, ref textRef, sizeof(int));

        if (hideTitle)
        {
            var options = new Native.WTA_OPTIONS
            {
                dwFlags = Native.WTNCA_NODRAWCAPTION | Native.WTNCA_NODRAWICON,
                dwMask = Native.WTNCA_NODRAWCAPTION | Native.WTNCA_NODRAWICON,
            };
            Native.SetWindowThemeAttribute(hwnd, Native.WTA_NONCLIENT, ref options, (uint)Marshal.SizeOf<Native.WTA_OPTIONS>());
        }
    }

    private static int ToColorRef(Color color) => color.R | (color.G << 8) | (color.B << 16);

    /// <summary>Shows, restores and activates a window even when another program is in the foreground.</summary>
    public static void ForceForeground(Window window)
    {
        if (!window.IsVisible)
            window.Show();

        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        if (Native.IsIconic(hwnd))
            Native.ShowWindow(hwnd, Native.SW_RESTORE);

        // Windows only lets the foreground thread hand out focus, so briefly join its input queue.
        uint foregroundThread = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out _);
        uint currentThread = Native.GetCurrentThreadId();
        bool attached = foregroundThread != 0 && foregroundThread != currentThread
            && Native.AttachThreadInput(currentThread, foregroundThread, true);
        try
        {
            Native.BringWindowToTop(hwnd);
            Native.SetForegroundWindow(hwnd);
        }
        finally
        {
            if (attached)
                Native.AttachThreadInput(currentThread, foregroundThread, false);
        }
        window.Activate();
    }

    /// <summary>
    /// Reads the window's normal (restored) bounds in physical pixels. Unlike WPF's Left/Top, which are
    /// relative to the DPI of whatever monitor the window is on, these round-trip across mixed-DPI monitors.
    /// </summary>
    public static WindowBounds? GetPlacement(Window window)
    {
        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        var placement = new Native.WINDOWPLACEMENT { length = Marshal.SizeOf<Native.WINDOWPLACEMENT>() };
        if (hwnd == IntPtr.Zero || !Native.GetWindowPlacement(hwnd, ref placement))
            return null;

        var rect = placement.rcNormalPosition;
        bool maximized = placement.showCmd == Native.SW_SHOWMAXIMIZED
            || (placement.showCmd == Native.SW_SHOWMINIMIZED && (placement.flags & Native.WPF_RESTORETOMAXIMIZED) != 0);
        return new WindowBounds
        {
            Left = rect.Left,
            Top = rect.Top,
            Width = rect.Right - rect.Left,
            Height = rect.Bottom - rect.Top,
            Maximized = maximized,
        };
    }

    /// <summary>Puts the window back where <see cref="GetPlacement"/> found it, if that spot is still on a monitor.</summary>
    public static bool TryRestorePlacement(Window window, WindowBounds saved)
    {
        IntPtr hwnd = new WindowInteropHelper(window).Handle;
        var rect = new Native.RECT
        {
            Left = (int)saved.Left,
            Top = (int)saved.Top,
            Right = (int)(saved.Left + saved.Width),
            Bottom = (int)(saved.Top + saved.Height),
        };
        if (hwnd == IntPtr.Zero || saved.Width < 200 || saved.Height < 150
            || Native.MonitorFromRect(ref rect, Native.MONITOR_DEFAULTTONULL) == IntPtr.Zero)
            return false;

        var placement = new Native.WINDOWPLACEMENT
        {
            length = Marshal.SizeOf<Native.WINDOWPLACEMENT>(),
            showCmd = saved.Maximized ? Native.SW_SHOWMAXIMIZED : Native.SW_SHOWNORMAL,
            rcNormalPosition = rect,
        };
        // Moving onto a monitor with a different DPI rescales the window; the second call restores the exact size.
        Native.SetWindowPlacement(hwnd, ref placement);
        Native.SetWindowPlacement(hwnd, ref placement);
        return true;
    }

    public static bool IsOwnWindowForeground()
    {
        IntPtr foreground = Native.GetForegroundWindow();
        if (foreground == IntPtr.Zero)
            return false;
        Native.GetWindowThreadProcessId(foreground, out uint processId);
        return processId == (uint)Environment.ProcessId;
    }
}
