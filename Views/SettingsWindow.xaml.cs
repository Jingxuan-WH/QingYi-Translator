using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

public partial class SettingsWindow : Window
{
    private const string DeepSeekKeyUrl = "https://platform.deepseek.com/api_keys";

    private readonly AppSettings _settings;
    private readonly App _app;
    private readonly Dictionary<string, ProviderConfig> _providers;
    private readonly Dictionary<string, string> _editedKeys = new();
    private readonly List<ProviderOption> _providerOptions;
    private string _currentProvider;
    private HotkeyGesture? _hotkey;
    private bool _loading = true;

    internal SettingsWindow(AppSettings settings, App app)
    {
        _settings = settings;
        _app = app;
        InitializeComponent();

        _providers = settings.ProviderConfigs.ToDictionary(pair => pair.Key, pair => pair.Value.Clone());
        _providerOptions = Providers.All.Select(id => new ProviderOption(id, Providers.DisplayName(id))).ToList();
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
        AutoTranslateToggle.IsChecked = settings.AutoTranslate;
        RestoreClipboardToggle.IsChecked = settings.RestoreClipboard;
        CloseToTrayToggle.IsChecked = settings.CloseToTray;
        StartupToggle.IsChecked = settings.StartWithWindows;

        string version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "";
        VersionText.Text = $"轻译 {version} · 设置保存在 {AppSettings.DataDirectory}";

        SourceInitialized += (_, _) => WindowUtil.StyleCaption(this, Color.FromRgb(0xF3, 0xF5, 0xF9), hideTitle: false);
        Loaded += (_, _) =>
        {
            if (string.IsNullOrEmpty(GetKeyText()))
                KeyBox.Focus();
        };
        _loading = false;
    }

    // ---------------- provider ----------------

    private void ProviderBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ProviderBox.SelectedItem is not ProviderOption option || option.Id == _currentProvider)
            return;
        StoreProviderFields(_currentProvider);
        _currentProvider = option.Id;
        LoadProviderFields(option.Id);
    }

    private void LoadProviderFields(string id)
    {
        var config = _providers.TryGetValue(id, out var existing) ? existing : _providers[id] = Providers.CreateDefault(id);
        SetKeyText(_editedKeys.TryGetValue(id, out var key) ? key : config.ApiKey);
        BaseUrlBox.Text = config.BaseUrl;
        ModelBox.Text = config.Model;

        bool isDeepSeek = id == Providers.DeepSeek;
        KeyLinkButton.Visibility = isDeepSeek ? Visibility.Visible : Visibility.Collapsed;
        ModelChips.ItemsSource = Providers.SuggestedModels(id);
        BaseUrlHint.Text = isDeepSeek
            ? "默认 https://api.deepseek.com，一般不需要修改。"
            : "填写服务商提供的 OpenAI 兼容接口地址，例如 https://api.moonshot.cn/v1";
        ModelHint.Text = isDeepSeek
            ? "deepseek-flash 速度快、价格低，适合日常翻译；deepseek-v4-pro 质量更高，但更慢、更贵。"
            : "填写服务商提供的模型名称。";
        TestResult.Text = "";
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
        try
        {
            Process.Start(new ProcessStartInfo(DeepSeekKeyUrl) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Error("无法打开浏览器", ex);
        }
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
        SetTestResult("正在连接…", "TextSecondaryBrush");
        var watch = Stopwatch.StartNew();
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var reply = new StringBuilder();
            await new TranslationClient().TranslateAsync(config, "",
                new TranslationRequest("Hello, world!", Lang.En, Lang.Zh), piece => reply.Append(piece), timeout.Token);
            string sample = reply.ToString().Trim();
            if (sample.Length > 30)
                sample = sample[..30] + "…";
            SetTestResult($"✓ 连接成功（{watch.Elapsed.TotalSeconds:0.0} 秒）：{sample}", "SuccessBrush");
        }
        catch (TranslationException ex)
        {
            SetTestResult(ex.Message, "ErrorBrush");
        }
        catch (OperationCanceledException)
        {
            SetTestResult("连接超时，请检查网络和接口地址。", "ErrorBrush");
        }
        catch (Exception ex)
        {
            Log.Error("测试连接失败", ex);
            SetTestResult($"测试失败：{ex.Message}", "ErrorBrush");
        }
        finally
        {
            TestButton.IsEnabled = true;
        }
    }

    private void SetTestResult(string text, string brushKey)
    {
        TestResult.Text = text;
        TestResult.Foreground = (Brush)FindResource(brushKey);
    }

    // ---------------- hotkey recording ----------------

    private void HotkeyBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        // Release our own registration so pressing the current hotkey reaches this box.
        _app.SuspendHotkey();
        SetHotkeyStatus("请按下新的组合键（Esc 取消，Backspace 清除）", isError: false);
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
            SetHotkeyStatus("已清除快捷键", isError: false);
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
            SetHotkeyStatus("快捷键需要包含 Ctrl、Alt 或 Win 键", isError: true);
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
            SetHotkeyStatus(required ? "尚未设置快捷键，点击上面的输入框后按下组合键" : "", isError: required);
        }
        else if (!_app.IsHotkeyAvailable(gesture))
        {
            SetHotkeyStatus($"{gesture} 已被其他程序占用，请换一个", isError: true);
        }
        else
        {
            SetHotkeyStatus("选中文字后按下即可翻译；没有选中文字时会直接打开主窗口，再按一次可隐藏。", isError: false);
        }
    }

    private void SetHotkeyStatus(string text, bool isError)
    {
        HotkeyStatus.Text = text;
        HotkeyStatus.Foreground = (Brush)FindResource(isError ? "ErrorBrush" : "TextTertiaryBrush");
    }

    // ---------------- misc ----------------

    private void ExtraBox_TextChanged(object sender, TextChangedEventArgs e) =>
        ExtraPlaceholder.Visibility = ExtraBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (HotkeyToggle.IsChecked == true && _hotkey is null)
        {
            SetHotkeyStatus("请先设置快捷键，或者关闭这个选项", isError: true);
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
        _settings.AutoTranslate = AutoTranslateToggle.IsChecked == true;
        _settings.RestoreClipboard = RestoreClipboardToggle.IsChecked == true;
        _settings.CloseToTray = CloseToTrayToggle.IsChecked == true;
        _settings.StartWithWindows = StartupToggle.IsChecked == true;
        DialogResult = true;
    }
}
