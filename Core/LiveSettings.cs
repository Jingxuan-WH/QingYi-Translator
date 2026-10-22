namespace Translator.Core;

/// <summary>Settings of live transcription, stored in settings.json under "Live".</summary>
public sealed class LiveSettings
{
    public const string SourceMicrophone = "microphone";
    public const string SourceSystem = "system";
    public const string SourceBoth = "both";

    /// <summary>"microphone", "system" (what the PC is playing) or "both".</summary>
    public string AudioSource { get; set; } = SourceMicrophone;

    /// <summary>Endpoint ID of the microphone; null follows the Windows default.</summary>
    public string? MicrophoneId { get; set; }

    /// <summary>"auto" or a language code.</summary>
    public string SourceLanguage { get; set; } = Languages.AutoCode;

    public string TargetLanguage { get; set; } = Languages.SimplifiedChinese.Code;

    /// <summary>Also translate the still-changing partial text (costs more requests).</summary>
    public bool TranslatePartials { get; set; }

    public bool ShowCaptions { get; set; }
    public double CaptionFontSize { get; set; } = 20;
    public WindowBounds? CaptionBounds { get; set; }
    public WindowBounds? Bounds { get; set; }

    public bool HotkeyEnabled { get; set; }
    public string Hotkey { get; set; } = "Ctrl+Alt+L";

    /// <summary>Whisper model id, see <see cref="WhisperModels"/>.</summary>
    public string Model { get; set; } = WhisperModels.DefaultId;

    /// <summary>"" picks by the system language; otherwise a <see cref="WhisperModels.Sources"/> id.</summary>
    public string DownloadSource { get; set; } = "";

    public bool UseGpu { get; set; } = true;

    public const double MinCaptionFontSize = 12;
    public const double MaxCaptionFontSize = 48;

    public void Normalize()
    {
        if (AudioSource is not (SourceSystem or SourceBoth))
            AudioSource = SourceMicrophone;
        if (SourceLanguage != Languages.AutoCode && Languages.Find(SourceLanguage) is null)
            SourceLanguage = Languages.AutoCode;
        if (Languages.Find(TargetLanguage) is null)
            TargetLanguage = Languages.SimplifiedChinese.Code;
        CaptionFontSize = double.IsFinite(CaptionFontSize) ? Math.Clamp(CaptionFontSize, MinCaptionFontSize, MaxCaptionFontSize) : 20;
        Hotkey ??= "";
        Model = WhisperModels.Find(Model).Id;
        DownloadSource ??= "";
        if (DownloadSource.Length > 0 && WhisperModels.Sources.All(source => source.Id != DownloadSource))
            DownloadSource = "";
    }
}
