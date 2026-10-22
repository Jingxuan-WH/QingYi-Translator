using Translator.Core;
using Translator.Platform;
using Translator.Views;

namespace Translator;

/// <summary>Live transcription: its window and its optional global hotkey.</summary>
public partial class App
{
    private LiveWindow? _liveWindow;
    private GlobalHotkey? _liveHotkey;

    internal HotkeyGesture? ActiveLiveHotkey { get; private set; }

    internal void OpenLiveWindow()
    {
        _liveWindow ??= new LiveWindow(Settings, Glossary);
        _liveWindow.BringToFront();
    }

    /// <summary>The live hotkey: opens the window and starts listening, or stops when already listening.</summary>
    private void ToggleLiveTranscription()
    {
        OpenLiveWindow();
        _liveWindow!.ToggleRunning();
    }

    /// <summary>Registers the live hotkey from the settings; returns why it couldn't be, if it couldn't.</summary>
    private LocText? ApplyLiveHotkey()
    {
        if (_liveHotkey is null)
        {
            _liveHotkey = new GlobalHotkey();
            _liveHotkey.Pressed += ToggleLiveTranscription;
        }
        _liveHotkey.Unregister();
        ActiveLiveHotkey = null;
        if (!Settings.Live.HotkeyEnabled)
            return null;
        if (!HotkeyGesture.TryParse(Settings.Live.Hotkey, out var gesture))
            return new LocText("实时转录的快捷键设置无效，请在设置中重新设置", "The live transcription hotkey is invalid. Please set it again in Settings");
        if (!_liveHotkey.Register(gesture))
            return new LocText($"实时转录的快捷键 {gesture} 已被占用，请在设置中更换", $"The live transcription hotkey {gesture} is taken. Please pick another one in Settings");
        ActiveLiveHotkey = gesture;
        return null;
    }

    internal void SuspendLiveHotkey() => _liveHotkey?.Unregister();

    internal void ResumeLiveHotkey()
    {
        if (ActiveLiveHotkey is { } gesture)
            _liveHotkey?.Register(gesture);
    }

    internal bool IsLiveHotkeyAvailable(HotkeyGesture gesture) => gesture == ActiveLiveHotkey || _liveHotkey?.IsAvailable(gesture) != false;
}
