using System.Windows;
using System.Windows.Threading;
using Translator.Core;
using Translator.Platform;
using Translator.Views;

namespace Translator;

public partial class App : Application
{
    private const string InstanceMutexName = @"Local\QingYiTranslator.Instance";
    private const string ShowEventName = @"Local\QingYiTranslator.Show";

    private Mutex? _instanceMutex;
    private EventWaitHandle? _showEvent;
    private RegisteredWaitHandle? _showWait;
    private TrayIcon? _tray;
    private DoubleCopyHook? _doubleCopy;
    private GlobalHotkey? _hotkey;
    private SettingsWindow? _settingsWindow;
    private bool _capturing;

    internal AppSettings Settings { get; private set; } = null!;
    internal MainWindow TranslatorWindow { get; private set; } = null!;
    internal bool IsExiting { get; private set; }
    internal HotkeyGesture? ActiveHotkey { get; private set; }
    internal string? ShortcutError { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instanceMutex = new Mutex(initiallyOwned: true, InstanceMutexName, out bool isFirstInstance);
        if (!isFirstInstance)
        {
            _instanceMutex.Dispose();
            _instanceMutex = null;
            SignalRunningInstance();
            Shutdown();
            return;
        }

        // Logoff/shutdown never goes through ExitApp: save now and let the window close for real.
        SessionEnding += (_, _) =>
        {
            IsExiting = true;
            PersistState();
        };
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Error("未处理的异常", args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Error("未观察到的任务异常", args.Exception);
            args.SetObserved();
        };

        Settings = AppSettings.Load();

        // A second launch signals this event instead of starting another copy.
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _showWait = ThreadPool.RegisterWaitForSingleObject(_showEvent,
            (_, _) => Dispatcher.InvokeAsync(ShowMainWindow), null, Timeout.Infinite, executeOnlyOnce: false);

        TranslatorWindow = new MainWindow(Settings);

        _tray = new TrayIcon();
        _tray.OpenRequested += ShowMainWindow;
        _tray.SettingsRequested += OpenSettings;
        _tray.ExitRequested += ExitApp;

        _doubleCopy = new DoubleCopyHook(sequence => Dispatcher.InvokeAsync(() => OnDoubleCopy(sequence)));
        _hotkey = new GlobalHotkey();
        _hotkey.Pressed += OnHotkeyPressed;
        ApplyShortcutSettings();
        AutoStart.Apply(Settings.StartWithWindows);

        bool startHidden = e.Args.Any(arg => string.Equals(arg, "--minimized", StringComparison.OrdinalIgnoreCase));
        if (!startHidden)
        {
            TranslatorWindow.Show();
            if (string.IsNullOrWhiteSpace(Settings.Active.ApiKey))
                Dispatcher.InvokeAsync(OpenSettings, DispatcherPriority.ApplicationIdle);
        }
    }

    internal void ShowMainWindow() => TranslatorWindow.BringToFront();

    internal void ApplyShortcutSettings()
    {
        ShortcutError = null;

        if (!Settings.DoubleCopyEnabled)
            _doubleCopy!.Stop();
        else if (!_doubleCopy!.Start())
            ShortcutError = "无法监听 Ctrl+C+C（键盘钩子安装失败）";

        _hotkey!.Unregister();
        ActiveHotkey = null;
        if (Settings.HotkeyEnabled)
        {
            if (!HotkeyGesture.TryParse(Settings.Hotkey, out var gesture))
                ShortcutError = "快捷键设置无效，请在设置中重新设置";
            else if (!_hotkey.Register(gesture))
                ShortcutError = $"快捷键 {gesture} 已被其他程序占用，请在设置中更换";
            else
                ActiveHotkey = gesture;
        }

        TranslatorWindow.RefreshSettingsDisplay();
    }

    internal void SuspendHotkey() => _hotkey?.Unregister();

    internal void ResumeHotkey()
    {
        if (ActiveHotkey is { } gesture)
            _hotkey?.Register(gesture);
    }

    internal bool IsHotkeyAvailable(HotkeyGesture gesture) => gesture == ActiveHotkey || _hotkey!.IsAvailable(gesture);

    internal void OpenSettings()
    {
        if (_settingsWindow is not null)
        {
            _settingsWindow.Activate();
            return;
        }

        // Always center on the main window (shown first if it was in the tray): WPF's CenterScreen can
        // size the dialog wrongly on a monitor whose DPI differs from the primary one.
        if (!TranslatorWindow.IsVisible)
            TranslatorWindow.BringToFront();
        var window = new SettingsWindow(Settings, this) { Owner = TranslatorWindow };

        _settingsWindow = window;
        bool saved;
        try
        {
            saved = window.ShowDialog() == true;
        }
        finally
        {
            _settingsWindow = null;
        }

        if (saved)
        {
            Settings.Save();
            AutoStart.Apply(Settings.StartWithWindows);
        }
        ApplyShortcutSettings(); // also re-registers a hotkey suspended while recording
        if (saved)
            TranslatorWindow.OnSettingsChanged();
    }

    internal void NotifyMinimizedToTray()
    {
        if (Settings.TrayTipShown)
            return;
        Settings.TrayTipShown = true;
        Settings.Save();
        _tray?.ShowTip("轻译仍在后台运行", "选中文字后按 Ctrl+C+C 即可翻译。右键托盘图标可以退出。");
    }

    internal void ExitApp()
    {
        IsExiting = true;
        PersistState();
        Shutdown();
    }

    /// <summary>Saves settings and window placement while the window still exists.</summary>
    private void PersistState()
    {
        TranslatorWindow.SaveWindowBounds();
        Settings.Save();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotkey?.Dispose();
        _doubleCopy?.Dispose();
        _tray?.Dispose();
        _showWait?.Unregister(null);
        _showEvent?.Dispose();
        if (_instanceMutex is not null)
        {
            _instanceMutex.ReleaseMutex();
            _instanceMutex.Dispose();
        }
        base.OnExit(e);
    }

    // ---------------- selection capture ----------------

    private async void OnDoubleCopy(uint sequenceBeforeFirstCopy)
    {
        // Copying inside our own window (e.g. the translation) should not re-trigger a translation.
        if (_capturing || WindowUtil.IsOwnWindowForeground())
            return;
        _capturing = true;
        try
        {
            string? text = await SelectionReader.ReadDoubleCopyAsync(sequenceBeforeFirstCopy);
            TranslatorWindow.ShowWithText(text);
        }
        catch (Exception ex)
        {
            Log.Error("读取剪贴板失败", ex);
        }
        finally
        {
            _capturing = false;
        }
    }

    private async void OnHotkeyPressed()
    {
        if (_capturing || ActiveHotkey is not { } gesture)
            return;
        if (TranslatorWindow.IsActive)
        {
            TranslatorWindow.HideOrMinimize(); // pressing the hotkey again hides the window
            return;
        }
        if (WindowUtil.IsOwnWindowForeground())
            return;

        _capturing = true;
        try
        {
            string? text = await SelectionReader.CaptureSelectionAsync(gesture.VirtualKey, Settings.RestoreClipboard);
            TranslatorWindow.ShowWithText(text);
        }
        catch (Exception ex)
        {
            Log.Error("获取选中文字失败", ex);
            TranslatorWindow.ShowWithText(null);
        }
        finally
        {
            _capturing = false;
        }
    }

    private void SignalRunningInstance()
    {
        try
        {
            using var showEvent = EventWaitHandle.OpenExisting(ShowEventName);
            showEvent.Set();
        }
        catch (Exception ex)
        {
            Log.Error("无法唤醒已在运行的轻译", ex);
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Error("界面线程异常", e.Exception);
        MessageBox.Show($"程序遇到错误：{e.Exception.Message}\n\n详细信息已写入日志：{Log.FilePath}",
            "轻译", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
