using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using Translator.Core;
using Translator.Core.FileTranslation;

namespace Translator.Views;

/// <summary>One term of the review list; entries from the user's glossary are marked.</summary>
public sealed class TermRow(string source, string target, bool fromGlossary) : INotifyPropertyChanged
{
    private string _source = source;
    private string _target = target;

    public string Source
    {
        get => _source;
        set
        {
            _source = value ?? "";
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Source)));
        }
    }

    public string Target
    {
        get => _target;
        set
        {
            _target = value ?? "";
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Target)));
        }
    }

    public bool FromGlossary { get; } = fromGlossary;

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>
/// Translates a whole file: pick or drop it, review the field and terms the model found, follow the progress,
/// then open the translated copy saved next to the original.
/// </summary>
public partial class FileTranslationWindow : Window
{
    private enum Stage { Pick, Loading, Analyzing, Review, Translating, Done, Failed }

    private readonly AppSettings _settings;
    private readonly Glossary _glossary;
    private readonly TranslationClient _client = new();
    private readonly ObservableCollection<TermRow> _terms = [];
    private readonly List<LanguageOption> _targetOptions;

    private Stage _stage;
    private string? _path;
    private TranslatableDocument? _document;
    private FileTranslationJob? _job;
    private Language? _detected;
    private Language _target;
    private List<GlossaryEntry> _userTerms = [];
    private FileTranslationOptions? _options;
    private FileTranslationResult? _result;
    private CancellationTokenSource? _work;
    private bool _syncingTarget;
    private bool _canResume;
    private bool _needsSettings;
    private Func<string>? _heading;   // re-evaluated when the interface language changes
    private Func<string>? _detail;
    private Func<string>? _analysisNote;
    private readonly Stopwatch _watch = new();

    public FileTranslationWindow(AppSettings settings, Glossary glossary)
    {
        _settings = settings;
        _glossary = glossary;
        _target = Languages.Find(settings.TargetLanguage) ?? Languages.SimplifiedChinese;
        InitializeComponent();

        _targetOptions = Languages.All.Select(language => new LanguageOption(language)).ToList();
        TargetBox.ItemsSource = _targetOptions;
        TargetBox.SelectionChanged += TargetBox_SelectionChanged;
        TermsList.ItemsSource = _terms;
        _terms.CollectionChanged += (_, _) => UpdateTermsTitle();

        PreviewDragOver += OnPreviewDragOver;
        PreviewDrop += OnPreviewDrop;
        PreviewKeyDown += OnPreviewKeyDown;
        Closing += OnClosing;
        ThemeManager.Track(this, "SurfaceBrush");
        Loc.Changed += OnInterfaceLanguageChanged;
        Closed += (_, _) =>
        {
            Loc.Changed -= OnInterfaceLanguageChanged;
            _work?.Cancel();
        };
        SetStage(Stage.Pick);
    }

    private bool IsBusy => _stage is Stage.Loading or Stage.Analyzing or Stage.Translating;

    // ---------------- called by App ----------------

    /// <summary>Starts with <paramref name="path"/>; refused (with a message) while another file is being translated.</summary>
    public void OpenFile(string path)
    {
        if (!RefuseWhileTranslating())
            _ = LoadAsync(path);
    }

    /// <summary>Shows the open-file dialog; returns false when the user cancelled it.</summary>
    public bool ChooseFile()
    {
        if (RefuseWhileTranslating())
            return false;
        var dialog = new OpenFileDialog
        {
            Title = Loc.T("选择要翻译的文件", "Choose a file to translate"),
            Filter = DocumentLoader.DialogFilter,
        };
        if (_path is { } current && Path.GetDirectoryName(current) is { Length: > 0 } folder)
            dialog.InitialDirectory = folder;
        if (dialog.ShowDialog(this) != true)
            return false;
        OpenFile(dialog.FileName);
        return true;
    }

    private bool RefuseWhileTranslating()
    {
        if (_stage != Stage.Translating)
            return false;
        MessageDialog.Inform(this, Loc.T("正在翻译另一个文件", "Another file is being translated"),
            Loc.T("请等它完成，或先取消，再翻译新的文件。", "Wait for it to finish, or cancel it, before translating a new file."));
        return true;
    }

    // ---------------- loading and analysis ----------------

    private async Task LoadAsync(string path)
    {
        _work?.Cancel();
        var cts = new CancellationTokenSource();
        _work = cts;
        _path = path;
        _document = null;
        _job = null;
        _result = null;
        _canResume = false;
        ShowFile();
        SetStage(Stage.Loading);
        try
        {
            var document = await Task.Run(() => DocumentLoader.Open(path), cts.Token);
            if (cts != _work)
                return;
            _document = document;
            int concurrency = _settings.ActivePreset.Id == "Ollama" ? 1 : 4; // a local model handles one request at a time
            _job = new FileTranslationJob(document, CallModel, concurrency);
            _detected = _job.DetectSourceLanguage();
            var preferred = Languages.Find(_settings.TargetLanguage) ?? Languages.SimplifiedChinese;
            _target = _detected is not null && _detected.IsSameLanguageAs(preferred) ? Languages.FallbackFor(preferred) : preferred;
            _userTerms = _settings.GlossaryEnabled ? DomainAnalyzer.MatchGlossary(_glossary.Entries, document.Segments) : [];
            ShowFile();
            await AnalyzeAsync();
        }
        catch (OperationCanceledException)
        {
            // Replaced by another file, or the window closed.
        }
        catch (DocumentException ex)
        {
            if (cts == _work)
                Fail(ex.Message, canResume: false);
        }
        catch (Exception ex)
        {
            Log.Error($"读取文件失败：{path}", ex);
            if (cts == _work)
                Fail(Loc.T($"无法读取文件：{ex.Message}", $"Couldn’t read the file: {ex.Message}"), canResume: false);
        }
    }

    /// <summary>Calls the provider selected in the settings at the time of the call.</summary>
    private Task<TranslationResult> CallModel(string system, string user, CancellationToken ct) =>
        _client.TranslateAsync(_settings.ActivePreset, _settings.Active, "", new TranslationRequest(user, null, _target, [], null, system), _ => { }, ct);

    private async Task AnalyzeAsync()
    {
        if (_job is not { } job)
            return;
        var cts = new CancellationTokenSource();
        _work = cts;
        SetStage(Stage.Analyzing);
        var target = _target;
        var answer = Loc.IsEnglish ? Languages.English : Languages.SimplifiedChinese;
        try
        {
            var profile = await Task.Run(() => job.AnalyzeAsync(target, answer, cts.Token));
            if (cts != _work)
                return;
            ShowReview(profile, profile is null
                ? () => Loc.T("没能识别出领域（模型的回答无法解析）。可以自己填写，或直接开始翻译。", "The field couldn’t be identified (the model’s answer was unreadable). Fill it in yourself, or just start.")
                : null);
        }
        catch (OperationCanceledException)
        {
            // Skipped or replaced.
        }
        catch (TranslationException ex) when (cts == _work)
        {
            if (ex.NeedsSettings)
            {
                Fail(ex.Message, canResume: false, needsSettings: true);
                return;
            }
            string message = ex.Message;
            ShowReview(null, () => Loc.T($"领域识别失败：{message}。可以自己填写，或直接开始翻译。", $"Identifying the field failed: {message}. Fill it in yourself, or just start."));
        }
    }

    private void ShowReview(DomainProfile? profile, Func<string>? note)
    {
        DomainBox.Text = profile?.DomainText ?? "";
        StyleBox.Text = profile?.Style ?? "";
        _terms.Clear();
        foreach (var term in DomainAnalyzer.MergeTerms(_userTerms, profile?.Terms ?? []))
            _terms.Add(new TermRow(term.Source, term.Target, term.FromGlossary));
        _analysisNote = note;
        bool hasReferences = _document?.Segments.Any(segment => segment.IsReference) == true;
        SkipReferencesToggle.Visibility = hasReferences ? Visibility.Visible : Visibility.Collapsed;
        BilingualToggle.Visibility = _document?.SupportsBilingual == true ? Visibility.Visible : Visibility.Collapsed;
        SetStage(Stage.Review);
    }

    private void TargetBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingTarget || TargetBox.SelectedItem is not LanguageOption { Language: { } language } || language == _target)
            return;
        _target = language;
        // The detected terms were translated into the old language: ask again for the new one.
        if (_stage == Stage.Review)
            _ = AnalyzeAsync();
    }

    // ---------------- translation ----------------

    private void StartTranslation(bool useProfile)
    {
        if (_document is not { } document)
            return;
        DomainProfile? profile = null;
        List<GlossaryEntry> terms;
        if (useProfile)
        {
            string domain = DomainBox.Text.Trim(), style = StyleBox.Text.Trim();
            if (domain.Length > 0 || style.Length > 0)
                profile = new DomainProfile(domain, "", style, []);
            terms = Glossary.Clean(_terms.Select(row => new GlossaryEntry { Source = row.Source, Target = row.Target }));
        }
        else
        {
            terms = _userTerms;
        }
        _options = new FileTranslationOptions(_target, profile, terms, _settings.ExtraInstructions,
            SkipReferences: SkipReferencesToggle.IsChecked == true || SkipReferencesToggle.Visibility != Visibility.Visible,
            Bilingual: BilingualToggle.IsChecked == true && document.SupportsBilingual);
        _ = TranslateAsync();
    }

    private async Task TranslateAsync()
    {
        if (_job is not { } job || _options is not { } options)
            return;
        var cts = new CancellationTokenSource();
        _work = cts;
        _watch.Restart();
        TranslateBar.Value = 0;
        SetStage(Stage.Translating);
        var progress = new Progress<FileTranslationProgress>(report =>
        {
            if (cts != _work)
                return;
            TranslateBar.Value = report.Total == 0 ? 1 : (double)report.Done / report.Total;
            _detail = () => DescribeProgress(report);
            ResultText.Text = _detail();
        });
        try
        {
            var result = await Task.Run(() => job.TranslateAsync(options, progress, cts.Token));
            if (cts != _work)
                return;
            _result = result;
            SetStage(Stage.Done);
        }
        catch (OperationCanceledException)
        {
            if (cts == _work)
                Fail(Loc.T("已取消。已经翻译的部分会保留，继续翻译时不会重复请求。", "Cancelled. What was already translated is kept and won’t be requested again."), canResume: true, cancelled: true);
        }
        catch (TranslationException ex) when (cts == _work)
        {
            Fail(ex.Message, canResume: true, needsSettings: ex.NeedsSettings);
        }
        catch (DocumentException ex) when (cts == _work)
        {
            Fail(ex.Message, canResume: true);
        }
        catch (Exception ex) when (cts == _work)
        {
            Log.Error("文件翻译失败", ex);
            string message = ex is IOException or UnauthorizedAccessException
                ? Loc.T($"无法保存译文：{ex.Message}", $"Couldn’t save the translation: {ex.Message}")
                : Loc.T($"翻译失败：{ex.Message}", $"Translation failed: {ex.Message}");
            Fail(message, canResume: true);
        }
        finally
        {
            _watch.Stop();
        }
    }

    private string DescribeProgress(FileTranslationProgress report)
    {
        string text = Loc.T($"已翻译 {report.Done:N0} / {report.Total:N0} 段", $"{report.Done:N0} of {report.Total:N0} segments translated");
        var elapsed = _watch.Elapsed;
        if (report.Done > 0 && report.Done < report.Total && elapsed.TotalSeconds > 5)
        {
            var remaining = TimeSpan.FromSeconds(elapsed.TotalSeconds / report.Done * (report.Total - report.Done));
            string minutes = remaining.TotalMinutes < 1 ? Loc.T("不到 1 分钟", "under a minute")
                : Loc.T($"约 {Math.Ceiling(remaining.TotalMinutes):0} 分钟", $"about {Math.Ceiling(remaining.TotalMinutes):0} min");
            text += Loc.T($" · 预计还需{minutes}", $" · {minutes} left");
        }
        return text;
    }

    private void Fail(string message, bool canResume, bool needsSettings = false, bool cancelled = false)
    {
        _canResume = canResume && _job is not null && _options is not null;
        _needsSettings = needsSettings;
        _heading = cancelled ? () => Loc.T("翻译已取消", "Translation cancelled") : () => Loc.T("出了点问题", "Something went wrong");
        _detail = () => message;
        SetStage(Stage.Failed);
    }

    // ---------------- display ----------------

    private void ShowFile()
    {
        FileNameText.Text = _path is null ? Loc.T("还没有选择文件", "No file chosen yet") : Path.GetFileName(_path);
        if (_document is { } document)
        {
            int characters = document.Segments.Sum(segment => segment.PlainText.Length);
            string kind = Path.GetExtension(_path ?? "").ToLowerInvariant() switch
            {
                ".pdf" => "PDF",
                ".docx" or ".docm" => "Word",
                ".pptx" or ".pptm" => "PowerPoint",
                ".xlsx" or ".xlsm" => "Excel",
                ".md" or ".markdown" => "Markdown",
                ".srt" => Loc.T("SRT 字幕", "SRT subtitles"),
                _ => Loc.T("纯文本", "Plain text"),
            };
            int segments = document.Segments.Count;
            FileInfoText.Text = Loc.T($"{kind} · {segments:N0} 段 · 约 {characters:N0} 字符", $"{kind} · {segments:N0} segments · about {characters:N0} characters");
        }
        else
        {
            FileInfoText.Text = _path is null ? "" : Path.GetDirectoryName(_path) ?? "";
        }
        ChangeFileButton.Visibility = _path is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void SetStage(Stage stage)
    {
        _stage = stage;
        PickPanel.Visibility = stage == Stage.Pick ? Visibility.Visible : Visibility.Collapsed;
        BusyPanel.Visibility = stage is Stage.Loading or Stage.Analyzing ? Visibility.Visible : Visibility.Collapsed;
        ReviewPanel.Visibility = stage == Stage.Review ? Visibility.Visible : Visibility.Collapsed;
        ResultPanel.Visibility = stage is Stage.Translating or Stage.Done or Stage.Failed ? Visibility.Visible : Visibility.Collapsed;
        TranslateBar.Visibility = stage == Stage.Translating ? Visibility.Visible : Visibility.Collapsed;
        OpenButtons.Visibility = stage == Stage.Done ? Visibility.Visible : Visibility.Collapsed;
        ChangeFileButton.IsEnabled = stage != Stage.Translating;
        if (stage == Stage.Translating)
        {
            _heading = () => Loc.T("正在翻译…", "Translating…");
            _detail = () => Loc.T("正在准备…", "Getting ready…");
        }
        else if (stage == Stage.Done && _result is { } result)
        {
            _heading = () => Loc.T("翻译完成", "Translation finished");
            _detail = () => Loc.T($"已保存为 {Path.GetFileName(result.OutputPath)}\n位置：{Path.GetDirectoryName(result.OutputPath)}",
                $"Saved as {Path.GetFileName(result.OutputPath)}\nin {Path.GetDirectoryName(result.OutputPath)}");
        }
        if (stage == Stage.Review)
            SyncTargetBox();
        RefreshTexts();
    }

    private void SyncTargetBox()
    {
        _syncingTarget = true;
        TargetBox.SelectedItem = _targetOptions.First(option => option.Language == _target);
        _syncingTarget = false;
    }

    /// <summary>Every text that depends on the stage or on the interface language.</summary>
    private void RefreshTexts()
    {
        ShowFile();
        switch (_stage)
        {
            case Stage.Loading:
                BusyText.Text = Loc.T("正在读取文件…", "Reading the file…");
                BusyHint.Text = Loc.T("大的 PDF 可能需要十几秒。", "A large PDF can take a few seconds.");
                break;
            case Stage.Analyzing:
                BusyText.Text = Loc.T("正在识别文档的领域和术语…", "Identifying the document’s field and terms…");
                BusyHint.Text = Loc.T("会把标题、摘要、各级标题和部分段落发给模型，只请求一次。", "The title, abstract, headings and some paragraphs are sent to the model in one request.");
                break;
        }

        string? detected = _detected is { } language ? language.LocalName : null;
        SourceLanguageText.Text = detected is null ? "" : Loc.T($"原文：{detected}（自动识别）", $"Source: {detected} (detected)");
        AnalysisNote.Text = _analysisNote?.Invoke()
            ?? Loc.T("模型根据文档摘录识别出下面的信息，翻译时会据此选用术语和行文风格。可以直接修改。",
                "The model identified the following from excerpts of the document; the translation follows it. You can edit it.");
        AnalysisNote.SetResourceReference(TextBlock.ForegroundProperty, _analysisNote is null ? "TextTertiaryBrush" : "WarningBrush");
        UpdateTermsTitle();

        ResultIcon.Visibility = _stage is Stage.Done or Stage.Failed ? Visibility.Visible : Visibility.Collapsed;
        ResultIcon.Text = _stage == Stage.Done ? "" : ""; // completed / warning
        ResultIcon.SetResourceReference(TextBlock.ForegroundProperty, _stage == Stage.Done ? "SuccessBrush" : "WarningBrush");
        ResultHeading.Text = _heading?.Invoke() ?? "";
        ResultText.Text = _detail?.Invoke() ?? "";
        var warnings = new List<string>();
        if (_stage == Stage.Done && _result is { } result)
        {
            if (result.Untranslated > 0)
                warnings.Add(Loc.T($"有 {result.Untranslated} 段没能翻译，保留了原文。", $"{result.Untranslated} segment(s) couldn’t be translated and kept the original text."));
            warnings.AddRange(result.Warnings);
            OpenBilingualButton.Visibility = result.BilingualPath is { } bilingual && File.Exists(bilingual) ? Visibility.Visible : Visibility.Collapsed;
        }
        WarningText.Text = string.Join("\n", warnings);
        WarningText.Visibility = warnings.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        // Footer: what the buttons do in this stage.
        (string? secondary, string? primary) = _stage switch
        {
            Stage.Pick => (null, Loc.T("选择文件…", "Choose a file…")),
            Stage.Loading => (Loc.T("取消", "Cancel"), null),
            Stage.Analyzing => (Loc.T("跳过，直接翻译", "Skip and translate"), null),
            Stage.Review => (Loc.T("跳过，直接翻译", "Skip and translate"), Loc.T("开始翻译", "Start translating")),
            Stage.Translating => (Loc.T("取消", "Cancel"), null),
            Stage.Done => (Loc.T("关闭", "Close"), Loc.T("翻译其他文件…", "Translate another file…")),
            Stage.Failed => (_needsSettings ? Loc.T("打开设置", "Open settings") : null,
                _canResume ? Loc.T("继续翻译", "Continue") : Loc.T("选择文件…", "Choose a file…")),
            _ => (null, null),
        };
        SecondaryButton.Content = secondary;
        SecondaryButton.Visibility = secondary is null ? Visibility.Collapsed : Visibility.Visible;
        PrimaryButton.Content = primary;
        PrimaryButton.Visibility = primary is null ? Visibility.Collapsed : Visibility.Visible;
        SecondaryButton.ToolTip = _stage is Stage.Analyzing or Stage.Review
            ? Loc.T("不使用识别出的领域和术语，只按你的术语表翻译", "Ignore the detected field and terms; use only your glossary")
            : null;

        var preset = _settings.ActivePreset;
        FooterText.Text = _stage is Stage.Review or Stage.Translating
            ? Loc.T($"翻译服务：{preset.DisplayName} · {_settings.Active.Model}", $"Service: {preset.DisplayName} · {_settings.Active.Model}")
            : "";
    }

    private void UpdateTermsTitle()
    {
        TermsTitle.Text = Loc.T($"术语（{_terms.Count}）", $"Terms ({_terms.Count})");
        NoTermsText.Visibility = _terms.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnInterfaceLanguageChanged()
    {
        foreach (var option in _targetOptions)
            option.DisplayName = option.Language!.LocalName;
        RefreshTexts();
    }

    // ---------------- events ----------------

    private void PrimaryButton_Click(object sender, RoutedEventArgs e)
    {
        switch (_stage)
        {
            case Stage.Review:
                StartTranslation(useProfile: true);
                break;
            case Stage.Failed when _canResume:
                _ = TranslateAsync();
                break;
            case Stage.Pick or Stage.Done or Stage.Failed:
                ChooseFile();
                break;
        }
    }

    private void SecondaryButton_Click(object sender, RoutedEventArgs e)
    {
        switch (_stage)
        {
            case Stage.Loading:
                _work?.Cancel();
                _path = null;
                _document = null;
                SetStage(Stage.Pick);
                break;
            case Stage.Analyzing or Stage.Review:
                _work?.Cancel();
                StartTranslation(useProfile: false);
                break;
            case Stage.Translating:
                _work?.Cancel();
                break;
            case Stage.Done:
                Close();
                break;
            case Stage.Failed when _needsSettings:
                ((App)Application.Current).OpenSettings();
                break;
        }
    }

    private void ChooseFile_Click(object sender, RoutedEventArgs e) => ChooseFile();

    private void PickPanel_MouseLeftButtonUp(object sender, MouseButtonEventArgs e) => ChooseFile();

    private void AddTerm_Click(object sender, RoutedEventArgs e) => _terms.Add(new TermRow("", "", fromGlossary: false));

    private void DeleteTerm_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: TermRow row })
            _terms.Remove(row);
    }

    private void OpenOutput_Click(object sender, RoutedEventArgs e)
    {
        if (_result is { } result)
            OpenPath(result.OutputPath);
    }

    private void OpenBilingual_Click(object sender, RoutedEventArgs e)
    {
        if (_result?.BilingualPath is { } path)
            OpenPath(path);
    }

    private void ShowInExplorer_Click(object sender, RoutedEventArgs e)
    {
        if (_result is not { } result)
            return;
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{result.OutputPath}\"") { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex)
        {
            Log.Error("无法打开资源管理器", ex);
        }
    }

    private void OpenPath(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex)
        {
            Log.Error($"无法打开 {path}", ex);
            MessageDialog.Inform(this, Loc.T("无法打开文件", "Couldn’t open the file"),
                Loc.T($"可能没有安装能打开它的程序。文件在：{path}", $"There may be no app to open it. The file is at: {path}"));
        }
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.O && Keyboard.Modifiers == ModifierKeys.Control && !IsBusy)
        {
            e.Handled = true;
            ChooseFile();
        }
        else if (e.Key == Key.Escape && !IsBusy && !TargetBox.IsDropDownOpen)
        {
            e.Handled = true;
            Close();
        }
    }

    /// <summary>The first file of a file drop, if any.</summary>
    internal static string? DroppedFile(DragEventArgs e) =>
        e.Data.GetDataPresent(DataFormats.FileDrop) && e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files
            ? files.FirstOrDefault(DocumentLoader.IsSupported) ?? files[0]
            : null;

    private void OnPreviewDragOver(object sender, DragEventArgs e)
    {
        if (DroppedFile(e) is null)
            return;
        e.Effects = _stage == Stage.Translating ? DragDropEffects.None : DragDropEffects.Copy;
        e.Handled = true;
    }

    private void OnPreviewDrop(object sender, DragEventArgs e)
    {
        if (DroppedFile(e) is not { } path)
            return;
        e.Handled = true;
        OpenFile(path);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_stage != Stage.Translating || ((App)Application.Current).IsExiting)
            return;
        if (!MessageDialog.Confirm(this, Loc.T("停止翻译？", "Stop translating?"),
                Loc.T("关闭窗口会取消正在进行的翻译。", "Closing the window cancels the translation in progress."), Loc.T("停止并关闭", "Stop and close"), danger: true))
        {
            e.Cancel = true;
            return;
        }
        _work?.Cancel();
    }
}
