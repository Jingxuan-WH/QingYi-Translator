using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Translator.Core;

/// <summary>Two equivalent terms. Works both ways: whichever side appears in the text is translated as the other.</summary>
public sealed class GlossaryEntry
{
    public string Source { get; set; } = "";
    public string Target { get; set; } = "";
}

/// <summary>The user's terminology, saved to glossary.json next to the settings.</summary>
public sealed class Glossary
{
    public const int MaxEntries = 5000;

    /// <summary>Only entries found in the text are sent, and at most this many, so a big glossary can't flood the prompt.</summary>
    public const int MaxEntriesPerRequest = 80;

    private const int MaxTermLength = 200;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    // First row of an exported or hand-made table, not a real entry.
    private static readonly HashSet<string> HeaderRows = new(StringComparer.OrdinalIgnoreCase)
    {
        "source|target", "term|translation", "source term|target term", "原文|译文", "术语|译法", "术语|译文",
    };

    private readonly string _path;

    private Glossary(string path, IReadOnlyList<GlossaryEntry> entries)
    {
        _path = path;
        Entries = entries;
    }

    public IReadOnlyList<GlossaryEntry> Entries { get; private set; }

    /// <summary>Changes whenever the entries do; part of the translation cache key, so edits take effect at once.</summary>
    public int Version { get; private set; }

    public static Glossary Load()
    {
        string path = Path.Combine(AppSettings.DataDirectory, "glossary.json");
        try
        {
            if (File.Exists(path))
                return new Glossary(path, Clean(JsonSerializer.Deserialize<List<GlossaryEntry>>(File.ReadAllText(path), JsonOptions) ?? []));
        }
        catch (Exception ex)
        {
            Log.Error("读取术语表失败", ex);
            try
            {
                File.Copy(path, path + ".bak", overwrite: true); // keep the unreadable file instead of overwriting it later
            }
            catch
            {
                // Nothing more we can do.
            }
        }
        return new Glossary(path, []);
    }

    public bool Replace(IEnumerable<GlossaryEntry> entries)
    {
        Entries = Clean(entries);
        Version++;
        return Save();
    }

    public IReadOnlyList<GlossaryEntry> Match(string text) => Match(Entries, text);

    public static IReadOnlyList<GlossaryEntry> Match(IReadOnlyList<GlossaryEntry> entries, string text)
    {
        var matches = new List<GlossaryEntry>();
        foreach (var entry in entries)
        {
            if (ContainsTerm(text, entry.Source) || ContainsTerm(text, entry.Target))
            {
                matches.Add(entry);
                if (matches.Count == MaxEntriesPerRequest)
                    break;
            }
        }
        return matches;
    }

    /// <summary>
    /// Case-insensitive. A term that starts with a letter of a space-separated script must start a word,
    /// so "AI" doesn't match inside "email"; the end is left open so plurals still match.
    /// </summary>
    public static bool ContainsTerm(string text, string term)
    {
        if (term.Length == 0)
            return false;
        bool needsWordStart = IsSpacedWordChar(term[0]);
        int from = 0;
        while (from <= text.Length - term.Length)
        {
            int index = text.IndexOf(term, from, StringComparison.OrdinalIgnoreCase);
            if (index < 0)
                return false;
            if (!needsWordStart || index == 0 || !IsSpacedWordChar(text[index - 1]))
                return true;
            from = index + 1;
        }
        return false;
    }

    // Letters and digits of scripts that put spaces between words (Latin, Greek, Cyrillic, Arabic, Devanagari…); not CJK or Thai.
    private static bool IsSpacedWordChar(char c) =>
        char.IsLetterOrDigit(c) && c < '\u2E80' && c is not (>= '\u0E00' and <= '\u0E7F');

    /// <summary>Trims terms, drops incomplete and duplicate entries.</summary>
    public static List<GlossaryEntry> Clean(IEnumerable<GlossaryEntry> entries)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<GlossaryEntry>();
        foreach (var entry in entries)
        {
            string source = Normalize(entry.Source);
            string target = Normalize(entry.Target);
            if (source.Length == 0 || target.Length == 0 || !seen.Add(source + '\u001F' + target))
                continue;
            result.Add(new GlossaryEntry { Source = source, Target = target });
            if (result.Count == MaxEntries)
                break;
        }
        return result;
    }

    private static string Normalize(string? term)
    {
        if (string.IsNullOrWhiteSpace(term))
            return "";
        string single = string.Join(' ', term.Split(['\r', '\n', '\t'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        return single.Length > MaxTermLength ? single[..MaxTermLength] : single;
    }

    // ---------------- import / export ----------------

    private static readonly string[] Separators = ["=>", "->", "→", "⇄", "↔", "="];

    /// <summary>
    /// Reads pasted or imported lines: cells copied from Excel (tab-separated), CSV rows, or text such as
    /// "power flow = 潮流" and "power flow → 潮流". Lines without a separator are skipped.
    /// </summary>
    public static List<GlossaryEntry> Parse(string text)
    {
        var entries = new List<GlossaryEntry>();
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0 || SplitLine(line) is not { } pair)
                continue;
            if (entries.Count == 0 && HeaderRows.Contains(pair.Source + "|" + pair.Target))
                continue;
            entries.Add(new GlossaryEntry { Source = pair.Source, Target = pair.Target });
        }
        return entries;
    }

    internal static (string Source, string Target)? SplitLine(string line)
    {
        string[] parts;
        if (line.Contains('\t'))
        {
            parts = line.Split('\t');
        }
        else if (FindSeparator(line) is { } at)
        {
            parts = [line[..at.Index], line[(at.Index + at.Length)..]];
        }
        else if (line.Contains(','))
        {
            parts = [.. ParseCsvLine(line)];
        }
        else
        {
            return null;
        }

        string source = Unquote(parts[0]);
        string target = parts.Length > 1 ? Unquote(parts[1]) : "";
        return source.Length > 0 && target.Length > 0 ? (source, target) : null;
    }

    private static (int Index, int Length)? FindSeparator(string line)
    {
        (int Index, int Length)? best = null;
        foreach (string separator in Separators) // longest first, so "=>" wins over "=" at the same spot
        {
            int index = line.IndexOf(separator, StringComparison.Ordinal);
            if (index > 0 && (best is null || index < best.Value.Index))
                best = (index, separator.Length);
        }
        return best;
    }

    private static List<string> ParseCsvLine(string line)
    {
        var fields = new List<string>();
        var field = new StringBuilder();
        bool quoted = false;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (quoted)
            {
                if (c != '"')
                    field.Append(c);
                else if (i + 1 < line.Length && line[i + 1] == '"')
                    field.Append(line[++i]);
                else
                    quoted = false;
            }
            else if (c == '"' && field.ToString().Trim().Length == 0)
            {
                field.Clear();
                quoted = true;
            }
            else if (c == ',')
            {
                fields.Add(field.ToString());
                field.Clear();
            }
            else
            {
                field.Append(c);
            }
        }
        fields.Add(field.ToString());
        return fields;
    }

    private static string Unquote(string cell)
    {
        cell = cell.Trim();
        if (cell.Length >= 2 && cell[0] == '"' && cell[^1] == '"')
            cell = cell[1..^1].Replace("\"\"", "\"").Trim();
        return cell;
    }

    /// <summary>CSV that Excel opens correctly (UTF-8 with a byte order mark when written with <see cref="WriteCsv"/>).</summary>
    public static string ToCsv(IEnumerable<GlossaryEntry> entries)
    {
        var csv = new StringBuilder();
        foreach (var entry in entries)
            csv.Append(QuoteCsv(entry.Source)).Append(',').Append(QuoteCsv(entry.Target)).Append("\r\n");
        return csv.ToString();
    }

    public static void WriteCsv(string path, IEnumerable<GlossaryEntry> entries) =>
        File.WriteAllText(path, ToCsv(entries), new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

    /// <summary>Reads a UTF-8/UTF-16 file, or one saved in the system code page (what Excel's plain "CSV" uses on Chinese Windows).</summary>
    public static List<GlossaryEntry> ReadFile(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        bool hasByteOrderMark = (bytes.Length >= 2 && (bytes[0], bytes[1]) is (0xFF, 0xFE) or (0xFE, 0xFF))
            || (bytes.Length >= 3 && (bytes[0], bytes[1], bytes[2]) is (0xEF, 0xBB, 0xBF));
        string text;
        if (hasByteOrderMark)
        {
            using var reader = new StreamReader(new MemoryStream(bytes), detectEncodingFromByteOrderMarks: true);
            text = reader.ReadToEnd();
        }
        else
        {
            try
            {
                text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
                text = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.ANSICodePage).GetString(bytes);
            }
        }
        return Parse(text);
    }

    private static string QuoteCsv(string field) =>
        field.IndexOfAny([',', '"', '\n', '\r']) >= 0 ? $"\"{field.Replace("\"", "\"\"")}\"" : field;

    private bool Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            string temp = _path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(Entries, JsonOptions));
            File.Move(temp, _path, overwrite: true);
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("保存术语表失败", ex);
            return false;
        }
    }
}
