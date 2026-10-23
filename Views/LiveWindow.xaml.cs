using System.ComponentModel;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using Translator.Core;
using Translator.Platform;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace Translator.Views;

/// <summary>
/// Live transcription: listens to the microphone and/or the PC's sound, shows each sentence as it is recognized
/// (grey while it may still change) and its translation underneath. Closing the window stops listening and frees the
/// devices and the model; the transcript stays until the app exits or it is cleared.
/// </summary>
public partial class LiveWindow : Window
{
    private static readonly TimeSpan DraftDelay = TimeSpan.FromMilliseconds(700);

    private readonly AppSettings _settings;
    private readonly Glossary _glossary;
    private readonly LiveTranscript _transcript = new();
    private readonly TranslationClient _client = new();
    private readonly LiveTranslationContext _context = new();
    private readonly Queue<TranscriptLine> _translationQueue = new();
    private readonly System.Windows.Threading.DispatcherTimer _draftTimer = new() { Interval = DraftDelay };
    private readonly SilenceWatch _micWatch = new();
    private readonly List<ChoiceOption> _sourceOptions =
    [
        new(LiveSettings.SourceMicrophone, new LocText("麦克风", "Microphone")),
        new(LiveSettings.SourceSystem, new LocText("电脑播放的声音", "PC sound")),
        new(LiveSettings.SourceBoth, new LocText("麦克风 + 电脑声音", "Microphone + PC sound")),
    ];
    private readonly LanguageOption _autoOption = new(null, AutoLabel);
    private readonly List<LanguageOption> _sourceLanguages;
    private readonly List<LanguageOption> _targetLanguages;
    private readonly List<ChoiceOption> _downloadSources;
    private List<ChoiceOption> _microphones = [];

    private LiveState _state = LiveState.Idle;
    private LiveTranscriber? _transcriber;
    private int _session;
    private bool _translating;
    private TranscriptLine? _draftLine;
    private string? _draftedText;
    private CancellationTokenSource? _draft;
    private CancellationTokenSource? _download;
    private CaptionWindow? _captions;
    private ScrollViewer? _scroller;
    private bool _followLatest = true;
    private bool _loading = true;
    private Func<string>? _status;
    private BannerKind _banner;
    private Func<string>? _bannerText;
    private bool _gpuOfferDismissed;
    private TranscriptLine? _menuLine;

    private enum LiveState { Idle, Downloading, Loading, Running, Paused }

    private enum BannerKind { None, Info, Download, GpuOffer, Error, Settings, MicrophonePrivacy, MicrophoneSilent, VisualCpp }

    internal LiveWindow(AppSettings settings, Glossary glossary)
    {
        _settings = settings;
        _glossary = glossary;
        InitializeComponent();

        _sourceLanguages = [_autoOption, .. Languages.All.Select(language => new LanguageOption(language))];
        _targetLanguages = Languages.All.Select(language => new LanguageOption(language)).ToList();
        _downloadSources = WhisperModels.Sources.Select(source => new ChoiceOption(source.Id, source.Name)).ToList();
        SourceBox.ItemsSource = _sourceOptions;
        SourceLanguageBox.ItemsSource = _sourceLanguages;
        TargetLanguageBox.ItemsSource = _targetLanguages;
        DownloadSourceBox.ItemsSource = _downloadSources;
        TranscriptList.ItemsSource = _transcript.Lines;

        var live = settings.Live;
        SourceBox.SelectedItem = _sourceOptions.First(option => option.Id == live.AudioSource);
        SourceLanguageBox.SelectedItem = _sourceLanguages.FirstOrDefault(option => option.Language?.Code == live.SourceLanguage) ?? _autoOption;
        TargetLanguageBox.SelectedItem = _targetLanguages.FirstOrDefault(option => option.Language?.Code == live.TargetLanguage) ?? _targetLanguages[0];
        PartialToggle.IsChecked = live.TranslatePartials;
        CaptionsToggle.IsChecked = live.ShowCaptions;
        RefreshMicrophones();
        MicrophoneBox.DropDownOpened += (_, _) => RefreshMicrophones();

        _draftTimer.Tick += (_, _) => TranslateDraft();
        _transcript.Lines.CollectionChanged += (_, _) => UpdateEmptyText();
        TranscriptList.Loaded += (_, _) => AttachScroller();
        ThemeManager.Track(this, "SurfaceBrush");
        SourceInitialized += (_, _) =>
        {
            if (live.Bounds is not { } saved || !WindowUtil.TryRestorePlacement(this, saved))
                CenterOnWorkArea();
        };
        Closing += OnClosing;
        Loc.Changed += OnInterfaceLanguageChanged;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && !new[] { SourceBox, MicrophoneBox, SourceLanguageBox, TargetLanguageBox, DownloadSourceBox }.Any(box => box.IsDropDownOpen))
            {
                e.Handled = true;
                Close();
            }
        };

        _loading = false;
        UpdateSourceChrome();
        UpdateControls();
        UpdateEmptyText();
        SetStatus(null);
    }

    private static App App => (App)Application.Current;

    private static string AutoLabel => Loc.T("自动检测语言", "Detect language");

    public bool IsRunning => _state is LiveState.Running or LiveState.Loading or LiveState.Downloading;

    // ---------------- called by App ----------------

    public void BringToFront() => WindowUtil.ForceForeground(this);

    /// <summary>The global hotkey: starts listening (or resumes after a pause), or stops when already listening.</summary>
    public void ToggleRunning()
    {
        if (IsRunning)
            Stop();
        else if (_state == LiveState.Paused)
            Resume();
        else
            _ = StartAsync();
    }

    // ---------------- start / pause / stop ----------------

    private async void StartButton_Click(object sender, RoutedEventArgs e)
    {
        if (_state == LiveState.Paused)
            Resume();
        else if (_state == LiveState.Idle)
            await StartAsync();
    }

    private void PauseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_state != LiveState.Running || _transcriber is null)
            return;
        _transcriber.StopCapture();
        _state = LiveState.Paused;
        SetStatus(() => Loc.T("已暂停", "Paused"));
        UpdateControls();
    }

    private void StopButton_Click(object sender, RoutedEventArgs e) => Stop();

    /// <summary>
    /// Checks the model and the engine, loads them and starts listening. Never throws: whatever goes wrong ends with a
    /// banner and the window ready to start again.
    /// </summary>
    private async Task StartAsync()
    {
        if (_state != LiveState.Idle)
            return;
        int session = ++_session;
        try
        {
            await StartSessionAsync(session);
        }
        catch (Exception ex)
        {
            Log.Error("无法开始实时转录", ex);
            if (session != _session)
                return;
            _transcriber?.Dispose();
            _transcriber = null;
            _state = LiveState.Idle;
            UpdateControls();
            SetStatus(null);
            ShowBanner(BannerKind.Error, () => Loc.T($"无法开始实时转录：{ex.Message}", $"Couldn’t start live transcription: {ex.Message}"));
        }
    }

    // Stop() moves _session on, so every await is followed by a check that this start is still wanted.
    private async Task StartSessionAsync(int session)
    {
        HideBanner();
        var model = WhisperModels.Find(_settings.Live.Model);
        Language? source = SelectedSourceLanguage;
        Log.Info($"实时转录：开始（音源 {_settings.Live.AudioSource}，语言 {source?.Code ?? Languages.AutoCode}，模型 {model.Id}，"
            + $"GPU 加速{(_settings.Live.UseGpu ? "开" : "关")}）");
        if (!WhisperModels.IsDownloaded(model))
        {
            _state = LiveState.Loading;
            UpdateControls();
            SetStatus(() => Loc.T("正在检查语音模型…", "Checking the speech model…"));
            bool ready = await WhisperModels.VerifyAsync(model, CancellationToken.None);
            if (session != _session)
                return; // stopped meanwhile
            _state = LiveState.Idle;
            UpdateControls();
            SetStatus(null);
            if (!ready)
            {
                ShowDownloadBanner(model);
                return;
            }
        }
        if (WhisperRuntime.LoadFailed)
        {
            ShowRestartBanner();
            return;
        }
        if (WhisperRuntime.Loaded is null && WhisperRuntime.CheckVisualCppRuntime() is { } problem)
        {
            ShowBanner(BannerKind.VisualCpp,
                () => Loc.T($"语音识别引擎需要微软的 Visual C++ 运行库 14.40 或更新的版本（{problem}）。请下载安装（约 25 MB）后再点“开始”。",
                    $"The speech recognition engine needs Microsoft’s Visual C++ runtime 14.40 or later ({problem}). Install it (about 25 MB), then click Start again."),
                () => Loc.T("下载 Visual C++ 运行库", "Download the Visual C++ runtime"));
            return;
        }
        if (_settings.Live.UseGpu && !_gpuOfferDismissed && WhisperRuntime.CanUseGpu && !WhisperRuntime.IsGpuInstalled
            && WhisperRuntime.Loaded is null)
        {
            ShowGpuOffer();
            return;
        }

        _state = LiveState.Loading;
        UpdateControls();
        SetStatus(() => Loc.T($"正在加载语音模型 {model.DisplayName}…", $"Loading the speech model {model.DisplayName}…"));
        var transcriber = new LiveTranscriber(SynchronizationContext.Current!);
        try
        {
            bool useGpu = _settings.Live.UseGpu;
            await Task.Run(() => transcriber.Load(model, source, useGpu));
        }
        catch (Exception ex)
        {
            transcriber.Dispose();
            if (session != _session || ex is OperationCanceledException)
                return; // stopped while loading
            Log.Error("加载语音模型失败", ex);
            await ShowLoadErrorAsync(model, ex, session);
            return;
        }
        if (session != _session || _state != LiveState.Loading)
        {
            transcriber.Dispose();
            return;
        }

        _transcriber = transcriber;
        _transcript.BeginSession();
        _context.Clear();
        transcriber.Partial += (utterance, text, start) =>
        {
            if (session == _session)
                OnPartial(utterance, text, start);
        };
        transcriber.Final += (utterance, text, start, end, language) =>
        {
            if (session == _session)
                OnFinal(utterance, text, start, end, language);
        };
        transcriber.Discarded += utterance =>
        {
            if (session == _session)
                _transcript.Discard(utterance);
        };
        transcriber.Levels += (mic, system) =>
        {
            if (transcriber != _transcriber)
                return;
            MicLevel.Value = mic;
            SystemLevel.Value = system;
            WatchMicrophone(mic);
        };
        transcriber.Failed += message =>
        {
            if (transcriber == _transcriber)
                ShowBanner(BannerKind.Error, () => message);
        };
        Resume();
    }

    /// <summary>
    /// Explains why the engine or the model didn't load. Only a model file that fails its checksum is offered for
    /// download again: too little memory, or a GPU that can't take the model, would fail the same way after a new download.
    /// </summary>
    private async Task ShowLoadErrorAsync(WhisperModelInfo model, Exception error, int session)
    {
        if (error is WhisperModelLoadException)
        {
            SetStatus(() => Loc.T("正在检查语音模型…", "Checking the speech model…"));
            bool intact = await WhisperModels.VerifyAsync(model, CancellationToken.None, recheck: true);
            if (session != _session)
                return;
            _state = LiveState.Idle;
            UpdateControls();
            SetStatus(null);
            if (!intact)
            {
                ShowDownloadBanner(model);
                ShowBannerError(() => Loc.T($"语音模型 {model.DisplayName} 的文件已损坏，已经删除，请重新下载。",
                    $"The file of the speech model {model.DisplayName} was damaged and has been deleted. Please download it again."));
                return;
            }
            bool gpu = WhisperRuntime.Loaded == RuntimeLibrary.Vulkan;
            ShowBanner(BannerKind.Settings, () => gpu
                    ? Loc.T($"语音模型 {model.DisplayName} 的文件完好，但识别引擎无法加载它（{error.Message}），可能是内存或显存不够。可以在设置里换一个更小的模型，或者关闭 GPU 加速后重新打开轻译。",
                        $"The speech model {model.DisplayName} is intact, but the engine couldn’t load it ({error.Message}); there may not be enough memory or graphics memory. Pick a smaller model in Settings, or turn GPU acceleration off and restart QingYi.")
                    : Loc.T($"语音模型 {model.DisplayName} 的文件完好，但识别引擎无法加载它（{error.Message}），可能是内存不够。可以关掉一些程序再试，或者在设置里换一个更小的模型。",
                        $"The speech model {model.DisplayName} is intact, but the engine couldn’t load it ({error.Message}); there may not be enough memory. Close some programs and try again, or pick a smaller model in Settings."),
                () => Loc.T("打开设置", "Open settings"));
            return;
        }
        _state = LiveState.Idle;
        UpdateControls();
        SetStatus(null);
        if (error is WhisperRuntimeException)
            ShowRestartBanner();
        else
            ShowBanner(BannerKind.Error, () => Loc.T($"无法启动语音识别引擎：{error.Message}", $"Couldn’t start the speech recognition engine: {error.Message}"));
    }

    // Whisper.net remembers a failed load of its native library for the rest of the process.
    private void ShowRestartBanner()
    {
        ShowBanner(BannerKind.Error,
            () => Loc.T("语音识别引擎没能加载，要重新打开轻译后才能再试：请从托盘图标的菜单里选“退出”，再打开轻译（刚装好或更新了 Visual C++ 运行库时也需要这样）。详细信息已写入日志。",
                "The speech recognition engine couldn’t be loaded and can only be tried again after QingYi restarts: choose Exit in the tray icon’s menu, then open QingYi again (also needed right after installing or updating the Visual C++ runtime). Details were written to the log."));
    }

    private void Resume()
    {
        if (_transcriber is null)
            return;
        try
        {
            _transcriber.StartCapture(_settings.Live.AudioSource, _settings.Live.MicrophoneId);
        }
        catch (AudioCaptureException ex)
        {
            _state = LiveState.Paused;
            UpdateControls();
            SetStatus(() => Loc.T("没有在聆听", "Not listening"));
            ShowBanner(ex.MicrophonePrivacy ? BannerKind.MicrophonePrivacy : BannerKind.Error, () => ex.Message,
                ex.MicrophonePrivacy ? () => Loc.T("打开隐私设置", "Open privacy settings") : null);
            return;
        }
        catch (Exception ex)
        {
            Log.Error("无法开始录音", ex);
            _state = LiveState.Paused;
            UpdateControls();
            SetStatus(() => Loc.T("没有在聆听", "Not listening"));
            ShowBanner(BannerKind.Error, () => Loc.T($"无法开始录音：{ex.Message}", $"Couldn’t start recording: {ex.Message}"));
            return;
        }
        if (_banner is BannerKind.MicrophonePrivacy or BannerKind.MicrophoneSilent or BannerKind.Error)
            HideBanner();
        _micWatch.Reset();
        _state = LiveState.Running;
        UpdateControls();
        string runtime = WhisperRuntime.DescribeLoaded();
        SetStatus(() => Loc.T($"正在聆听 · {WhisperModels.Find(_settings.Live.Model).DisplayName} · {runtime}",
            $"Listening · {WhisperModels.Find(_settings.Live.Model).DisplayName} · {runtime}"));
    }

    // A microphone that has given nothing but silence so far: muted, blocked by the privacy settings (Windows then
    // hands desktop apps silence) or not shared with a virtual machine.
    private void WatchMicrophone(float level)
    {
        bool microphone = _settings.Live.AudioSource is LiveSettings.SourceMicrophone or LiveSettings.SourceBoth;
        if (_state != LiveState.Running || !microphone)
            return;
        if (level > SilenceWatch.Threshold)
        {
            if (_banner == BannerKind.MicrophoneSilent)
                HideBanner();
        }
        if (_micWatch.Update(level, Environment.TickCount64 / 1000.0) && _banner == BannerKind.None)
        {
            ShowBanner(BannerKind.MicrophoneSilent,
                () => Loc.T("麦克风到现在还没有收到声音。如果你已经在说话，请检查：麦克风没有静音，上面选对了设备；“设置 › 隐私和安全性 › 麦克风”中允许了桌面应用使用麦克风（不允许时 Windows 只给静音）；在虚拟机里要先把麦克风共享给虚拟机。",
                    "The microphone hasn’t picked up any sound yet. If you are already speaking, check that it isn’t muted and the right device is picked above; that desktop apps may use the microphone under Settings › Privacy & security › Microphone (otherwise Windows only hands over silence); and, in a virtual machine, that the microphone is shared with it."),
                () => Loc.T("打开隐私设置", "Open privacy settings"), () => Loc.T("关闭", "Dismiss"));
        }
    }

    /// <summary>Releases the devices and the model; the sentence in progress is still finished and translated.</summary>
    private void Stop()
    {
        _download?.Cancel();
        if (_state == LiveState.Loading)
            _session++; // the load in progress is thrown away when it completes
        _transcriber?.Dispose();
        _transcriber = null;
        _state = LiveState.Idle;
        _draftTimer.Stop();
        MicLevel.Value = 0;
        SystemLevel.Value = 0;
        UpdateControls();
        SetStatus(_transcript.Lines.Count > 0 ? () => Loc.T("已停止", "Stopped") : null);
    }

    private void RestartIfRunning()
    {
        if (_state is LiveState.Running or LiveState.Paused)
        {
            Stop();
            _ = StartAsync();
        }
    }

    // ---------------- recognition results ----------------

    private void OnPartial(int utterance, string text, double start)
    {
        if (_transcript.UpdatePartial(utterance, text, start) is not { } line)
            return;
        UpdateCaptions();
        ScrollToLatestIfFollowing();
        if (PartialToggle.IsChecked == true)
        {
            _draftLine = line;
            _draftTimer.Stop();
            _draftTimer.Start();
        }
    }

    private void OnFinal(int utterance, string text, double start, double end, string? language)
    {
        var line = _transcript.Finalize(utterance, text, start, end, language);
        if (line == _draftLine || line is null)
        {
            _draftTimer.Stop();
            _draft?.Cancel();
            _draftLine = null;
        }
        if (line is null)
            return;
        _translationQueue.Enqueue(line);
        UpdateCaptions();
        ScrollToLatestIfFollowing();
        _ = TranslateQueueAsync();
    }

    // ---------------- translation ----------------

    private Language? SelectedSourceLanguage => (SourceLanguageBox.SelectedItem as LanguageOption)?.Language;

    private Language PreferredTarget => (TargetLanguageBox.SelectedItem as LanguageOption)?.Language ?? Languages.SimplifiedChinese;

    /// <summary>Final sentences are translated one after another, each with the previous ones as context.</summary>
    private async Task TranslateQueueAsync()
    {
        if (_translating)
            return;
        _translating = true;
        try
        {
            while (_translationQueue.TryDequeue(out var line))
            {
                if (!_transcript.Lines.Contains(line))
                    continue; // cleared meanwhile
                string? translation = await TranslateAsync(line, draft: false, CancellationToken.None);
                if (translation is { Length: > 0 })
                    _context.Add(line.Text, translation);
            }
        }
        finally
        {
            _translating = false;
        }
    }

    private void TranslateDraft()
    {
        _draftTimer.Stop();
        if (_draftLine is not { IsFinal: false } line || line.Text == _draftedText || line.Text.Length < 4)
            return;
        _draft?.Cancel();
        var cts = new CancellationTokenSource();
        _draft = cts;
        _draftedText = line.Text;
        _ = TranslateAsync(line, draft: true, cts.Token);
    }

    private async Task<string?> TranslateAsync(TranscriptLine line, bool draft, CancellationToken ct)
    {
        string text = line.Text;
        var (promptSource, target) = LiveTranslationContext.ResolveLanguages(text, SelectedSourceLanguage, PreferredTarget);
        var glossary = _settings.GlossaryEnabled ? _glossary.Match(text) : [];
        var request = new TranslationRequest(text, promptSource, target, _context.Turns, glossary);
        var output = new StringBuilder();
        line.IsTranslating = !draft;
        try
        {
            var result = await _client.TranslateAsync(_settings.ActivePreset, _settings.Active,
                LiveTranslationContext.BuildInstructions(_settings.ExtraInstructions), request, delta =>
                {
                    if (draft && line.IsFinal)
                        return; // the final translation takes over
                    output.Append(delta);
                    line.Translation = output.ToString();
                    line.TranslationIsDraft = draft;
                    UpdateCaptions();
                }, ct);
            if (draft && line.IsFinal)
                return null;
            line.Translation = result.Text.Trim();
            line.TranslationIsDraft = draft;
            if (_banner == BannerKind.Settings)
                HideBanner();
            UpdateCaptions();
            ScrollToLatestIfFollowing();
            return result.Text;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (TranslationException ex)
        {
            if (!draft)
                ShowBanner(ex.NeedsSettings ? BannerKind.Settings : BannerKind.Error, () => Loc.T($"翻译失败：{ex.Message}", $"Translation failed: {ex.Message}"),
                    ex.NeedsSettings ? () => Loc.T("打开设置", "Open settings") : null);
            return null;
        }
        catch (Exception ex)
        {
            Log.Error("实时翻译失败", ex);
            return null;
        }
        finally
        {
            if (!draft)
                line.IsTranslating = false;
        }
    }

    // ---------------- model download ----------------

    private void ShowDownloadBanner(WhisperModelInfo model)
    {
        var source = WhisperModels.ResolveSource(_settings.Live.DownloadSource);
        DownloadSourceBox.SelectedItem = _downloadSources.First(option => option.Id == source.Id);
        bool offerGpu = _settings.Live.UseGpu && WhisperRuntime.CanUseGpu && !WhisperRuntime.IsGpuInstalled;
        GpuDownloadToggle.Visibility = offerGpu ? Visibility.Visible : Visibility.Collapsed;
        GpuDownloadToggle.IsChecked = offerGpu;
        GpuDownloadToggle.Content = Loc.T($"同时下载 GPU 加速组件（约 {WhisperRuntime.GpuDownloadMegabytes} MB）",
            $"Also download GPU acceleration (about {WhisperRuntime.GpuDownloadMegabytes} MB)");
        ShowBanner(BannerKind.Download,
            () => Loc.T($"第一次使用需要下载语音识别模型 {model.DisplayName}（约 {model.Megabytes} MB），之后在本机离线识别，声音不会上传。可以在设置里换成更小或更准的模型。",
                $"The speech model {model.DisplayName} (about {model.Megabytes} MB) is downloaded once; recognition then runs offline on this PC and no audio is uploaded. You can pick a smaller or more accurate model in Settings."),
            () => Loc.T("下载", "Download"));
        DownloadOptions.Visibility = Visibility.Visible;
    }

    private void ShowGpuOffer()
    {
        ShowBanner(BannerKind.GpuOffer,
            () => Loc.T($"检测到支持 Vulkan 的显卡。下载 GPU 加速组件（约 {WhisperRuntime.GpuDownloadMegabytes} MB）后识别更快，也能用更准的大模型。",
                $"A Vulkan-capable graphics card was found. With GPU acceleration (about {WhisperRuntime.GpuDownloadMegabytes} MB to download) recognition is faster and the larger models become usable."),
            () => Loc.T("下载", "Download"), () => Loc.T("不用，只用 CPU", "No, use the CPU"));
    }

    private async Task DownloadAsync(bool model, bool gpu)
    {
        var info = WhisperModels.Find(_settings.Live.Model);
        model = model && !WhisperModels.IsDownloaded(info); // e.g. a retry after only the GPU part failed
        string sourceId = (DownloadSourceBox.SelectedItem as ChoiceOption)?.Id ?? WhisperModels.ResolveSource(_settings.Live.DownloadSource).Id;
        var source = WhisperModels.ResolveSource(sourceId);
        if (model && sourceId != WhisperModels.ResolveSource(_settings.Live.DownloadSource).Id)
        {
            _settings.Live.DownloadSource = sourceId;
            _settings.Save();
        }

        var cts = new CancellationTokenSource();
        _download = cts;
        _state = LiveState.Downloading;
        UpdateControls();
        DownloadOptions.Visibility = Visibility.Collapsed;
        BannerProgress.Visibility = Visibility.Visible;
        BannerProgress.Value = 0;
        BannerButton.Content = Loc.T("取消", "Cancel");
        BannerLinkButton.Visibility = Visibility.Collapsed;
        try
        {
            if (model)
            {
                string name = info.DisplayName;
                await WhisperModels.DownloadAsync(info, source, new Progress<DownloadProgress>(p => ShowProgress(p, name)), cts.Token);
            }
            if (gpu)
                await WhisperRuntime.DownloadGpuAsync(source.Id == WhisperModels.MirrorId,
                    new Progress<DownloadProgress>(p => ShowProgress(p, Loc.T("GPU 加速组件", "GPU acceleration"))), cts.Token);
        }
        catch (OperationCanceledException)
        {
            _state = LiveState.Idle;
            UpdateControls();
            HideBanner();
            SetStatus(() => Loc.T("已取消下载，下次会从断点继续", "Download cancelled; it will resume next time"));
            return;
        }
        catch (Exception ex) when (ex is DownloadException or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Log.Error("下载失败", ex);
            _state = LiveState.Idle;
            UpdateControls();
            if (!WhisperModels.IsDownloaded(info))
                ShowDownloadBanner(info);
            else
                ShowGpuOffer();
            ShowBannerError(() => ex.Message);
            BannerButton.Content = Loc.T("重试", "Retry");
            return;
        }
        finally
        {
            if (_download == cts)
                _download = null;
            cts.Dispose();
        }

        _state = LiveState.Idle;
        HideBanner();
        _gpuOfferDismissed = true;
        await StartAsync();
        // Only once listening: a banner about why it didn't start matters more.
        if (gpu && WhisperRuntime.Loaded is not RuntimeLibrary.Vulkan && _state is LiveState.Running or LiveState.Paused && _banner == BannerKind.None)
            ShowBanner(BannerKind.Info, () => Loc.T("GPU 加速组件已下载，重新打开轻译后生效。", "GPU acceleration was downloaded; it takes effect after QingYi restarts."));
    }

    private void ShowProgress(DownloadProgress progress, string what)
    {
        BannerProgress.Value = progress.Fraction;
        string done = $"{progress.Received / 1048576.0:0} / {progress.Total / 1048576.0:0} MB";
        _bannerText = progress.Verifying
            ? () => Loc.T($"正在校验 {what}…", $"Verifying {what}…")
            : () => Loc.T($"正在下载 {what}… {done}", $"Downloading {what}… {done}");
        BannerText.Text = _bannerText();
        SetStatus(() => Loc.T("正在下载…", "Downloading…"));
    }

    // ---------------- banner ----------------

    private void ShowBanner(BannerKind kind, Func<string> text, Func<string>? button = null, Func<string>? link = null)
    {
        _banner = kind;
        _bannerText = text;
        BannerText.Text = text();
        Log.Info($"实时转录横幅：{kind}：{BannerText.Text}");
        Banner.SetResourceReference(Border.BackgroundProperty, kind is BannerKind.Error or BannerKind.Settings or BannerKind.MicrophonePrivacy or BannerKind.VisualCpp
            ? "ErrorSoftBrush" : "AccentSoftBrush");
        BannerButton.Content = button?.Invoke() ?? Loc.T("关闭", "Dismiss");
        BannerButton.Tag = button;
        BannerLinkButton.Content = link?.Invoke();
        BannerLinkButton.Tag = link;
        BannerLinkButton.Visibility = link is null ? Visibility.Collapsed : Visibility.Visible;
        DownloadOptions.Visibility = Visibility.Collapsed;
        BannerProgress.Visibility = Visibility.Collapsed;
        Banner.Visibility = Visibility.Visible;
    }

    // Keeps the banner's buttons but shows what went wrong.
    private void ShowBannerError(Func<string> text)
    {
        _bannerText = text;
        BannerText.Text = text();
        Log.Info($"实时转录横幅：{_banner}：{BannerText.Text}");
        Banner.SetResourceReference(Border.BackgroundProperty, "ErrorSoftBrush");
    }

    private void HideBanner()
    {
        _banner = BannerKind.None;
        _bannerText = null;
        Banner.Visibility = Visibility.Collapsed;
    }

    private async void BannerButton_Click(object sender, RoutedEventArgs e)
    {
        if (_state == LiveState.Downloading)
        {
            _download?.Cancel();
            return;
        }
        switch (_banner)
        {
            case BannerKind.Download:
                await DownloadAsync(model: true, gpu: GpuDownloadToggle.Visibility == Visibility.Visible && GpuDownloadToggle.IsChecked == true);
                break;
            case BannerKind.GpuOffer:
                await DownloadAsync(model: false, gpu: true);
                break;
            case BannerKind.Settings:
                HideBanner();
                App.OpenSettings();
                break;
            case BannerKind.MicrophonePrivacy or BannerKind.MicrophoneSilent:
                App.OpenUrl("ms-settings:privacy-microphone");
                break;
            case BannerKind.VisualCpp:
                App.OpenUrl(WhisperRuntime.VisualCppDownloadUrl);
                HideBanner();
                break;
            default:
                HideBanner();
                break;
        }
    }

    private async void BannerLinkButton_Click(object sender, RoutedEventArgs e)
    {
        if (_banner == BannerKind.MicrophoneSilent)
        {
            HideBanner();
        }
        else if (_banner == BannerKind.GpuOffer)
        {
            // Not asked again; GPU acceleration can be turned back on in Settings.
            _settings.Live.UseGpu = false;
            _settings.Save();
            HideBanner();
            await StartAsync();
        }
    }

    // ---------------- sources and languages ----------------

    private void RefreshMicrophones()
    {
        var devices = AudioCapture.Microphones();
        var options = new List<ChoiceOption> { new("", new LocText("默认麦克风（跟随系统）", "Default microphone")) };
        options.AddRange(devices.Select(device => new ChoiceOption(device.Id, device.Name)));
        string selected = _settings.Live.MicrophoneId ?? "";
        bool wasLoading = _loading;
        _loading = true;
        _microphones = options;
        MicrophoneBox.ItemsSource = options;
        MicrophoneBox.SelectedItem = options.FirstOrDefault(option => option.Id == selected) ?? options[0];
        _loading = wasLoading;
    }

    private void SourceBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SourceBox.SelectedItem is not ChoiceOption option)
            return;
        _settings.Live.AudioSource = option.Id;
        _settings.Save();
        UpdateSourceChrome();
        if (_state == LiveState.Running)
            Resume(); // reopens the devices
    }

    private void MicrophoneBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || MicrophoneBox.SelectedItem is not ChoiceOption option)
            return;
        _settings.Live.MicrophoneId = option.Id.Length == 0 ? null : option.Id;
        _settings.Save();
        if (_state == LiveState.Running)
            Resume();
    }

    private void SourceLanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || SourceLanguageBox.SelectedItem is not LanguageOption option)
            return;
        _settings.Live.SourceLanguage = option.Language?.Code ?? Languages.AutoCode;
        _settings.Save();
        RestartIfRunning(); // the model is set up for one language (or detection)
    }

    private void TargetLanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || TargetLanguageBox.SelectedItem is not LanguageOption { Language: { } language })
            return;
        _settings.Live.TargetLanguage = language.Code;
        _settings.Save();
        _context.Clear(); // earlier translations are in the old language
    }

    private void UpdateSourceChrome()
    {
        string source = _settings.Live.AudioSource;
        bool microphone = source is LiveSettings.SourceMicrophone or LiveSettings.SourceBoth;
        bool system = source is LiveSettings.SourceSystem or LiveSettings.SourceBoth;
        MicrophoneBox.Visibility = microphone ? Visibility.Visible : Visibility.Collapsed;
        MicLevelPanel.Visibility = microphone ? Visibility.Visible : Visibility.Collapsed;
        SystemLevelPanel.Visibility = system ? Visibility.Visible : Visibility.Collapsed;
    }

    // ---------------- options, export, clear ----------------

    private void PartialToggle_Click(object sender, RoutedEventArgs e)
    {
        _settings.Live.TranslatePartials = PartialToggle.IsChecked == true;
        _settings.Save();
        if (!_settings.Live.TranslatePartials)
        {
            _draftTimer.Stop();
            _draft?.Cancel();
        }
    }

    private void CaptionsToggle_Click(object sender, RoutedEventArgs e)
    {
        _settings.Live.ShowCaptions = CaptionsToggle.IsChecked == true;
        _settings.Save();
        UpdateCaptions();
    }

    /// <summary>Shows the last sentence or two in the floating caption bar.</summary>
    private void UpdateCaptions()
    {
        bool show = _settings.Live.ShowCaptions && IsVisible;
        if (!show)
        {
            _captions?.Hide();
            return;
        }
        if (_captions is null)
        {
            _captions = new CaptionWindow(_settings);
            _captions.CloseRequested += () =>
            {
                CaptionsToggle.IsChecked = false;
                CaptionsToggle_Click(this, new RoutedEventArgs());
            };
        }
        var lines = _transcript.Lines;
        _captions.ShowLines(lines.Count > 1 ? lines[^2] : null, lines.Count > 0 ? lines[^1] : null);
    }

    private void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        ExportMenu.PlacementTarget = ExportButton;
        ExportMenu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        ExportMenu.IsOpen = true;
    }

    private void ExportItem_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuItem { Tag: string tag })
            return;
        string[] parts = tag.Split(' ');
        var format = parts[0] == "srt" ? TranscriptFormat.Srt : TranscriptFormat.Text;
        var content = parts[1] switch
        {
            "original" => TranscriptContent.Original,
            "translation" => TranscriptContent.Translation,
            _ => TranscriptContent.Bilingual,
        };
        string text = TranscriptExport.Build(_transcript.Lines, format, content);
        if (text.Length == 0)
        {
            MessageDialog.Inform(this, Loc.T("没有可以导出的内容", "Nothing to export"),
                content == TranscriptContent.Translation ? Loc.T("还没有翻译好的句子。", "No sentence has been translated yet.")
                    : Loc.T("还没有识别出完整的句子。", "No sentence has been recognized yet."));
            return;
        }
        string extension = format == TranscriptFormat.Srt ? "srt" : "txt";
        var dialog = new SaveFileDialog
        {
            FileName = Loc.T($"实时转录 {DateTime.Now:yyyy-MM-dd HHmm}", $"Transcript {DateTime.Now:yyyy-MM-dd HHmm}") + "." + extension,
            DefaultExt = extension,
            Filter = format == TranscriptFormat.Srt
                ? Loc.T("SRT 字幕 (*.srt)|*.srt", "SRT subtitles (*.srt)|*.srt")
                : Loc.T("文本文件 (*.txt)|*.txt", "Text files (*.txt)|*.txt"),
        };
        if (dialog.ShowDialog(this) != true)
            return;
        try
        {
            File.WriteAllText(dialog.FileName, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Error("导出转录失败", ex);
            MessageDialog.Inform(this, Loc.T("导出失败", "Export failed"), ex.Message);
        }
    }

    private void ClearButton_Click(object sender, RoutedEventArgs e)
    {
        if (_transcript.Lines.Count == 0 || !MessageDialog.Confirm(this, Loc.T("清空转录内容", "Clear the transcript"),
                Loc.T("确定要清空全部原文和译文吗？没有导出的内容将无法找回。", "Delete all sentences and translations? Anything not exported is lost."),
                Loc.T("清空", "Clear"), danger: true))
            return;
        _translationQueue.Clear();
        _draft?.Cancel();
        _draftLine = null;
        _transcript.Clear();
        _transcript.BeginSession();
        _context.Clear();
        UpdateCaptions();
    }

    // The copy menu belongs to the list; it opens for the line under the mouse.
    private void TranscriptList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && ItemsControl.ContainerFromElement(TranscriptList, source) is ListBoxItem { DataContext: TranscriptLine line })
            _menuLine = line;
        else
            e.Handled = true;
    }

    private void CopyLine_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuItem { Tag: string what } || _menuLine is not { } line)
            return;
        string text = what switch
        {
            "original" => line.Text,
            "translation" => line.Translation,
            _ => line.Translation.Length == 0 ? line.Text : line.Text + Environment.NewLine + line.Translation,
        };
        if (text.Length > 0)
            ClipboardUtil.TrySetText(text);
    }

    // ---------------- scrolling ----------------

    private void AttachScroller()
    {
        if (_scroller is not null)
            return;
        _scroller = TranscriptList.Template.FindName("Scroller", TranscriptList) as ScrollViewer;
        if (_scroller is not null)
            _scroller.ScrollChanged += OnScrollChanged;
    }

    // Follows new lines only while the view is at the bottom, so reading back isn't interrupted.
    private void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_scroller is null)
            return;
        if (e.ExtentHeightChange == 0)
            _followLatest = _scroller.VerticalOffset >= _scroller.ScrollableHeight - 4;
        else if (_followLatest)
            _scroller.ScrollToEnd();
        JumpButton.Visibility = _followLatest || _scroller.ScrollableHeight <= 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ScrollToLatestIfFollowing()
    {
        if (_followLatest)
            _scroller?.ScrollToEnd();
    }

    private void JumpButton_Click(object sender, RoutedEventArgs e)
    {
        _followLatest = true;
        _scroller?.ScrollToEnd();
        JumpButton.Visibility = Visibility.Collapsed;
    }

    // ---------------- chrome ----------------

    private void UpdateControls()
    {
        StartButton.Content = _state == LiveState.Paused ? Loc.T("继续", "Resume") : Loc.T("开始", "Start");
        StartButton.IsEnabled = _state is LiveState.Idle or LiveState.Paused;
        PauseButton.IsEnabled = _state == LiveState.Running;
        StopButton.IsEnabled = _state != LiveState.Idle;
        SourceLanguageBox.IsEnabled = _state is not (LiveState.Loading or LiveState.Downloading);
    }

    private void UpdateEmptyText()
    {
        EmptyText.Text = Loc.T("点击“开始”，然后说话或播放视频、网课、会议，原文和译文会实时出现在这里。",
            "Click Start, then speak or play a video, a lecture or a meeting. The original and its translation appear here as they are spoken.");
        EmptyText.Visibility = _transcript.Lines.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SetStatus(Func<string>? status)
    {
        _status = status;
        StatusText.Text = status?.Invoke() ?? "";
    }

    private void OnInterfaceLanguageChanged()
    {
        foreach (var option in _sourceOptions.Concat(_microphones).Concat(_downloadSources))
            option.Refresh();
        foreach (var option in _sourceLanguages.Concat(_targetLanguages))
            option.DisplayName = option.Language?.LocalName ?? AutoLabel;
        UpdateControls();
        UpdateEmptyText();
        StatusText.Text = _status?.Invoke() ?? "";
        if (_bannerText is not null)
            BannerText.Text = _bannerText();
        if (BannerButton.Tag is Func<string> button)
            BannerButton.Content = button();
        if (BannerLinkButton.Tag is Func<string> link)
            BannerLinkButton.Content = link();
    }

    private void CenterOnWorkArea()
    {
        Rect area = SystemParameters.WorkArea;
        Left = area.Left + Math.Max(0, (area.Width - Width) / 2);
        Top = area.Top + Math.Max(0, (area.Height - Height) / 2);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        Stop();
        if (WindowUtil.GetPlacement(this) is { } bounds)
            _settings.Live.Bounds = bounds;
        _settings.Save();
        _captions?.Hide();
        if (App.IsExiting)
            return;
        // Closing only hides the window: the transcript stays for the next time it is opened.
        e.Cancel = true;
        Hide();
    }
}
