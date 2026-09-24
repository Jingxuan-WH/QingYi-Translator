using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Translator.Core;

public sealed class HistoryEntry
{
    public DateTime Time { get; set; }
    public string SourceText { get; set; } = "";
    public string TranslatedText { get; set; } = "";

    /// <summary>Language code of the source (chosen or detected); null when unknown.</summary>
    public string? SourceLanguage { get; set; }

    public string TargetLanguage { get; set; } = "";

    /// <summary>Provider and model that produced the translation, e.g. "DeepSeek · deepseek-flash".</summary>
    public string Engine { get; set; } = "";

    [JsonIgnore]
    public string LanguagePairText =>
        $"{Languages.Find(SourceLanguage)?.LocalName ?? Loc.T("自动检测", "Auto-detected")} → {Languages.Find(TargetLanguage)?.LocalName ?? TargetLanguage}";

    [JsonIgnore]
    public string TimeText
    {
        get
        {
            DateTime today = DateTime.Today;
            if (Time.Date == today)
                return Loc.T($"今天 {Time:HH:mm}", $"Today {Time:HH:mm}");
            if (Time.Date == today.AddDays(-1))
                return Loc.T($"昨天 {Time:HH:mm}", $"Yesterday {Time:HH:mm}");
            var english = CultureInfo.GetCultureInfo("en-US");
            return Time.Year == today.Year
                ? Loc.T($"{Time:M月d日 HH:mm}", Time.ToString("MMM d, HH:mm", english))
                : Loc.T($"{Time:yyyy年M月d日}", Time.ToString("MMM d, yyyy", english));
        }
    }

    [JsonIgnore]
    public string SourcePreview => Preview(SourceText);

    [JsonIgnore]
    public string TranslationPreview => Preview(TranslatedText);

    private static string Preview(string text)
    {
        string flat = string.Join(' ', text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        return flat.Length > 160 ? flat[..160] + "…" : flat;
    }
}

/// <summary>The most recent translations, newest first, saved to %APPDATA%\QingYiTranslator\history.json.</summary>
public sealed class TranslationHistory
{
    public const int Capacity = 100;
    private const int MaxStoredChars = 50_000;
    private static readonly TimeSpan EditSessionWindow = TimeSpan.FromMinutes(3);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly string _path;

    private TranslationHistory(string path, IEnumerable<HistoryEntry> entries)
    {
        _path = path;
        Entries = new ObservableCollection<HistoryEntry>(entries.Take(Capacity));
    }

    public ObservableCollection<HistoryEntry> Entries { get; }

    public static TranslationHistory Load()
    {
        string path = Path.Combine(AppSettings.DataDirectory, "history.json");
        try
        {
            if (File.Exists(path))
                return new TranslationHistory(path, JsonSerializer.Deserialize<List<HistoryEntry>>(File.ReadAllText(path), JsonOptions) ?? []);
        }
        catch (Exception ex)
        {
            Log.Error("读取翻译历史失败", ex);
        }
        return new TranslationHistory(path, []);
    }

    public void Record(HistoryEntry entry)
    {
        if (entry.SourceText.Length > MaxStoredChars || entry.TranslatedText.Length > MaxStoredChars)
            return;

        // Replace instead of adding when the same text was translated again, or when this is the next
        // step of the text being typed or edited (each pause while typing produces a translation).
        var replaced = Entries.FirstOrDefault(e => e.SourceText == entry.SourceText && e.TargetLanguage == entry.TargetLanguage);
        if (replaced is null && Entries.FirstOrDefault() is { } latest
            && entry.Time - latest.Time < EditSessionWindow && IsSameEditSession(latest.SourceText, entry.SourceText))
            replaced = latest;
        if (replaced is not null)
            Entries.Remove(replaced);

        Entries.Insert(0, entry);
        while (Entries.Count > Capacity)
            Entries.RemoveAt(Entries.Count - 1);
        Save();
    }

    public void Remove(HistoryEntry entry)
    {
        if (Entries.Remove(entry))
            Save();
    }

    public void Clear()
    {
        Entries.Clear();
        Save();
    }

    /// <summary>True when <paramref name="b"/> looks like an edit of <paramref name="a"/> (text appended, deleted or changed in place).</summary>
    internal static bool IsSameEditSession(string a, string b)
    {
        a = a.Trim();
        b = b.Trim();
        int shorter = Math.Min(a.Length, b.Length);
        if (shorter == 0)
            return false;
        int prefix = 0;
        while (prefix < shorter && a[prefix] == b[prefix])
            prefix++;
        int suffix = 0;
        while (suffix < shorter - prefix && a[^(suffix + 1)] == b[^(suffix + 1)])
            suffix++;
        return prefix + suffix >= shorter * 0.6;
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            string temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Entries, JsonOptions));
            File.Move(temp, _path, overwrite: true);
        }
        catch (Exception ex)
        {
            Log.Error("保存翻译历史失败", ex);
        }
    }
}
