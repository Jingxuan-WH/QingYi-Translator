using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Translator.Core;
using Translator.Platform;
using Translator.Views;

namespace Translator;

public partial class App : Application
{
    // A copy started with its own TRANSLATOR_DATA_DIR (e.g. for testing) runs independently of the normal one.
    private static readonly string InstanceSuffix = AppSettings.UsesCustomDataDirectory
        ? "." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppSettings.DataDirectory.ToUpperInvariant())))[..12]
        : "";
    private static readonly string InstanceMutexName = @"Local\QingYiTranslator.Instance" + InstanceSuffix;
    private static readonly string ShowEventName = @"Local\QingYiTranslator.Show" + InstanceSuffix;
    private static readonly TimeSpan UpdateCheckInterval = TimeSpan.FromHours(12);

    private Mutex? _instanceMutex;
    private EventWaitHandle? _showEvent;
    private RegisteredWaitHandle? _showWait;
    private TrayIcon? _tray;
    private DoubleCopyHook? _doubleCopy;
    private GlobalHotkey? _hotkey;
    private SettingsWindow? _settingsWindow;
    private GlossaryWindow? _glossaryWindow;
    private UpdateWindow? _updateWindow;
    private DispatcherTimer? _updateTimer;
    private bool _capturing;
    private bool _checkingForUpdates;

    internal AppSettings Settings { get; private set; } = null!;
    internal Glossary Glossary { get; private set; } = null!;
    internal MainWindow TranslatorWindow { get; private set; } = null!;
    internal bool IsExiting { get; private set; }
    internal HotkeyGesture? ActiveHotkey { get; private set; }
    internal LocText? ShortcutError { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // After an update the new copy is started while the old one is still closing; let it finish first.
        if (ArgumentValue(e.Args, "--wait-pid") is { } pidText && int.TryParse(pidText, out int oldProcessId))
            WaitForExit(oldProcessId);

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
        Loc.Apply(Settings.UiLanguage);
        ThemeManager.Apply(Settings.Theme);
        SelfUpdater.CleanUpInBackground();

        // A second launch signals this event instead of starting another copy.
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _showWait = ThreadPool.RegisterWaitForSingleObject(_showEvent,
            (_, _) => Dispatcher.InvokeAsync(ShowMainWindow), null, Timeout.Infinite, executeOnlyOnce: false);

        Glossary = Glossary.Load();
        TranslatorWindow = new MainWindow(Settings, TranslationHistory.Load(), Glossary);

        _tray = new TrayIcon();
        _tray.ApplyTheme(ThemeManager.IsDark);
        _tray.OpenRequested += ShowMainWindow;
        _tray.SettingsRequested += OpenSettings;
        _tray.ExitRequested += ExitApp;
        Loc.Changed += () => _tray?.UpdateTexts();
        ThemeManager.Changed += () => _tray?.ApplyTheme(ThemeManager.IsDark);

        _doubleCopy = new DoubleCopyHook(sequence => Dispatcher.InvokeAsync(() => OnDoubleCopy(sequence)));
        _hotkey = new GlobalHotkey();
        _hotkey.Pressed += OnHotkeyPressed;
        ApplyShortcutSettings();
        ApplyAutoStart();

        if (e.Args.Contains("--updated", StringComparer.OrdinalIgnoreCase))
        {
            string version = UpdateService.CurrentVersionText;
            Log.Info($"已更新到 {version}");
            TranslatorWindow.ShowNotice(() => Loc.T($"轻译已更新到 {version}", $"Updated to version {version}"));
        }

        bool startHidden = e.Args.Contains("--minimized", StringComparer.OrdinalIgnoreCase);
        if (!startHidden)
        {
            TranslatorWindow.Show();
            if (Settings.ActivePreset.RequiresApiKey && string.IsNullOrWhiteSpace(Settings.Active.ApiKey))
                Dispatcher.InvokeAsync(OpenSettings, DispatcherPriority.ApplicationIdle);
        }
        StartUpdateChecks();
    }

    internal void ShowMainWindow() => TranslatorWindow.BringToFront();

    internal void ApplyShortcutSettings()
    {
        ShortcutError = null;

        if (!Settings.DoubleCopyEnabled)
            _doubleCopy!.Stop();
        else if (!_doubleCopy!.Start())
            ShortcutError = new LocText("无法监听 Ctrl+C+C（键盘钩子安装失败）", "Can’t listen for Ctrl+C+C (the keyboard hook failed)");

        _hotkey!.Unregister();
        ActiveHotkey = null;
        if (Settings.HotkeyEnabled)
        {
            if (!HotkeyGesture.TryParse(Settings.Hotkey, out var gesture))
                ShortcutError = new LocText("快捷键设置无效，请在设置中重新设置", "The hotkey setting is invalid. Please set it again in Settings");
            else if (!_hotkey.Register(gesture))
                ShortcutError = new LocText($"快捷键 {gesture} 已被其他程序占用，请在设置中更换",
                    $"{gesture} is already used by another program. Please pick another hotkey in Settings");
            else
                ActiveHotkey = gesture;
        }

        TranslatorWindow.RefreshSettingsDisplay();
    }

    // A copy with its own data folder (e.g. a test copy) leaves the Windows startup entry to the normal installation.
    private void ApplyAutoStart()
    {
        if (!AppSettings.UsesCustomDataDirectory)
            AutoStart.Apply(Settings.StartWithWindows);
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
        if (IsExiting)
            return; // e.g. an update was installed from the dialog

        if (saved)
        {
            Settings.Save();
            ApplyAutoStart();
        }
        ApplyShortcutSettings(); // also re-registers a hotkey suspended while recording
        if (saved)
            TranslatorWindow.OnSettingsChanged();
    }

    /// <summary>Edits the glossary; it is saved on its own, independent of the settings dialog.</summary>
    internal void OpenGlossary(Window? owner)
    {
        if (_glossaryWindow is not null)
        {
            _glossaryWindow.Activate();
            return;
        }
        if (owner is null || !owner.IsVisible)
        {
            TranslatorWindow.BringToFront();
            owner = TranslatorWindow;
        }

        var window = new GlossaryWindow(Glossary, Settings.GlossaryEnabled) { Owner = owner };
        _glossaryWindow = window;
        bool saved;
        try
        {
            saved = window.ShowDialog() == true;
        }
        finally
        {
            _glossaryWindow = null;
        }
        if (!saved || IsExiting)
            return;

        if (!Glossary.Replace(window.Entries))
            MessageDialog.Inform(owner, Loc.T("术语表保存失败", "Couldn’t save the glossary"),
                Loc.T($"详细信息已写入日志：{Log.FilePath}", $"Details were written to the log: {Log.FilePath}"));
        Settings.GlossaryEnabled = window.GlossaryEnabled;
        Settings.Save();
        TranslatorWindow.OnSettingsChanged();
    }

    internal void NotifyMinimizedToTray()
    {
        if (Settings.TrayTipShown)
            return;
        Settings.TrayTipShown = true;
        Settings.Save();
        _tray?.ShowTip(Loc.T("轻译仍在后台运行", "QingYi Translator is still running"),
            Loc.T("选中文字后按 Ctrl+C+C 即可翻译。右键托盘图标可以退出。", "Select text and press Ctrl+C+C to translate. Right-click the tray icon to exit."));
    }

    internal void ExitApp()
    {
        IsExiting = true;
        PersistState();
        Shutdown();
    }

    internal static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex)
        {
            Log.Error("无法打开浏览器", ex);
        }
    }

    /// <summary>Saves settings and window placement while the window still exists.</summary>
    private void PersistState()
    {
        TranslatorWindow.SaveWindowBounds();
        Settings.Save();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _updateTimer?.Stop();
        ThemeManager.Stop();
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

    // ---------------- updates ----------------

    private void StartUpdateChecks()
    {
        // The first check waits until startup has settled; later ones run every 12 hours while the app stays open.
        var first = new DispatcherTimer { Interval = TimeSpan.FromSeconds(8) };
        first.Tick += (_, _) =>
        {
            first.Stop();
            _ = CheckForUpdatesInBackgroundAsync(startup: true);
        };
        first.Start();

        _updateTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(30) };
        _updateTimer.Tick += (_, _) => _ = CheckForUpdatesInBackgroundAsync(startup: false);
        _updateTimer.Start();
    }

    private async Task CheckForUpdatesInBackgroundAsync(bool startup)
    {
        if (!Settings.AutoCheckUpdates || IsExiting || _checkingForUpdates)
            return;
        if (!startup && Settings.LastUpdateCheck is { } last && DateTime.Now - last < UpdateCheckInterval)
            return;
        try
        {
            await CheckForUpdatesAsync(userInitiated: false);
        }
        catch (UpdateException ex)
        {
            Log.Info($"自动检查更新失败：{ex.Message}");
        }
        catch (Exception ex)
        {
            Log.Error("自动检查更新失败", ex);
        }
    }

    /// <summary>
    /// Asks GitHub for the latest release and returns it when it is newer than this version. Automatic checks
    /// ignore a version the user chose to skip. Throws <see cref="UpdateException"/> when the check fails.
    /// </summary>
    internal async Task<ReleaseInfo?> CheckForUpdatesAsync(bool userInitiated)
    {
        _checkingForUpdates = true;
        try
        {
            var release = await UpdateService.GetLatestAsync(CancellationToken.None);
            Settings.LastUpdateCheck = DateTime.Now;
            Settings.Save();
            if (release is null || !UpdateService.IsNewer(release) || (!userInitiated && release.Tag == Settings.SkippedUpdateVersion))
            {
                if (release is null || !UpdateService.IsNewer(release))
                    TranslatorWindow.ShowUpdateAvailable(null);
                return null;
            }

            TranslatorWindow.ShowUpdateAvailable(release);
            if (!userInitiated && !TranslatorWindow.IsVisible && Settings.NotifiedUpdateVersion != release.Tag)
            {
                Settings.NotifiedUpdateVersion = release.Tag;
                Settings.Save();
                _tray?.ShowTip(Loc.T($"轻译 {release.VersionText} 已发布", $"QingYi Translator {release.VersionText} is available"),
                    Loc.T("点击这里查看更新内容。", "Click to see what’s new."), () => ShowUpdateDialog(release, null));
            }
            return release;
        }
        finally
        {
            _checkingForUpdates = false;
        }
    }

    internal void ShowUpdateDialog(ReleaseInfo release, Window? owner)
    {
        if (_updateWindow is not null)
        {
            _updateWindow.Activate();
            return;
        }
        if (owner is null || !owner.IsVisible)
        {
            TranslatorWindow.BringToFront();
            owner = TranslatorWindow;
        }
        var window = new UpdateWindow(release, this) { Owner = owner };
        _updateWindow = window;
        try
        {
            window.ShowDialog();
        }
        finally
        {
            _updateWindow = null;
        }
    }

    internal void SkipUpdate(ReleaseInfo release)
    {
        Settings.SkippedUpdateVersion = release.Tag;
        Settings.Save();
        TranslatorWindow.ShowUpdateAvailable(null);
    }

    /// <summary>Swaps in the downloaded version, starts it and exits. Throws if the files can't be replaced.</summary>
    internal void InstallUpdate(string downloadedPath)
    {
        PersistState();
        SelfUpdater.Install(downloadedPath, showWindow: TranslatorWindow.IsVisible);
        ExitApp();
    }

    private static string? ArgumentValue(string[] args, string name)
    {
        int index = Array.FindIndex(args, arg => string.Equals(arg, name, StringComparison.OrdinalIgnoreCase));
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static void WaitForExit(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            process.WaitForExit(TimeSpan.FromSeconds(15));
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
            // Already gone.
        }
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
        MessageBox.Show(Loc.T($"程序遇到错误：{e.Exception.Message}\n\n详细信息已写入日志：{Log.FilePath}",
                $"Something went wrong: {e.Exception.Message}\n\nDetails were written to the log: {Log.FilePath}"),
            Loc.T("轻译", "QingYi Translator"), MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}
