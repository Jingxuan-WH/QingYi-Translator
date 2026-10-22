using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Translator.Core;
using Translator.Platform;

namespace Translator.Views;

/// <summary>The "Live transcription" section of the settings dialog: model, download source, GPU and hotkey.</summary>
public partial class LiveSettingsPanel : UserControl
{
    private readonly List<ChoiceOption> _models;
    private readonly List<ChoiceOption> _sources;
    private AppSettings _settings = null!;
    private App _app = null!;
    private HotkeyGesture? _hotkey;

    public LiveSettingsPanel()
    {
        InitializeComponent();
        _models = WhisperModels.All.Select(model => new ChoiceOption(model.Id, new LocText(
            $"{model.DisplayName} · 约 {model.Megabytes} MB · {model.Speed.Zh}",
            $"{model.DisplayName} · about {model.Megabytes} MB · {model.Speed.En}"))).ToList();
        _sources =
        [
            new("", new LocText("自动（中文系统用 hf-mirror.com）", "Automatic (hf-mirror.com on Chinese systems)")),
            .. WhisperModels.Sources.Select(source => new ChoiceOption(source.Id, source.Name)),
        ];
        ModelBox.ItemsSource = _models;
        SourceBox.ItemsSource = _sources;
        Loc.Changed += OnInterfaceLanguageChanged;
        Unloaded += (_, _) => Loc.Changed -= OnInterfaceLanguageChanged;
    }

    internal void Load(AppSettings settings, App app)
    {
        _settings = settings;
        _app = app;
        var live = settings.Live;
        ModelBox.SelectedItem = _models.First(option => option.Id == live.Model);
        SourceBox.SelectedItem = _sources.FirstOrDefault(option => option.Id == live.DownloadSource) ?? _sources[0];
        GpuToggle.IsChecked = live.UseGpu;
        HotkeyToggle.IsChecked = live.HotkeyEnabled;
        _hotkey = HotkeyGesture.TryParse(live.Hotkey, out var gesture) ? gesture : null;
        HotkeyBox.Text = _hotkey?.ToString() ?? "";
        RefreshHints();
    }

    /// <summary>False when something still needs attention (the hotkey); the panel then shows why.</summary>
    internal bool Validate()
    {
        if (HotkeyToggle.IsChecked == true && _hotkey is null)
        {
            SetHotkeyStatus(Loc.T("请先设置快捷键，或者关闭这个选项", "Set a hotkey first, or turn this option off"), isError: true);
            HotkeyBox.BringIntoView();
            return false;
        }
        return true;
    }

    internal void Save(AppSettings settings)
    {
        var live = settings.Live;
        live.Model = (ModelBox.SelectedItem as ChoiceOption)?.Id ?? WhisperModels.DefaultId;
        live.DownloadSource = (SourceBox.SelectedItem as ChoiceOption)?.Id ?? "";
        live.UseGpu = GpuToggle.IsChecked == true;
        live.HotkeyEnabled = HotkeyToggle.IsChecked == true;
        live.Hotkey = _hotkey?.ToString() ?? "";
    }

    private void OnInterfaceLanguageChanged()
    {
        foreach (var option in _models.Concat(_sources))
            option.Refresh();
        RefreshHints();
    }

    private void RefreshHints()
    {
        var model = WhisperModels.Find((ModelBox.SelectedItem as ChoiceOption)?.Id);
        ModelHint.Text = WhisperModels.IsDownloaded(model)
            ? Loc.T("已下载。识别完全在本机进行，声音不会上传。", "Downloaded. Recognition runs entirely on this PC; no audio is uploaded.")
            : Loc.T("第一次开始实时转录时下载。识别完全在本机进行，声音不会上传。", "Downloaded the first time you start live transcription. Recognition runs entirely on this PC; no audio is uploaded.");

        bool loadedGpu = WhisperRuntime.Loaded == Whisper.net.LibraryLoader.RuntimeLibrary.Vulkan;
        GpuHint.Text = !WhisperRuntime.HasVulkanDriver
            ? Loc.T("没有检测到支持 Vulkan 的显卡驱动，将使用 CPU。", "No graphics driver with Vulkan support was found; the CPU is used.")
            : WhisperRuntime.IsGpuInstalled
                ? loadedGpu || WhisperRuntime.Loaded is null
                    ? Loc.T("GPU 加速组件已安装。", "GPU acceleration is installed.")
                    : Loc.T("GPU 加速组件已安装，重新打开轻译后生效。", "GPU acceleration is installed and takes effect after QingYi restarts.")
                : Loc.T($"需要先下载 GPU 加速组件（约 {WhisperRuntime.GpuDownloadMegabytes} MB），开始实时转录时会询问。没有独立显卡时 CPU 也能用 base 或 small 模型实时识别。",
                    $"GPU acceleration needs a one-time download (about {WhisperRuntime.GpuDownloadMegabytes} MB); you’re asked when you start live transcription. Without a dedicated GPU, the base and small models still run in real time on the CPU.");
        UpdateHotkeyStatus();
    }

    private void ModelBox_SelectionChanged(object sender, SelectionChangedEventArgs e) => RefreshHints();

    private void GpuToggle_Click(object sender, RoutedEventArgs e) => RefreshHints();

    private void ModelsFolderButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(WhisperModels.Directory);
            Process.Start(new ProcessStartInfo(WhisperModels.Directory) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex)
        {
            Log.Error("无法打开模型文件夹", ex);
        }
    }

    // ---------------- hotkey recording (same as the main hotkey in SettingsWindow) ----------------

    private void HotkeyBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        // Release both registrations so pressing the current hotkeys reaches this box.
        _app.SuspendHotkey();
        _app.SuspendLiveHotkey();
        SetHotkeyStatus(Loc.T("请按下新的组合键（Esc 取消，Backspace 清除）", "Press the new key combination (Esc cancels, Backspace clears)"), isError: false);
    }

    private void HotkeyBox_LostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        _app.ResumeHotkey();
        _app.ResumeLiveHotkey();
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
        else if (HotkeyGesture.TryParse(_settings.Hotkey, out var main) && main == gesture && _settings.HotkeyEnabled)
        {
            SetHotkeyStatus(Loc.T("和取词快捷键相同，请换一个", "This is the hotkey for translating a selection. Please pick another one"), isError: true);
        }
        else if (!_app.IsLiveHotkeyAvailable(gesture))
        {
            SetHotkeyStatus(Loc.T($"{gesture} 已被其他程序占用，请换一个", $"{gesture} is already used by another program. Please pick another one"), isError: true);
        }
        else
        {
            SetHotkeyStatus(Loc.T("在任意程序中按下即可开始实时转录，再按一次停止。", "Press it in any app to start live transcription; press it again to stop."), isError: false);
        }
    }

    private void SetHotkeyStatus(string text, bool isError)
    {
        HotkeyStatus.Text = text;
        HotkeyStatus.SetResourceReference(TextBlock.ForegroundProperty, isError ? "ErrorBrush" : "TextTertiaryBrush");
    }
}
