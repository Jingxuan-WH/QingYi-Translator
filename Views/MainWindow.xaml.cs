using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

public partial class MainWindow : Window
{
    // Longer texts are only translated on demand (Ctrl+Enter), so an accidental Ctrl+A, Ctrl+C+C can't burn tokens.
    private const int AutoTranslateLimit = 20_000;
    private static readonly TimeSpan DebounceDelay = TimeSpan.FromMilliseconds(700);

    private readonly AppSettings _settings;
    private readonly TranslationHistory _history;
    private readonly Glossary _glossary;
    private readonly ICollectionView _historyView;
    private readonly TranslationClient _client = new();
    private readonly IncrementalCache _incremental = new();
    private readonly DispatcherTimer _debounce = new() { Interval = DebounceDelay };
    private readonly LanguageOption _detectOption = new(null, DetectLabel);
    private readonly List<LanguageOption> _sourceOptions;
    private readonly List<LanguageOption> _targetOptions;

    private Language? _source;           // null: detect automatically
    private Language? _detected;         // what detection found in the current text, for the drop-down label
    private Language _preferredTarget;   // what the user picked
    private Language _target;            // what the current text goes into (the fallback when it is already in the picked language)
    private bool _syncingLanguages;
    private bool _restoringHistory;
    private CancellationTokenSource? _translation;
    private string? _lastRequestKey;
    private Func<string>? _status;       // re-evaluated when the interface language changes
    private bool _copied;
    private int _copyFeedbackVersion;
    private ReleaseInfo? _availableUpdate;

    public MainWindow(AppSettings settings, TranslationHistory history, Glossary glossary)
    {
        _settings = settings;
        _history = history;
        _glossary = glossary;
        _debounce.Tick += (_, _) => _ = TranslateAsync(force: false);
        InitializeComponent();

        _sourceOptions = [_detectOption, .. Languages.All.Select(language => new LanguageOption(language))];
        _targetOptions = Languages.All.Select(language => new LanguageOption(language)).ToList();
        SourceLangBox.ItemsSource = _sourceOptions;
        TargetLangBox.ItemsSource = _targetOptions;
        _source = Languages.Find(settings.SourceLanguage);
        _preferredTarget = Languages.Find(settings.TargetLanguage) ?? Languages.SimplifiedChinese;
        _target = _preferredTarget;
        SyncLanguageBoxes();

        _historyView = CollectionViewSource.GetDefaultView(history.Entries);
        _historyView.Filter = MatchesHistorySearch;
        HistoryList.ItemsSource = _historyView;
        history.Entries.CollectionChanged += (_, _) => UpdateHistoryChrome();

        Topmost = settings.Topmost;
        PinButton.IsChecked = settings.Topmost;
        UpdatePinIcon();
        UpdateCopyButton();
        CenterOnPrimaryScreen();

        ThemeManager.Track(this, "SurfaceBrush", hideTitle: true);
        SourceInitialized += (_, _) =>
        {
            if (_settings.MainWindowBounds is { } saved)
                WindowUtil.TryRestorePlacement(this, saved);
        };
        Closing += OnClosing;
        PreviewKeyDown += OnPreviewKeyDown;
        Loc.Changed += OnInterfaceLanguageChanged;

        UpdateSourceChrome();
        UpdateOutputChrome();
        UpdateHistoryChrome();
        RefreshSettingsDisplay();
    }

    private static App App => (App)Application.Current;

    private static string DetectLabel => Loc.T("检测语言", "Detect language");

    // ---------------- called by App ----------------

    public void BringToFront() => WindowUtil.ForceForeground(this);

    /// <summary>Brings the window up after a hotkey. With text, translates it; without, focuses the input box.</summary>
    public void ShowWithText(string? text)
    {
        BringToFront();
        SetHistoryOpen(false);
        text = text?.Trim();
        if (string.IsNullOrEmpty(text))
        {
            SourceBox.Focus();
            SourceBox.SelectAll();
            return;
        }

        // A fixed source language that doesn't match the new text would give nonsense, so fall back to detection.
        if (_source is { } chosen && LanguageDetector.Detect(text) is { } detected && !detected.IsSameLanguageAs(chosen))
        {
            _source = null;
            _settings.SourceLanguage = Languages.AutoCode;
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
        var preset = _settings.ActivePreset;
        var config = _settings.Active;
        string? problem = string.IsNullOrWhiteSpace(config.Model) ? Loc.T("未设置模型", "No model set")
            : preset.RequiresApiKey && string.IsNullOrWhiteSpace(config.ApiKey) ? Loc.T("未设置 API Key", "No API key")
            : null;
        EngineText.Text = $"{preset.DisplayName} · {problem ?? config.Model}";
        EngineDot.SetResourceReference(Shape.FillProperty, problem is null ? "SuccessBrush" : "WarningBrush");

        var shortcuts = new List<string>(2);
        if (_settings.DoubleCopyEnabled)
            shortcuts.Add("Ctrl+C+C");
        if (App.ActiveHotkey is { } hotkey)
            shortcuts.Add(hotkey.ToString());
        string joined = string.Join(Loc.T(" 或 ", " or "), shortcuts);
        PlaceholderHint.Text = shortcuts.Count > 0
            ? Loc.T($"也可以在任意软件中选中文字，按 {joined} 翻译", $"Or select text in any app and press {joined}")
            : "";

        if (App.ShortcutError is { } error)
        {
            ShortcutHintText.Text = error;
            ShortcutHintText.SetResourceReference(TextBlock.ForegroundProperty, "ErrorBrush");
        }
        else
        {
            ShortcutHintText.Text = shortcuts.Count > 0 ? Loc.T($"选中文字后按 {joined} 翻译", $"Select text and press {joined} to translate") : "";
            ShortcutHintText.SetResourceReference(TextBlock.ForegroundProperty, "TextTertiaryBrush");
        }
        UpdateHistoryChrome();
    }

    public void OnSettingsChanged()
    {
        RefreshSettingsDisplay();
        // The request key covers provider, model, extra instructions and the glossary,
        // so this only calls the API if one of them changed.
        if (!string.IsNullOrWhiteSpace(SourceBox.Text))
            _ = TranslateAsync(force: false);
    }

    public void SaveWindowBounds()
    {
        if (WindowUtil.GetPlacement(this) is { } bounds) // null if the window was never shown
            _settings.MainWindowBounds = bounds;
    }

    /// <summary>Shows or hides the "new version" badge in the header.</summary>
    public void ShowUpdateAvailable(ReleaseInfo? release)
    {
        _availableUpdate = release;
        UpdateButton.Visibility = release is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateUpdateButton();
    }

    /// <summary>A one-off message in the status line, e.g. after an update.</summary>
    public void ShowNotice(Func<string> message)
    {
        if (string.IsNullOrWhiteSpace(SourceBox.Text))
            SetStatus(message);
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
            int length = text.Length;
            SetStatus(() => Loc.T($"文本较长（{length:N0} 字符），按 Ctrl+Enter 开始翻译",
                $"Long text ({length:N0} characters). Press Ctrl+Enter to translate"));
            return;
        }

        var (detected, promptSource, target) = ResolveLanguages(text);
        _detected = detected;
        UpdateDetectLabel();
        ShowTarget(target);

        var preset = _settings.ActivePreset;
        var config = _settings.Active;
        string contextKey = BuildContextKey(promptSource, target, preset, config);
        string requestKey = contextKey + '\u001F' + text;
        if (!force && requestKey == _lastRequestKey)
            return;
        _lastRequestKey = requestKey;

        // Reuse the translation of unchanged leading paragraphs; Ctrl+Enter / the retranslate button starts over.
        var plan = force || !_settings.IncrementalTranslation ? IncrementalPlan.Full(text) : _incremental.Plan(contextKey, text);

        CancelTranslation();
        HideError();
        if (plan.NothingNew)
        {
            OutputBox.Text = plan.ReusedTranslation.TrimEnd();
            _incremental.Commit(contextKey, plan, "");
            UpdateOutputChrome();
            return;
        }

        var cts = new CancellationTokenSource();
        _translation = cts;
        OutputBox.Text = plan.ReusedTranslation;
        bool full = plan.IsFull;
        SetStatus(() => full ? Loc.T("正在翻译…", "Translating…") : Loc.T("正在翻译新增内容…", "Translating the new part…"));
        SetBusy(true);
        var watch = Stopwatch.StartNew();
        try
        {
            var glossary = _settings.GlossaryEnabled ? _glossary.Match(plan.Remainder) : [];
            var request = new TranslationRequest(plan.Remainder, promptSource, target, plan.Context, glossary);
            var result = await _client.TranslateAsync(preset, config, _settings.ExtraInstructions, request, AppendOutput, cts.Token);
            if (cts == _translation)
            {
                _incremental.Commit(contextKey, plan, result.Text);
                var elapsed = watch.Elapsed;
                int glossaryHits = glossary.Count;
                SetStatus(() => DescribeResult(result, preset, elapsed, full, glossaryHits));
                if (result.Text.Length > 0)
                    RecordHistory(text, promptSource ?? detected, target, preset, config);
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
                FailTranslation(Loc.T($"翻译失败：{ex.Message}", $"Translation failed: {ex.Message}"), needsSettings: false);
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

    /// <summary>
    /// With automatic detection, text already written in the picked target language goes to the fallback
    /// (Chinese → English, anything else → Chinese); the model is then left to identify the source itself.
    /// </summary>
    private (Language? Detected, Language? PromptSource, Language Target) ResolveLanguages(string text)
    {
        if (_source is { } chosen)
            return (chosen, chosen, _preferredTarget);
        var detected = LanguageDetector.Detect(text);
        var target = detected is not null && detected.IsSameLanguageAs(_preferredTarget)
            ? Languages.FallbackFor(_preferredTarget)
            : _preferredTarget;
        return (detected, null, target);
    }

    private string BuildContextKey(Language? promptSource, Language target, ProviderPreset preset, ProviderConfig config) =>
        string.Join('\u001F', promptSource?.Code ?? Languages.AutoCode, target.Code, preset.Id, config.BaseUrl, config.Model,
            _settings.ExtraInstructions, _settings.GlossaryEnabled ? _glossary.Version : -1);

    private static string DescribeResult(TranslationResult result, ProviderPreset preset, TimeSpan elapsed, bool full, int glossaryHits)
    {
        string summary = result switch
        {
            { FinishReason: "length" } => Loc.T("译文过长，已被截断", "The translation was too long and got cut off"),
            { FinishReason: "content_filter" } => Loc.T("部分内容被服务商过滤，译文可能不完整", "The provider filtered some content; the translation may be incomplete"),
            { FinishReason: "insufficient_system_resource" } => Loc.T("服务器资源不足，译文可能不完整，请稍后重试",
                "The server ran out of resources; the translation may be incomplete. Please try again later"),
            { Text.Length: 0 } => Loc.T("服务器没有返回译文", "The server returned no translation"),
            _ => Loc.T($"{preset.DisplayName} · {elapsed.TotalSeconds:0.0} 秒", $"{preset.DisplayName} · {elapsed.TotalSeconds:0.0} s"),
        };
        if (result.Text.Length > 0 && result.FinishReason is null or "stop")
        {
            if (!full)
                summary += Loc.T(" · 只翻译了新增内容", " · only the new part was translated");
            if (glossaryHits > 0)
                summary += Loc.T($" · 用到 {glossaryHits} 条术语", glossaryHits == 1 ? " · 1 glossary term" : $" · {glossaryHits} glossary terms");
        }
        return summary;
    }

    private void RecordHistory(string text, Language? source, Language target, ProviderPreset preset, ProviderConfig config)
    {
        if (!_settings.SaveHistory)
            return;
        _history.Record(new HistoryEntry
        {
            Time = DateTime.Now,
            SourceText = text,
            TranslatedText = OutputBox.Text,
            SourceLanguage = source?.Code,
            TargetLanguage = target.Code,
            Engine = $"{preset.DisplayName.En} · {config.Model}",
        });
    }

    private void AppendOutput(string delta)
    {
        OutputBox.AppendText(delta);
        UpdateOutputChrome();
    }

    private void FailTranslation(string message, bool needsSettings)
    {
        _lastRequestKey = null;
        SetStatus(null);
        ErrorText.Text = message;
        ErrorActionButton.Visibility = needsSettings ? Visibility.Visible : Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Visible;
    }

    private void HideError() => ErrorPanel.Visibility = Visibility.Collapsed;

    private void SetStatus(Func<string>? status)
    {
        _status = status;
        StatusText.Text = status?.Invoke() ?? "";
    }

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
        _incremental.Clear();
        OutputBox.Clear();
        HideError();
        SetStatus(null);
        _detected = null;
        UpdateDetectLabel();
        ShowTarget(_preferredTarget);
        UpdateOutputChrome();
    }

    private void SetBusy(bool busy)
    {
        if (busy)
        {
            LoadingTrack.Visibility = Visibility.Visible;
            double width = Math.Max(OutputPane.ActualWidth, 200);
            var sweep = new DoubleAnimation(-140, width, TimeSpan.FromSeconds(1.1)) { RepeatBehavior = RepeatBehavior.Forever };
            LoadingShift.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, sweep);
        }
        else
        {
            LoadingShift.BeginAnimation(System.Windows.Media.TranslateTransform.XProperty, null);
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
        CharCountText.Text = empty ? "" : Loc.T($"{length:N0} 字符", length == 1 ? "1 character" : $"{length:N0} characters");
    }

    // ---------------- languages ----------------

    private void SourceLangBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingLanguages || SourceLangBox.SelectedItem is not LanguageOption option)
            return;
        _source = option.Language;
        _settings.SourceLanguage = _source?.Code ?? Languages.AutoCode;
        UpdateDetectLabel();
        _ = TranslateAsync(force: false);
    }

    private void TargetLangBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingLanguages || TargetLangBox.SelectedItem is not LanguageOption { Language: { } language })
            return;
        _preferredTarget = language;
        _settings.TargetLanguage = language.Code;
        _ = TranslateAsync(force: false);
    }

    private void SwapButton_Click(object sender, RoutedEventArgs e)
    {
        string text = SourceBox.Text;
        Language from = _source ?? LanguageDetector.Detect(text) ?? Languages.FallbackFor(_target);
        Language to = _target;
        _source = to;
        _preferredTarget = from;
        _target = from;
        _settings.SourceLanguage = to.Code;
        _settings.TargetLanguage = from.Code;
        UpdateDetectLabel();
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
        SourceLangBox.SelectedItem = _source is null ? _detectOption : _sourceOptions.First(option => option.Language == _source);
        TargetLangBox.SelectedItem = _targetOptions.First(option => option.Language == _target);
        _syncingLanguages = false;
    }

    private void ShowTarget(Language target)
    {
        _target = target;
        _syncingLanguages = true;
        TargetLangBox.SelectedItem = _targetOptions.First(option => option.Language == target);
        _syncingLanguages = false;
    }

    /// <summary>With automatic detection, the "detect" entry shows what it found, e.g. "English (detected)".</summary>
    private void UpdateDetectLabel() =>
        _detectOption.DisplayName = _source is null && _detected is { } found
            ? Loc.T($"{found.LocalName}（检测到）", $"{found.LocalName} (detected)")
            : DetectLabel;

    // ---------------- history ----------------

    private bool IsHistoryOpen => HistoryOverlay.Visibility == Visibility.Visible;

    private void SetHistoryOpen(bool open)
    {
        if (IsHistoryOpen == open)
            return;
        HistoryOverlay.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        HistoryButton.IsChecked = open;
        if (open)
        {
            UpdateHistoryChrome();
            HistorySearchBox.Focus();
        }
    }

    // Checked/Unchecked rather than Click, so screen readers and other UI Automation clients can open the panel too.
    private void HistoryButton_Checked(object sender, RoutedEventArgs e) => SetHistoryOpen(true);

    private void HistoryButton_Unchecked(object sender, RoutedEventArgs e) => SetHistoryOpen(false);

    private void CloseHistoryButton_Click(object sender, RoutedEventArgs e) => SetHistoryOpen(false);

    private void HistoryBackdrop_MouseLeftButtonDown(object sender, MouseButtonEventArgs e) => SetHistoryOpen(false);

    private bool MatchesHistorySearch(object item)
    {
        string query = HistorySearchBox.Text.Trim();
        return query.Length == 0 || (item is HistoryEntry entry
            && (entry.SourceText.Contains(query, StringComparison.OrdinalIgnoreCase)
                || entry.TranslatedText.Contains(query, StringComparison.OrdinalIgnoreCase)));
    }

    private void HistorySearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        HistorySearchPlaceholder.Visibility = HistorySearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _historyView.Refresh();
        UpdateHistoryChrome();
    }

    private void UpdateHistoryChrome()
    {
        int total = _history.Entries.Count;
        HistoryCountText.Text = total > 0 ? Loc.T($"共 {total} 条", total == 1 ? "1 entry" : $"{total} entries") : "";
        ClearHistoryButton.Visibility = total > 0 ? Visibility.Visible : Visibility.Collapsed;
        HistoryEmptyText.Text = total > 0 ? Loc.T("没有找到匹配的记录", "No matching entries")
            : _settings.SaveHistory ? Loc.T("还没有翻译记录", "No translations yet")
            : Loc.T("翻译历史已在设置中关闭", "History is turned off in Settings");
        HistoryEmptyText.Visibility = _historyView.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void HistoryItem_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (sender is ListBoxItem { DataContext: HistoryEntry entry })
            RestoreFromHistory(entry);
    }

    private void HistoryItem_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && sender is ListBoxItem { DataContext: HistoryEntry entry })
        {
            e.Handled = true;
            RestoreFromHistory(entry);
        }
    }

    private void DeleteHistoryItem_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is FrameworkElement { Tag: HistoryEntry entry })
            _history.Remove(entry);
    }

    private void ClearHistoryButton_Click(object sender, RoutedEventArgs e)
    {
        if (MessageDialog.Confirm(this, Loc.T("清空翻译历史", "Clear history"),
                Loc.T("确定要清空全部翻译历史吗？此操作无法撤销。", "Delete all history entries? This can’t be undone."),
                Loc.T("清空", "Clear all"), danger: true))
            _history.Clear();
    }

    /// <summary>Shows a past translation without calling the API; editing it afterwards translates incrementally.</summary>
    private void RestoreFromHistory(HistoryEntry entry)
    {
        CancelTranslation();
        _debounce.Stop();
        _restoringHistory = true;
        SourceBox.Text = entry.SourceText;
        _restoringHistory = false;
        UpdateSourceChrome();

        Language target = Languages.Find(entry.TargetLanguage) ?? _preferredTarget;
        // Keep the user's pick when it already leads to this entry's language (e.g. the Chinese→English fallback);
        // otherwise adopt the entry's target, so the drop-down and any later edits agree with what is on screen.
        if (ResolveLanguages(entry.SourceText).Target != target)
        {
            _preferredTarget = target;
            _settings.TargetLanguage = target.Code;
        }
        _detected = _source ?? LanguageDetector.Detect(entry.SourceText);
        UpdateDetectLabel();
        ShowTarget(target);

        HideError();
        OutputBox.Text = entry.TranslatedText;
        UpdateOutputChrome();
        SetStatus(() => Loc.T($"来自翻译历史 · {entry.TimeText}", $"From history · {entry.TimeText}"));

        string contextKey = BuildContextKey(_source, target, _settings.ActivePreset, _settings.Active);
        _lastRequestKey = contextKey + '\u001F' + entry.SourceText;
        _incremental.Commit(contextKey, IncrementalPlan.Full(entry.SourceText), entry.TranslatedText);

        SetHistoryOpen(false);
        SourceBox.Focus();
        SourceBox.CaretIndex = SourceBox.Text.Length;
    }

    // ---------------- interface language ----------------

    private void OnInterfaceLanguageChanged()
    {
        foreach (var option in _sourceOptions.Concat(_targetOptions))
        {
            if (option.Language is { } language)
                option.DisplayName = language.LocalName;
        }
        UpdateDetectLabel();
        RefreshSettingsDisplay();
        UpdateSourceChrome();
        UpdatePinIcon();
        UpdateCopyButton();
        UpdateUpdateButton();
        _historyView.Refresh(); // time and language labels of the entries
        UpdateHistoryChrome();
        StatusText.Text = _status?.Invoke() ?? "";
    }

    // ---------------- UI events ----------------

    private void SourceBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        UpdateSourceChrome();
        if (_restoringHistory)
            return;
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
        _copied = true;
        UpdateCopyButton();
        await Task.Delay(1500);
        if (version != _copyFeedbackVersion)
            return;
        _copied = false;
        UpdateCopyButton();
    }

    private void UpdateCopyButton()
    {
        CopyButton.Content = _copied ? "" : ""; // check mark / copy
        CopyButton.ToolTip = _copied ? Loc.T("已复制", "Copied") : Loc.T("复制译文", "Copy translation");
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
        PinButton.Content = Topmost ? "" : ""; // pinned / pin
        PinButton.ToolTip = Topmost ? Loc.T("取消置顶", "Unpin") : Loc.T("窗口置顶", "Keep on top");
    }

    private void UpdateUpdateButton()
    {
        if (_availableUpdate is not { } release)
            return;
        UpdateButton.Content = Loc.T($"新版本 {release.VersionText}", $"Update {release.VersionText}");
        UpdateButton.ToolTip = Loc.T("点击查看更新内容并升级", "See what’s new and update");
    }

    private void UpdateButton_Click(object sender, RoutedEventArgs e)
    {
        if (_availableUpdate is { } release)
            App.ShowUpdateDialog(release, this);
    }

    private void GlossaryButton_Click(object sender, RoutedEventArgs e) => App.OpenGlossary(this);

    private void SettingsButton_Click(object sender, RoutedEventArgs e) => App.OpenSettings();

    private void EngineStatus_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => App.OpenSettings();

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control)
        {
            e.Handled = true;
            _ = TranslateAsync(force: true);
        }
        else if (e.Key == Key.H && Keyboard.Modifiers == ModifierKeys.Control)
        {
            e.Handled = true;
            SetHistoryOpen(!IsHistoryOpen);
        }
        else if (e.Key == Key.Escape && !SourceLangBox.IsDropDownOpen && !TargetLangBox.IsDropDownOpen)
        {
            e.Handled = true;
            if (IsHistoryOpen)
                SetHistoryOpen(false);
            else
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
