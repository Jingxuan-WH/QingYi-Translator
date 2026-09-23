using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Translator.Core;

public sealed class ProviderConfig
{
    public string BaseUrl { get; set; } = "";
    public string Model { get; set; } = "";

    /// <summary>API key encrypted with Windows DPAPI (current user), base64.</summary>
    public string? ApiKeyProtected { get; set; }

    public double Temperature { get; set; } = 0.3;

    /// <summary>Sends <c>"thinking": {"type": "disabled"}</c>; DeepSeek enables thinking by default, which only slows translation down.</summary>
    public bool DisableThinking { get; set; }

    [JsonIgnore]
    public string ApiKey
    {
        get => Dpapi.Unprotect(ApiKeyProtected);
        set => ApiKeyProtected = string.IsNullOrWhiteSpace(value) ? null : Dpapi.Protect(value.Trim());
    }

    public ProviderConfig Clone() => (ProviderConfig)MemberwiseClone();
}

public static class Providers
{
    public const string DeepSeek = "DeepSeek";
    public const string Custom = "Custom";

    public static IReadOnlyList<string> All { get; } = [DeepSeek, Custom];

    public static string DisplayName(string id) => id == DeepSeek ? "DeepSeek" : "自定义接口";

    public static IReadOnlyList<string> SuggestedModels(string id) =>
        id == DeepSeek ? ["deepseek-flash", "deepseek-v4-pro"] : [];

    public static ProviderConfig CreateDefault(string id) => id switch
    {
        // DeepSeek's docs recommend temperature 1.3 for translation (their API rescales the value).
        DeepSeek => new ProviderConfig { BaseUrl = "https://api.deepseek.com", Model = "deepseek-flash", Temperature = 1.3, DisableThinking = true },
        _ => new ProviderConfig { Temperature = 0.3 },
    };
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

    public string ActiveProvider { get; set; } = Providers.DeepSeek;
    public Dictionary<string, ProviderConfig> ProviderConfigs { get; set; } = new();
    public string ExtraInstructions { get; set; } = "";

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

    [JsonIgnore]
    public ProviderConfig Active => GetProvider(ActiveProvider);

    public ProviderConfig GetProvider(string id)
    {
        if (!ProviderConfigs.TryGetValue(id, out var config))
        {
            config = Providers.CreateDefault(id);
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
        if (!Providers.All.Contains(ActiveProvider))
            ActiveProvider = Providers.DeepSeek;
        foreach (string id in Providers.All)
            GetProvider(id);
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
