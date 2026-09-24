using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Translator.Core;

/// <summary>What the user configured for one provider. Request details (temperature, thinking switches) come from its <see cref="ProviderPreset"/>.</summary>
public sealed class ProviderConfig
{
    public string BaseUrl { get; set; } = "";
    public string Model { get; set; } = "";

    /// <summary>API key encrypted with Windows DPAPI (current user), base64.</summary>
    public string? ApiKeyProtected { get; set; }

    [JsonIgnore]
    public string ApiKey
    {
        get => Dpapi.Unprotect(ApiKeyProtected);
        set => ApiKeyProtected = string.IsNullOrWhiteSpace(value) ? null : Dpapi.Protect(value.Trim());
    }

    public static ProviderConfig FromPreset(ProviderPreset preset) => new() { BaseUrl = preset.BaseUrl, Model = preset.DefaultModel };

    public ProviderConfig Clone() => (ProviderConfig)MemberwiseClone();
}

/// <summary>Restored-state window bounds in physical pixels, as reported by GetWindowPlacement.</summary>
public sealed class WindowBounds
{
    public double Left { get; set; }
    public double Top { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public bool Maximized { get; set; }
}

public sealed class AppSettings
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public string ActiveProvider { get; set; } = ProviderCatalog.DeepSeekId;
    public Dictionary<string, ProviderConfig> ProviderConfigs { get; set; } = new();
    public string ExtraInstructions { get; set; } = "";

    /// <summary>"auto" or a language code.</summary>
    public string SourceLanguage { get; set; } = Languages.AutoCode;

    /// <summary>The language the user wants translations in; text already in it goes to <see cref="Languages.FallbackFor"/>.</summary>
    public string TargetLanguage { get; set; } = Languages.SimplifiedChinese.Code;

    public bool IncrementalTranslation { get; set; } = true;
    public bool SaveHistory { get; set; } = true;
    public bool GlossaryEnabled { get; set; } = true;

    /// <summary>Interface language: "system", "zh" or "en".</summary>
    public string UiLanguage { get; set; } = Loc.SystemCode;

    /// <summary>"system", "light" or "dark".</summary>
    public string Theme { get; set; } = ThemeSystem;

    public bool DoubleCopyEnabled { get; set; } = true;
    public bool HotkeyEnabled { get; set; } = true;
    public string Hotkey { get; set; } = "Alt+Q";

    public bool AutoTranslate { get; set; } = true;
    public bool RestoreClipboard { get; set; } = true;
    public bool CloseToTray { get; set; } = true;
    public bool StartWithWindows { get; set; }
    public bool Topmost { get; set; }
    public bool TrayTipShown { get; set; }
    public WindowBounds? MainWindowBounds { get; set; }

    public bool AutoCheckUpdates { get; set; } = true;
    public DateTime? LastUpdateCheck { get; set; }

    /// <summary>Tag of a release the user chose to skip; it is no longer announced.</summary>
    public string? SkippedUpdateVersion { get; set; }

    /// <summary>Tag of the last release announced with a tray notification, so each one is announced only once.</summary>
    public string? NotifiedUpdateVersion { get; set; }

    public const string ThemeSystem = "system";
    public const string ThemeLight = "light";
    public const string ThemeDark = "dark";

    [JsonIgnore]
    public ProviderPreset ActivePreset => ProviderCatalog.Get(ActiveProvider);

    [JsonIgnore]
    public ProviderConfig Active => GetProvider(ActiveProvider);

    public ProviderConfig GetProvider(string id)
    {
        if (!ProviderConfigs.TryGetValue(id, out var config))
        {
            config = ProviderConfig.FromPreset(ProviderCatalog.Get(id));
            ProviderConfigs[id] = config;
        }
        return config;
    }

    // ---------------- persistence ----------------

    /// <summary>%APPDATA%\QingYiTranslator, or TRANSLATOR_DATA_DIR when set (used for testing).</summary>
    public static string DataDirectory { get; } =
        Environment.GetEnvironmentVariable("TRANSLATOR_DATA_DIR") is { Length: > 0 } custom
            ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QingYiTranslator");

    /// <summary>True when TRANSLATOR_DATA_DIR points somewhere else, e.g. for a test copy running next to the real one.</summary>
    public static bool UsesCustomDataDirectory => Environment.GetEnvironmentVariable("TRANSLATOR_DATA_DIR") is { Length: > 0 };

    private static string SettingsPath => Path.Combine(DataDirectory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions);
                if (loaded is not null)
                {
                    loaded.Normalize();
                    return loaded;
                }
            }
        }
        catch (Exception ex)
        {
            Log.Error("读取设置失败，将使用默认设置", ex);
        }

        var settings = new AppSettings();
        settings.Normalize();
        return settings;
    }

    public bool Save()
    {
        try
        {
            Directory.CreateDirectory(DataDirectory);
            string temp = SettingsPath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(temp, SettingsPath, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("保存设置失败", ex);
            return false;
        }
    }

    private void Normalize()
    {
        ProviderConfigs ??= new();
        ExtraInstructions ??= "";
        Hotkey ??= "";
        if (ProviderCatalog.All.All(preset => preset.Id != ActiveProvider))
            ActiveProvider = ProviderCatalog.DeepSeekId;
        foreach (var preset in ProviderCatalog.All)
            GetProvider(preset.Id);
        if (SourceLanguage != Languages.AutoCode && Languages.Find(SourceLanguage) is null)
            SourceLanguage = Languages.AutoCode;
        if (Languages.Find(TargetLanguage) is null)
            TargetLanguage = Languages.SimplifiedChinese.Code;
        if (UiLanguage is not (Loc.ChineseCode or Loc.EnglishCode))
            UiLanguage = Loc.SystemCode;
        if (Theme is not (ThemeLight or ThemeDark))
            Theme = ThemeSystem;
    }
}

/// <summary>Encrypts secrets for the current Windows user (CryptProtectData).</summary>
internal static class Dpapi
{
    private const int CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    public static string Protect(string plain) =>
        Convert.ToBase64String(Transform(Encoding.UTF8.GetBytes(plain), protect: true));

    public static string Unprotect(string? protectedBase64)
    {
        if (string.IsNullOrEmpty(protectedBase64))
            return "";
        try
        {
            return Encoding.UTF8.GetString(Transform(Convert.FromBase64String(protectedBase64), protect: false));
        }
        catch (Exception ex)
        {
            Log.Error("无法解密已保存的 API Key", ex);
            return "";
        }
    }

    private static byte[] Transform(byte[] input, bool protect)
    {
        var pinned = GCHandle.Alloc(input, GCHandleType.Pinned);
        try
        {
            var inBlob = new DataBlob { cbData = input.Length, pbData = pinned.AddrOfPinnedObject() };
            var outBlob = new DataBlob();
            bool ok = protect
                ? CryptProtectData(ref inBlob, "QingYi Translator", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, ref outBlob)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, ref outBlob);
            if (!ok)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally
            {
                LocalFree(outBlob.pbData);
            }
        }
        finally
        {
            pinned.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int cbData;
        public IntPtr pbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob pDataIn, string? szDataDescr, IntPtr pOptionalEntropy,
        IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DataBlob pDataOut);

    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob pDataIn, IntPtr ppszDataDescr, IntPtr pOptionalEntropy,
        IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, ref DataBlob pDataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);
}
