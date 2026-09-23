using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using Translator.Core;

namespace Translator.Platform;

/// <summary>Gets the text the user selected in another program, via the clipboard.</summary>
internal static class SelectionReader
{
    /// <summary>
    /// After Ctrl+C+C: returns what the user's own copy put on the clipboard,
    /// or null when nothing new was copied (e.g. nothing was selected).
    /// </summary>
    public static async Task<string?> ReadDoubleCopyAsync(uint sequenceBeforeFirstCopy)
    {
        if (!await WaitForClipboardChangeAsync(sequenceBeforeFirstCopy, timeoutMs: 600))
            return null;
        await Task.Delay(60); // let the second copy finish writing
        return await ClipboardUtil.TryGetTextAsync();
    }

    /// <summary>
    /// After the custom hotkey: presses Ctrl+C in the foreground program and returns the copied text,
    /// or null when nothing is selected. Optionally puts the previous clipboard content back.
    /// </summary>
    public static async Task<string?> CaptureSelectionAsync(uint hotkeyVirtualKey, bool restoreClipboard)
    {
        if (Native.IsKeyDown(Native.VK_MENU) || Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN))
            KeyboardSimulator.TapMaskKey();

        // Simulating Ctrl+C while the hotkey is still held would turn it into e.g. Ctrl+Alt+C,
        // so wait for the user to let go first.
        if (!await WaitForKeysReleasedAsync(hotkeyVirtualKey, timeoutMs: 1500))
        {
            Log.Info("快捷键按住时间过长，已跳过取词");
            return null;
        }

        ClipboardSnapshot? snapshot = restoreClipboard ? ClipboardSnapshot.TryCapture() : null;
        uint before = Native.GetClipboardSequenceNumber();
        if (!KeyboardSimulator.SendCtrlC())
            return null;
        if (!await WaitForClipboardChangeAsync(before, timeoutMs: 700))
            return null; // nothing was copied, so the clipboard is untouched

        await Task.Delay(40);
        string? text = await ClipboardUtil.TryGetTextAsync();
        snapshot?.Restore();
        return text;
    }

    private static async Task<bool> WaitForClipboardChangeAsync(uint before, int timeoutMs)
    {
        var watch = Stopwatch.StartNew();
        while (Native.GetClipboardSequenceNumber() == before)
        {
            if (watch.ElapsedMilliseconds > timeoutMs)
                return false;
            await Task.Delay(15);
        }
        return true;
    }

    private static async Task<bool> WaitForKeysReleasedAsync(uint hotkeyVirtualKey, int timeoutMs)
    {
        var watch = Stopwatch.StartNew();
        while (Native.IsKeyDown((int)hotkeyVirtualKey)
            || Native.IsKeyDown(Native.VK_SHIFT) || Native.IsKeyDown(Native.VK_CONTROL) || Native.IsKeyDown(Native.VK_MENU)
            || Native.IsKeyDown(Native.VK_LWIN) || Native.IsKeyDown(Native.VK_RWIN))
        {
            if (watch.ElapsedMilliseconds > timeoutMs)
                return false;
            await Task.Delay(10);
        }
        return true;
    }
}

internal static class ClipboardUtil
{
    public static async Task<string?> TryGetTextAsync()
    {
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                return Clipboard.ContainsText() ? Clipboard.GetText() : null;
            }
            catch (ExternalException)
            {
                await Task.Delay(30); // another program still has the clipboard open
            }
        }
        return null;
    }

    public static bool TrySetText(string text)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(text, copy: true);
                return true;
            }
            catch (ExternalException)
            {
                Thread.Sleep(30);
            }
        }
        return false;
    }
}

/// <summary>A copy of the clipboard's text, file-list and raw binary formats, so it can be put back after we borrow it.</summary>
internal sealed class ClipboardSnapshot
{
    private readonly List<(string Format, object Data)> _items = [];
    private bool _wasEmpty;

    public static ClipboardSnapshot? TryCapture()
    {
        try
        {
            var snapshot = new ClipboardSnapshot();
            IDataObject? data = Clipboard.GetDataObject();
            string[] formats = data?.GetFormats(autoConvert: false) ?? [];
            snapshot._wasEmpty = formats.Length == 0;
            bool hasUnicodeText = formats.Contains(DataFormats.UnicodeText);
            foreach (string format in formats)
            {
                // Windows regenerates the ANSI/OEM variants from the Unicode text; writing them back
                // ourselves could garble Chinese text for programs that read the ANSI format.
                if (hasUnicodeText && (format == DataFormats.Text || format == DataFormats.OemText))
                    continue;
                try
                {
                    object? value = data!.GetData(format, autoConvert: false);
                    // Only keep types that can be written back safely; skip GDI handles and serialized objects.
                    switch (value)
                    {
                        case string or string[]:
                            snapshot._items.Add((format, value));
                            break;
                        case MemoryStream stream:
                            snapshot._items.Add((format, new MemoryStream(stream.ToArray())));
                            break;
                    }
                }
                catch (Exception)
                {
                    // Some formats (e.g. delayed-rendered or OLE storage) cannot be read; skip them.
                }
            }
            return snapshot;
        }
        catch (Exception ex)
        {
            Log.Error("备份剪贴板失败", ex);
            return null;
        }
    }

    public void Restore()
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (_wasEmpty)
                {
                    Clipboard.Clear();
                    return;
                }
                if (_items.Count == 0)
                    return;
                var data = new DataObject();
                foreach (var (format, value) in _items)
                {
                    if (value is MemoryStream stream)
                        stream.Position = 0;
                    data.SetData(format, value, autoConvert: false);
                }
                Clipboard.SetDataObject(data, copy: true);
                return;
            }
            catch (ExternalException)
            {
                Thread.Sleep(30);
            }
            catch (Exception ex)
            {
                Log.Error("恢复剪贴板失败", ex);
                return;
            }
        }
    }
}
