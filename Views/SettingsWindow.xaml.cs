using System.Diagnostics;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

public partial class SettingsWindow : Window
{
    private readonly AppSettings _settings;
    private readonly App _app;
    private readonly Dictionary<string, ProviderConfig> _providers;
    private readonly Dictionary<string, string> _editedKeys = new();
    private readonly List<ChoiceOption> _providerOptions;
    private readonly List<ChoiceOption> _languageOptions =
    [
        new(Loc.SystemCode, new LocText("跟随系统", "System default")),
        new(Loc.ChineseCode, "简体中文"),
        new(Loc.EnglishCode, "English"),
    ];
    private readonly List<ChoiceOption> _themeOptions =
    [
        new(AppSettings.ThemeSystem, new LocText("跟随系统", "System default")),
        new(AppSettings.ThemeLight, new LocText("浅色", "Light")),
        new(AppSettings.ThemeDark, new LocText("深色", "Dark")),
    ];
    private string _currentProvider;
    private HotkeyGesture? _hotkey;
    private Func<string>? _testResult;
    private Func<string>? _updateStatus;
    private bool _loading = true;
    private bool _saved;

    internal SettingsWindow(AppSettings settings, App app)
    {
        _settings = settings;
        _app = app;
        InitializeComponent();

        // Language and theme preview live; they are put back if the dialog is cancelled.
        UiLanguageBox.ItemsSource = _languageOptions;
        UiLanguageBox.SelectedItem = _languageOptions.First(option => option.Id == settings.UiLanguage);
        ThemeBox.ItemsSource = _themeOptions;
        ThemeBox.SelectedItem = _themeOptions.First(option => option.Id == settings.Theme);

        _providers = settings.ProviderConfigs.ToDictionary(pair => pair.Key, pair => pair.Value.Clone());
        _providerOptions = ProviderCatalog.All.Select(preset => new ChoiceOption(preset.Id, preset.DisplayName)).ToList();
        _currentProvider = settings.ActiveProvider;
        ProviderBox.ItemsSource = _providerOptions;
        ProviderBox.SelectedItem = _providerOptions.First(option => option.Id == _currentProvider);
        LoadProviderFields(_currentProvider);

        DoubleCopyToggle.IsChecked = settings.DoubleCopyEnabled;
        HotkeyToggle.IsChecked = settings.HotkeyEnabled;
        _hotkey = HotkeyGesture.TryParse(settings.Hotkey, out var gesture) ? gesture : null;
        HotkeyBox.Text = _hotkey?.ToString() ?? "";
        UpdateHotkeyStatus();

        ExtraBox.Text = settings.ExtraInstructions;
        IncrementalToggle.IsChecked = settings.IncrementalTranslation;
        HistoryToggle.IsChecked = settings.SaveHistory;
        AutoTranslateToggle.IsChecked = settings.AutoTranslate;
        RestoreClipboardToggle.IsChecked = settings.RestoreClipboard;
        CloseToTrayToggle.IsChecked = settings.CloseToTray;
        StartupToggle.IsChecked = settings.StartWithWindows;
        AutoUpdateToggle.IsChecked = settings.AutoCheckUpdates;
        _updateStatus = DescribeLastCheck;
        RefreshLocalizedText();

        ThemeManager.Track(this, "WindowBrush");
        Loaded += (_, _) =>
        {
            if (ProviderCatalog.Get(_currentProvider).RequiresApiKey && string.IsNullOrEmpty(GetKeyText()))
                KeyBox.Focus();
        };
        Loc.Changed += OnInterfaceLanguageChanged;
        Closed += OnClosed;
        _loading = false;
    }

    // ---------------- appearance ----------------

    private void UiLanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && UiLanguageBox.SelectedItem is ChoiceOption option)
            Loc.Apply(option.Id);
    }

    private void ThemeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && ThemeBox.SelectedItem is ChoiceOption option)
            ThemeManager.Apply(option.Id);
    }

    private void OnInterfaceLanguageChanged()
    {
        foreach (var option in _providerOptions.Concat(_languageOptions).Concat(_themeOptions))
            option.Refresh();
        LoadProviderHints(ProviderCatalog.Get(_currentProvider));
        UpdateHotkeyStatus();
        RefreshLocalizedText();
    }

    private void RefreshLocalizedText()
    {
        TestResult.Text = _testResult?.Invoke() ?? "";
        UpdateStatus.Text = _updateStatus?.Invoke() ?? "";
        CurrentVersionText.Text = Loc.T($"当前版本 {UpdateService.CurrentVersionText}", $"Current version {UpdateService.CurrentVersionText}");
        DataDirText.Text = Loc.T($"设置保存在 {AppSettings.DataDirectory}", $"Settings are stored in {AppSettings.DataDirectory}");
        UpdateGlossaryStatus();
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        Loc.Changed -= OnInterfaceLanguageChanged;
        if (!_saved)
        {
            Loc.Apply(_settings.UiLanguage);
            ThemeManager.Apply(_settings.Theme);
        }
    }

    // ---------------- provider ----------------

    private void ProviderBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ProviderBox.SelectedItem is not ChoiceOption option || option.Id == _currentProvider)
            return;
        StoreProviderFields(_currentProvider);
        _currentProvider = option.Id;
        LoadProviderFields(option.Id);
    }

    private void LoadProviderFields(string id)
    {
        var preset = ProviderCatalog.Get(id);
        var config = _providers.TryGetValue(id, out var existing) ? existing : _providers[id] = ProviderConfig.FromPreset(preset);
        SetKeyText(_editedKeys.TryGetValue(id, out var key) ? key : config.ApiKey);
        BaseUrlBox.Text = config.BaseUrl;
        ModelBox.Text = config.Model;
        KeyLinkButton.Visibility = preset.KeyUrl is null ? Visibility.Collapsed : Visibility.Visible;
        ModelChips.ItemsSource = preset.SuggestedModels;
        LoadProviderHints(preset);
        SetTestResult(null, "TextSecondaryBrush");
    }

    private void LoadProviderHints(ProviderPreset preset)
    {
        ProviderHint.Text = preset.Hint;
        KeyHint.Text = preset.RequiresApiKey
            ? Loc.T("API Key 使用 Windows 账户加密后保存在本机，不会上传到其他地方。",
                "Your API key is encrypted with your Windows account and stored only on this PC.")
            : Loc.T("本地模型不需要 API Key，可以留空。", "Local models don’t need an API key; leave it empty.");
        BaseUrlHint.Text = preset.BaseUrl.Length > 0
            ? Loc.T($"默认 {preset.BaseUrl}，一般不需要修改。", $"Default: {preset.BaseUrl}. Usually there is no need to change it.")
            : Loc.T("填写服务商提供的 OpenAI 兼容接口地址，例如 https://example.com/v1",
                "Enter the OpenAI-compatible base URL from your provider, e.g. https://example.com/v1");
        ModelHint.Text = preset.ModelHint;
    }

    private void StoreProviderFields(string id)
    {
        var config = _providers[id];
        _editedKeys[id] = GetKeyText();
        config.BaseUrl = BaseUrlBox.Text.Trim();
        config.Model = ModelBox.Text.Trim();
    }

    private string GetKeyText() => (RevealKeyButton.IsChecked == true ? KeyPlainBox.Text : KeyBox.Password).Trim();

    private void SetKeyText(string key)
    {
        KeyBox.Password = key;
        KeyPlainBox.Text = key;
    }

    private void RevealKeyButton_Click(object sender, RoutedEventArgs e)
    {
        bool reveal = RevealKeyButton.IsChecked == true;
        if (reveal)
            KeyPlainBox.Text = KeyBox.Password;
        else
            KeyBox.Password = KeyPlainBox.Text;
        KeyPlainBox.Visibility = reveal ? Visibility.Visible : Visibility.Collapsed;
        KeyBox.Visibility = reveal ? Visibility.Collapsed : Visibility.Visible;
    }

    private void KeyLinkButton_Click(object sender, RoutedEventArgs e)
    {
        if (ProviderCatalog.Get(_currentProvider).KeyUrl is { } url)
            App.OpenUrl(url);
    }

    private void ModelChip_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Content: string model })
            ModelBox.Text = model;
    }

    private async void TestButton_Click(object sender, RoutedEventArgs e)
    {
        var config = _providers[_currentProvider].Clone();
        config.BaseUrl = BaseUrlBox.Text.Trim();
        config.Model = ModelBox.Text.Trim();
        config.ApiKey = GetKeyText();

        TestButton.IsEnabled = false;
        SetTestResult(() => Loc.T("正在连接…", "Connecting…"), "TextSecondaryBrush");
        var watch = Stopwatch.StartNew();
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var reply = new StringBuilder();
            await new TranslationClient().TranslateAsync(ProviderCatalog.Get(_currentProvider), config, "",
                new TranslationRequest("Hello, world!", Languages.English, Languages.SimplifiedChinese, []),
                piece => reply.Append(piece), timeout.Token);
            string sample = reply.ToString().Trim();
            if (sample.Length > 30)
                sample = sample[..30] + "…";
            double seconds = watch.Elapsed.TotalSeconds;
            SetTestResult(() => Loc.T($"✓ 连接成功（{seconds:0.0} 秒）：{sample}", $"✓ Connected ({seconds:0.0} s): {sample}"), "SuccessBrush");
        }
        catch (TranslationException ex)
        {
            SetTestResult(() => ex.Message, "ErrorBrush");
        }
        catch (OperationCanceledException)
        {
            SetTestResult(() => Loc.T("连接超时，请检查网络和接口地址。", "Timed out. Please check your network and the base URL."), "ErrorBrush");
        }
        catch (Exception ex)
        {
            Log.Error("测试连接失败", ex);
            SetTestResult(() => Loc.T($"测试失败：{ex.Message}", $"Test failed: {ex.Message}"), "ErrorBrush");
        }
        finally
        {
            TestButton.IsEnabled = true;
        }
    }

    private void SetTestResult(Func<string>? text, string brushKey)
    {
        _testResult = text;
        TestResult.Text = text?.Invoke() ?? "";
        TestResult.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
    }

    // ---------------- glossary ----------------

    private void GlossaryButton_Click(object sender, RoutedEventArgs e)
    {
        _app.OpenGlossary(this);
        UpdateGlossaryStatus();
    }

    private void UpdateGlossaryStatus()
    {
        int count = _app.Glossary.Entries.Count;
        GlossaryStatus.Text = count == 0
            ? Loc.T("按你指定的译法翻译专业术语、人名和产品名。", "Make terms, names and product names translate the way you want.")
            : !_settings.GlossaryEnabled ? Loc.T($"{count} 条术语 · 已停用", count == 1 ? "1 term · turned off" : $"{count} terms · turned off")
            : Loc.T($"{count} 条术语 · 已启用", count == 1 ? "1 term · on" : $"{count} terms · on");
    }

    // ---------------- updates ----------------

    private async void CheckUpdateButton_Click(object sender, RoutedEventArgs e)
    {
        CheckUpdateButton.IsEnabled = false;
        SetUpdateStatus(() => Loc.T("正在检查…", "Checking…"), "TextTertiaryBrush");
        try
        {
            var release = await _app.CheckForUpdatesAsync(userInitiated: true);
            if (release is null)
            {
                SetUpdateStatus(() => Loc.T("已是最新版本。", "You’re up to date."), "SuccessBrush");
            }
            else
            {
                SetUpdateStatus(() => Loc.T($"发现新版本 {release.VersionText}", $"Version {release.VersionText} is available"), "AccentTextBrush");
                _app.ShowUpdateDialog(release, this);
            }
        }
        catch (UpdateException ex)
        {
            SetUpdateStatus(() => ex.Message, "ErrorBrush");
        }
        finally
        {
            CheckUpdateButton.IsEnabled = true;
        }
    }

    private string DescribeLastCheck() => _settings.LastUpdateCheck is { } last
        ? Loc.T($"上次检查：{last:yyyy-MM-dd HH:mm}", $"Last checked: {last:yyyy-MM-dd HH:mm}")
        : "";

    private void SetUpdateStatus(Func<string> text, string brushKey)
    {
        _updateStatus = text;
        UpdateStatus.Text = text();
        UpdateStatus.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
    }

    // ---------------- hotkey recording ----------------

    private void HotkeyBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        // Release our own registration so pressing the current hotkey reaches this box.
        _app.SuspendHotkey();
        SetHotkeyStatus(Loc.T("请按下新的组合键（Esc 取消，Backspace 清除）", "Press the new key combination (Esc cancels, Backspace clears)"), isError: false);
    }

    private void HotkeyBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        _app.ResumeHotkey();
        HotkeyBox.Text = _hotkey?.ToString() ?? "";
        UpdateHotkeyStatus();
    }

    private void HotkeyBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        Key key = e.Key switch
        {
            Key.System => e.SystemKey,
            Key.ImeProcessed => e.ImeProcessedKey,
            _ => e.Key,
        };
        ModifierKeys modifiers = Keyboard.Modifiers;

        if (modifiers == ModifierKeys.None && key is Key.Escape or Key.Tab)
        {
            Keyboard.ClearFocus();
            return;
        }
        if (modifiers == ModifierKeys.None && key is Key.Back or Key.Delete)
        {
            _hotkey = null;
            HotkeyBox.Text = "";
            SetHotkeyStatus(Loc.T("已清除快捷键", "Hotkey cleared"), isError: false);
            return;
        }
        if (HotkeyGesture.IsModifierKey(key))
        {
            HotkeyBox.Text = HotkeyGesture.FormatModifiers(modifiers) + "+…";
            return;
        }

        var gesture = new HotkeyGesture(modifiers, key);
        HotkeyBox.Text = gesture.ToString();
        if (!gesture.IsValid)
        {
            SetHotkeyStatus(Loc.T("快捷键需要包含 Ctrl、Alt 或 Win 键", "The hotkey must include Ctrl, Alt or Win"), isError: true);
            return;
        }
        _hotkey = gesture;
        UpdateHotkeyStatus();
    }

    private void HotkeyToggle_Click(object sender, RoutedEventArgs e) => UpdateHotkeyStatus();

    private void UpdateHotkeyStatus()
    {
        if (_hotkey is not { } gesture)
        {
            bool required = HotkeyToggle.IsChecked == true;
            SetHotkeyStatus(required ? Loc.T("尚未设置快捷键，点击上面的输入框后按下组合键", "No hotkey yet. Click the box above and press a key combination") : "",
                isError: required);
        }
        else if (!_app.IsHotkeyAvailable(gesture))
        {
            SetHotkeyStatus(Loc.T($"{gesture} 已被其他程序占用，请换一个", $"{gesture} is already used by another program. Please pick another one"), isError: true);
        }
        else
        {
            SetHotkeyStatus(Loc.T("选中文字后按下即可翻译；没有选中文字时会直接打开主窗口，再按一次可隐藏。",
                "Select text and press it to translate. Without a selection it opens the main window; press again to hide it."), isError: false);
        }
    }

    private void SetHotkeyStatus(string text, bool isError)
    {
        HotkeyStatus.Text = text;
        HotkeyStatus.SetResourceReference(TextBlock.ForegroundProperty, isError ? "ErrorBrush" : "TextTertiaryBrush");
    }

    // ---------------- misc ----------------

    private void ExtraBox_TextChanged(object sender, TextChangedEventArgs e) =>
        ExtraPlaceholder.Visibility = ExtraBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (HotkeyToggle.IsChecked == true && _hotkey is null)
        {
            SetHotkeyStatus(Loc.T("请先设置快捷键，或者关闭这个选项", "Set a hotkey first, or turn this option off"), isError: true);
            HotkeyBox.BringIntoView();
            return;
        }

        StoreProviderFields(_currentProvider);
        foreach (var (id, key) in _editedKeys)
            _providers[id].ApiKey = key;

        _settings.ProviderConfigs = _providers;
        _settings.ActiveProvider = _currentProvider;
        _settings.DoubleCopyEnabled = DoubleCopyToggle.IsChecked == true;
        _settings.HotkeyEnabled = HotkeyToggle.IsChecked == true;
        _settings.Hotkey = _hotkey?.ToString() ?? "";
        _settings.ExtraInstructions = ExtraBox.Text.Trim();
        _settings.IncrementalTranslation = IncrementalToggle.IsChecked == true;
        _settings.SaveHistory = HistoryToggle.IsChecked == true;
        _settings.AutoTranslate = AutoTranslateToggle.IsChecked == true;
        _settings.RestoreClipboard = RestoreClipboardToggle.IsChecked == true;
        _settings.CloseToTray = CloseToTrayToggle.IsChecked == true;
        _settings.StartWithWindows = StartupToggle.IsChecked == true;
        _settings.AutoCheckUpdates = AutoUpdateToggle.IsChecked == true;
        _settings.UiLanguage = (UiLanguageBox.SelectedItem as ChoiceOption)?.Id ?? Loc.SystemCode;
        _settings.Theme = (ThemeBox.SelectedItem as ChoiceOption)?.Id ?? AppSettings.ThemeSystem;
        _saved = true;
        DialogResult = true;
    }
}
