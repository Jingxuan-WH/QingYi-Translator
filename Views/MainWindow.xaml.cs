using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

public partial class MainWindow : Window
{
    private const string DetectLabel = "检测语言";

    // Longer texts are only translated on demand (Ctrl+Enter), so an accidental Ctrl+A, Ctrl+C+C can't burn tokens.
    private const int AutoTranslateLimit = 20_000;
    private static readonly TimeSpan DebounceDelay = TimeSpan.FromMilliseconds(700);

    private readonly AppSettings _settings;
    private readonly TranslationClient _client = new();
    private readonly DispatcherTimer _debounce = new() { Interval = DebounceDelay };
    private readonly LanguageOption _detectOption = new(Lang.Auto, DetectLabel);
    private readonly LanguageOption _sourceZh = new(Lang.Zh, "中文");
    private readonly LanguageOption _sourceEn = new(Lang.En, "英语");
    private readonly LanguageOption _targetZh = new(Lang.Zh, "中文（简体）");
    private readonly LanguageOption _targetEn = new(Lang.En, "英语");

    private Lang _source = Lang.Auto;
    private Lang _target = Lang.En;
    private bool _syncingLanguages;
    private CancellationTokenSource? _translation;
    private string? _lastRequestKey;
    private int _copyFeedbackVersion;

    public MainWindow(AppSettings settings)
    {
        _settings = settings;
        _debounce.Tick += (_, _) => _ = TranslateAsync(force: false);
        InitializeComponent();

        SourceLangBox.ItemsSource = new[] { _detectOption, _sourceZh, _sourceEn };
        TargetLangBox.ItemsSource = new[] { _targetZh, _targetEn };
        SyncLanguageBoxes();

        Topmost = settings.Topmost;
        PinButton.IsChecked = settings.Topmost;
        UpdatePinIcon();
        CenterOnPrimaryScreen();

        SourceInitialized += (_, _) =>
        {
            WindowUtil.StyleCaption(this, Colors.White, hideTitle: true);
            if (_settings.MainWindowBounds is { } saved)
                WindowUtil.TryRestorePlacement(this, saved);
        };
        Closing += OnClosing;
        PreviewKeyDown += OnPreviewKeyDown;

        UpdateSourceChrome();
        UpdateOutputChrome();
        RefreshSettingsDisplay();
    }

    private static App App => (App)Application.Current;

    // ---------------- called by App ----------------

    public void BringToFront() => WindowUtil.ForceForeground(this);

    /// <summary>Brings the window up after a hotkey. With text, translates it; without, focuses the input box.</summary>
    public void ShowWithText(string? text)
    {
        BringToFront();
        text = text?.Trim();
        if (string.IsNullOrEmpty(text))
        {
            SourceBox.Focus();
            SourceBox.SelectAll();
            return;
        }

        // A fixed source language that doesn't match the new text would give nonsense, so fall back to detection.
        if (_source != Lang.Auto && LanguageDetector.Detect(text) != _source)
        {
            _source = Lang.Auto;
            SyncLanguageBoxes();
        }
        SourceBox.Text = text;
        SourceBox.Focus();
        SourceBox.CaretIndex = SourceBox.Text.Length;
        _ = TranslateAsync(force: false);
    }

    public void HideOrMinimize()
    {
        if (_settings.CloseToTray)
        {
            Hide();
            App.NotifyMinimizedToTray();
        }
        else
        {
            WindowState = WindowState.Minimized;
        }
    }

    public void RefreshSettingsDisplay()
    {
        var provider = _settings.Active;
        bool hasKey = !string.IsNullOrWhiteSpace(provider.ApiKey);
        string name = Providers.DisplayName(_settings.ActiveProvider);
        EngineText.Text = hasKey ? $"{name} · {provider.Model}" : $"{name} · 未设置 API Key";
        EngineDot.Fill = (Brush)FindResource(hasKey ? "SuccessBrush" : "WarningBrush");

        var shortcuts = new List<string>(2);
        if (_settings.DoubleCopyEnabled)
            shortcuts.Add("Ctrl+C+C");
        if (App.ActiveHotkey is { } hotkey)
            shortcuts.Add(hotkey.ToString());
        string joined = string.Join(" 或 ", shortcuts);
        PlaceholderHint.Text = shortcuts.Count > 0 ? $"也可以在任意软件中选中文字，按 {joined} 翻译" : "";

        if (App.ShortcutError is { } error)
        {
            ShortcutHintText.Text = error;
            ShortcutHintText.Foreground = (Brush)FindResource("ErrorBrush");
        }
        else
        {
            ShortcutHintText.Text = shortcuts.Count > 0 ? $"选中文字后按 {joined} 翻译" : "";
            ShortcutHintText.Foreground = (Brush)FindResource("TextTertiaryBrush");
        }
    }

    public void OnSettingsChanged()
    {
        RefreshSettingsDisplay();
        // The request key covers provider, model and extra instructions, so this only calls the API if one of them changed.
        if (!string.IsNullOrWhiteSpace(SourceBox.Text))
            _ = TranslateAsync(force: false);
    }

    public void SaveWindowBounds()
    {
        if (WindowUtil.GetPlacement(this) is { } bounds) // null if the window was never shown
            _settings.MainWindowBounds = bounds;
    }

    // ---------------- translation ----------------

    private async Task TranslateAsync(bool force)
    {
        _debounce.Stop();
        string text = SourceBox.Text;
        if (string.IsNullOrWhiteSpace(text))
        {
            ResetOutput();
            return;
        }
        if (!force && text.Length > AutoTranslateLimit)
        {
            CancelTranslation();
            StatusText.Text = $"文本较长（{text.Length:N0} 字符），按 Ctrl+Enter 开始翻译";
            return;
        }

        Lang source = _source == Lang.Auto ? LanguageDetector.Detect(text) : _source;
        Lang target = LanguageDetector.Other(source);
        _detectOption.DisplayName = _source == Lang.Auto ? $"{LanguageName(source)}（检测到）" : DetectLabel;
        SetTarget(target);

        var provider = _settings.Active;
        string requestKey = string.Join('\u001F', source, target, _settings.ActiveProvider, provider.BaseUrl,
            provider.Model, _settings.ExtraInstructions, text);
        if (!force && requestKey == _lastRequestKey)
            return;
        _lastRequestKey = requestKey;

        CancelTranslation();
        var cts = new CancellationTokenSource();
        _translation = cts;
        HideError();
        OutputBox.Clear();
        StatusText.Text = "正在翻译…";
        SetBusy(true);
        var watch = Stopwatch.StartNew();
        try
        {
            var result = await _client.TranslateAsync(provider, _settings.ExtraInstructions,
                new TranslationRequest(text, source, target), AppendOutput, cts.Token);
            if (cts == _translation)
            {
                StatusText.Text = result switch
                {
                    { FinishReason: "length" } => "译文过长，已被截断",
                    { FinishReason: "content_filter" } => "部分内容被服务商过滤，译文可能不完整",
                    { FinishReason: "insufficient_system_resource" } => "服务器资源不足，译文可能不完整，请稍后重试",
                    { Text.Length: 0 } => "服务器没有返回译文",
                    _ => $"{Providers.DisplayName(_settings.ActiveProvider)} · {watch.Elapsed.TotalSeconds:0.0} 秒",
                };
            }
        }
        catch (OperationCanceledException)
        {
            // Superseded by newer input.
        }
        catch (TranslationException ex)
        {
            if (cts == _translation)
                FailTranslation(ex.Message, ex.NeedsSettings);
        }
        catch (Exception ex)
        {
            Log.Error("翻译失败", ex);
            if (cts == _translation)
                FailTranslation($"翻译失败：{ex.Message}", needsSettings: false);
        }
        finally
        {
            if (cts == _translation)
            {
                _translation = null;
                SetBusy(false);
            }
            cts.Dispose();
        }
    }

    private void AppendOutput(string delta)
    {
        OutputBox.AppendText(delta);
        UpdateOutputChrome();
    }

    private void FailTranslation(string message, bool needsSettings)
    {
        _lastRequestKey = null;
        StatusText.Text = "";
        ErrorText.Text = message;
        ErrorActionButton.Visibility = needsSettings ? Visibility.Visible : Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private void HideError() => ErrorPanel.Visibility = Visibility.Collapsed;

    private void CancelTranslation()
    {
        if (_translation is null)
            return;
        _translation.Cancel();
        _translation = null;
        SetBusy(false);
    }

    private void ResetOutput()
    {
        CancelTranslation();
        _lastRequestKey = null;
        OutputBox.Clear();
        HideError();
        StatusText.Text = "";
        _detectOption.DisplayName = DetectLabel;
        UpdateOutputChrome();
    }

    private void SetBusy(bool busy)
    {
        if (busy)
        {
            LoadingTrack.Visibility = Visibility.Visible;
            double width = Math.Max(OutputPane.ActualWidth, 200);
            var sweep = new DoubleAnimation(-140, width, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            LoadingShift.BeginAnimation(TranslateTransform.XProperty, sweep);
        }
        else
        {
            LoadingShift.BeginAnimation(TranslateTransform.XProperty, null);
            LoadingTrack.Visibility = Visibility.Collapsed;
        }
        UpdateOutputChrome();
    }

    private void UpdateOutputChrome()
    {
        bool busy = LoadingTrack.Visibility == Visibility.Visible;
        OutputPlaceholder.Visibility = OutputBox.Text.Length == 0 && !busy ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateSourceChrome()
    {
        int length = SourceBox.Text.Length;
        bool empty = length == 0;
        SourcePlaceholder.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        ClearButton.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        CharCountText.Text = empty ? "" : $"{length:N0} 字符";
    }

    // ---------------- languages ----------------

    private void SourceLangBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingLanguages || SourceLangBox.SelectedItem is not LanguageOption option)
            return;
        _source = option.Lang;
        if (_source != Lang.Auto)
        {
            _detectOption.DisplayName = DetectLabel;
            SetTarget(LanguageDetector.Other(_source));
        }
        _ = TranslateAsync(force: false);
    }

    private void TargetLangBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingLanguages || TargetLangBox.SelectedItem is not LanguageOption option)
            return;
        // With only two languages, picking the target fixes the source too.
        _target = option.Lang;
        _source = LanguageDetector.Other(option.Lang);
        _detectOption.DisplayName = DetectLabel;
        SyncLanguageBoxes();
        _ = TranslateAsync(force: false);
    }

    private void SwapButton_Click(object sender, RoutedEventArgs e)
    {
        string text = SourceBox.Text;
        Lang currentSource = _source != Lang.Auto ? _source
            : string.IsNullOrWhiteSpace(text) ? LanguageDetector.Other(_target)
            : LanguageDetector.Detect(text);
        _source = LanguageDetector.Other(currentSource);
        _target = currentSource;
        _detectOption.DisplayName = DetectLabel;
        SyncLanguageBoxes();

        // Like DeepL, the translation becomes the new input.
        string translation = OutputBox.Text;
        if (!string.IsNullOrWhiteSpace(translation))
        {
            SourceBox.Text = translation;
            SourceBox.CaretIndex = SourceBox.Text.Length;
        }
        _ = TranslateAsync(force: false);
    }

    private void SyncLanguageBoxes()
    {
        _syncingLanguages = true;
        SourceLangBox.SelectedItem = _source switch
        {
            Lang.Zh => _sourceZh,
            Lang.En => _sourceEn,
            _ => _detectOption,
        };
        TargetLangBox.SelectedItem = _target == Lang.Zh ? _targetZh : _targetEn;
        _syncingLanguages = false;
    }

    private void SetTarget(Lang target)
    {
        _target = target;
        _syncingLanguages = true;
        TargetLangBox.SelectedItem = target == Lang.Zh ? _targetZh : _targetEn;
        _syncingLanguages = false;
    }

    private static string LanguageName(Lang lang) => lang == Lang.Zh ? "中文" : "英语";

    // ---------------- UI events ----------------

    private void SourceBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        UpdateSourceChrome();
        if (string.IsNullOrWhiteSpace(SourceBox.Text))
        {
            _debounce.Stop();
            ResetOutput();
            return;
        }
        if (_settings.AutoTranslate)
        {
            _debounce.Stop();
            _debounce.Start();
        }
    }

    private void ClearButton_Click(object sender, RoutedEventArgs e)
    {
        SourceBox.Clear();
        SourceBox.Focus();
    }

    private void RetranslateButton_Click(object sender, RoutedEventArgs e) => _ = TranslateAsync(force: true);

    private async void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        string text = OutputBox.Text;
        if (text.Length == 0 || !ClipboardUtil.TrySetText(text))
            return;
        int version = ++_copyFeedbackVersion;
        CopyButton.Content = "";
        CopyButton.ToolTip = "已复制";
        await Task.Delay(1500);
        if (version != _copyFeedbackVersion)
            return;
        CopyButton.Content = "";
        CopyButton.ToolTip = "复制译文";
    }

    private void PinButton_Click(object sender, RoutedEventArgs e)
    {
        Topmost = PinButton.IsChecked == true;
        _settings.Topmost = Topmost;
        _settings.Save();
        UpdatePinIcon();
    }

    private void UpdatePinIcon()
    {
        PinButton.Content = Topmost ? "" : "";
        PinButton.ToolTip = Topmost ? "取消置顶" : "窗口置顶";
    }

    private void SettingsButton_Click(object sender, RoutedEventArgs e) => App.OpenSettings();

    private void EngineStatus_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => App.OpenSettings();

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
        {
            e.Handled = true;
            _ = TranslateAsync(force: true);
        }
        else if (e.Key == Key.Escape && !SourceLangBox.IsDropDownOpen && !TargetLangBox.IsDropDownOpen)
        {
            e.Handled = true;
            HideOrMinimize();
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (App.IsExiting)
            return;
        e.Cancel = true;
        if (_settings.CloseToTray)
        {
            SaveWindowBounds();
            _settings.Save();
            HideOrMinimize();
        }
        else
        {
            Dispatcher.InvokeAsync(App.ExitApp);
        }
    }

    /// <summary>
    /// Default spot for the first launch. WPF's CenterScreen follows the mouse, and on a monitor whose DPI differs
    /// from the primary one it can create the window at the wrong size, so center on the primary work area instead.
    /// </summary>
    private void CenterOnPrimaryScreen()
    {
        Rect area = SystemParameters.WorkArea;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = area.Left + Math.Max(0, (area.Width - Width) / 2);
        Top = area.Top + Math.Max(0, (area.Height - Height) / 2);
    }
}
