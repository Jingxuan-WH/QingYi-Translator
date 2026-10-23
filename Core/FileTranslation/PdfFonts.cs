using System.Buffers.Binary;
using System.IO;
using PdfSharp.Fonts;

namespace Translator.Core.FileTranslation;

/// <summary>
/// Fonts for the translated PDF, taken from the Windows font folder: 宋体 / 微软雅黑 for Chinese, Yu Mincho /
/// Yu Gothic for Japanese, Malgun Gothic for Korean, Times New Roman / Arial for Latin text and most other
/// languages, Cambria Math / Segoe UI Symbol for symbols the others lack. Each character is drawn with a font
/// that has it (see <see cref="FaceForChar"/>). PDFsharp embeds only the characters used.
/// </summary>
public sealed class PdfFonts : IFontResolver
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, byte[]?> Cache = [];
    private static readonly Dictionary<string, (int Start, int End)[]?> Coverage = [];
    private static PdfFonts? _installed;

    /// <summary>Candidate font files per face, the first one found wins; ",1" picks the second font of a .ttc collection.</summary>
    private static readonly Dictionary<string, string[]> Faces = new()
    {
        ["zh-serif"] = ["simsun.ttc", "msyh.ttc"],
        ["zh-serif-bold"] = ["simhei.ttf", "msyhbd.ttc", "msyh.ttc"],
        ["zh-sans"] = ["msyh.ttc", "Deng.ttf", "simhei.ttf", "simsun.ttc"],
        ["zh-sans-bold"] = ["msyhbd.ttc", "Dengb.ttf", "simhei.ttf", "msyh.ttc"],
        ["zht-serif"] = ["mingliu.ttc", "msjh.ttc", "simsun.ttc"],
        ["zht-serif-bold"] = ["msjhbd.ttc", "msjh.ttc", "simhei.ttf"],
        ["zht-sans"] = ["msjh.ttc", "msyh.ttc", "mingliu.ttc"],
        ["zht-sans-bold"] = ["msjhbd.ttc", "msjh.ttc", "msyhbd.ttc"],
        ["ja-serif"] = ["yumin.ttf", "msmincho.ttc", "YuGothR.ttc", "msgothic.ttc"],
        ["ja-serif-bold"] = ["yumindb.ttf", "YuGothB.ttc", "meiryob.ttc", "msgothic.ttc"],
        ["ja-sans"] = ["YuGothR.ttc", "meiryo.ttc", "msgothic.ttc"],
        ["ja-sans-bold"] = ["YuGothB.ttc", "meiryob.ttc", "msgothic.ttc"],
        ["ko-serif"] = ["batang.ttc", "malgun.ttf"],
        ["ko-serif-bold"] = ["malgunbd.ttf", "malgun.ttf"],
        ["ko-sans"] = ["malgun.ttf", "gulim.ttc"],
        ["ko-sans-bold"] = ["malgunbd.ttf", "malgun.ttf"],
        ["latin-serif"] = ["times.ttf", "georgia.ttf", "arial.ttf"],
        ["latin-serif-bold"] = ["timesbd.ttf", "georgiab.ttf", "arialbd.ttf"],
        ["latin-sans"] = ["arial.ttf", "segoeui.ttf", "calibri.ttf"],
        ["latin-sans-bold"] = ["arialbd.ttf", "segoeuib.ttf", "calibrib.ttf"],
        ["latin-serif-italic"] = ["timesi.ttf", "georgiai.ttf"],
        ["latin-serif-bold-italic"] = ["timesbi.ttf", "georgiaz.ttf"],
        ["latin-sans-italic"] = ["ariali.ttf", "segoeuii.ttf"],
        ["latin-sans-bold-italic"] = ["arialbi.ttf", "segoeuiz.ttf"],
        ["math"] = ["cambria.ttc,1", "seguisym.ttf"],
        ["symbol"] = ["seguisym.ttf", "arialuni.ttf"],
        ["th-sans"] = ["LeelawUI.ttf", "tahoma.ttf"],
        ["th-sans-bold"] = ["LeelaUIb.ttf", "tahomabd.ttf"],
        ["hi-sans"] = ["Nirmala.ttc", "Nirmala.ttf", "mangal.ttf"],
        ["hi-sans-bold"] = ["NirmalaB.ttc", "NirmalaB.ttf", "mangalb.ttf"],
        ["ar-sans"] = ["segoeui.ttf", "arial.ttf", "tahoma.ttf"],
        ["ar-sans-bold"] = ["segoeuib.ttf", "arialbd.ttf", "tahomabd.ttf"],
    };

    /// <summary>Folders searched for the files above. Tests point this at other fonts.</summary>
    public static List<string> Directories { get; } =
    [
        Environment.GetFolderPath(Environment.SpecialFolder.Fonts),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Fonts"),
    ];

    /// <summary>Replaces the lookup by face name (tests): return a font file path, optionally with ",index" for a collection.</summary>
    public static Func<string, string?>? Override { get; set; }

    /// <summary>Installs the resolver once; PDFsharp keeps a single global one.</summary>
    public static void Install()
    {
        lock (Gate)
        {
            if (_installed is not null)
                return;
            _installed = new PdfFonts();
            if (GlobalFontSettings.FontResolver is null)
                GlobalFontSettings.FontResolver = _installed;
        }
    }

    /// <summary>The face for a block of translated text: by target language (or the script of the text), serif or not, bold or not.</summary>
    public static string FaceFor(Language target, string text, bool serif, bool bold)
    {
        string script = target.Code switch
        {
            "zh-Hans" => "zh",
            "zh-Hant" => "zht",
            "ja" => "ja",
            "ko" => "ko",
            "th" => "th",
            "hi" => "hi",
            "ar" => "ar",
            _ => "latin",
        };
        // A Latin font can't show Chinese names or terms the translation kept.
        if (script == "latin" && text.Any(c => c is >= '⺀' and <= '鿿' or >= '가' and <= '힯'))
            script = "zh";
        bool hasSerif = script is "zh" or "zht" or "ja" or "ko" or "latin";
        string face = $"{script}-{(serif && hasSerif ? "serif" : "sans")}{(bold ? "-bold" : "")}";
        return Resolve(face) is not null ? face : Resolve($"{script}-sans") is not null ? $"{script}-sans" : "latin-sans";
    }

    private static string ScriptOf(Language target) => target.Code switch
    {
        "zh-Hans" => "zh",
        "zh-Hant" => "zht",
        "ja" => "ja",
        "ko" => "ko",
        "th" => "th",
        "hi" => "hi",
        "ar" => "ar",
        _ => "latin",
    };

    /// <summary>Faces tried after the preferred ones, so that some font has every character.</summary>
    private static readonly string[] Fallbacks = ["latin-serif", "latin-sans", "math", "symbol", "zh-sans", "ja-sans", "ko-sans", "hi-sans", "th-sans", "ar-sans"];

    /// <summary>
    /// The face for one character of translated text: the target language's font for its own script, a Latin font for
    /// Latin letters, digits and symbols (CJK fonts draw them as stiff half-width forms), and otherwise the first font
    /// that has the character, so none is ever dropped. Italic is only used for Latin text.
    /// </summary>
    public static string FaceForChar(Language target, int codepoint, bool serif, bool bold, bool italic)
    {
        string script = ScriptOf(target);
        bool cjkTarget = script is "zh" or "zht" or "ja" or "ko";
        string preferred = codepoint switch
        {
            >= 0xAC00 and <= 0xD7AF or >= 0x1100 and <= 0x11FF or >= 0x3130 and <= 0x318F => cjkTarget ? script : "ko",
            >= 0x3040 and <= 0x30FF or >= 0x31F0 and <= 0x31FF => cjkTarget ? script : "ja",
            >= 0x2E80 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF or >= 0xFE30 and <= 0xFE4F or >= 0xFF00 and <= 0xFFEF or >= 0x20000 and <= 0x3FFFF
                => cjkTarget ? script : "zh",
            // Dashes, ellipses, quotes and the middle dot take the width of the text around them in CJK writing.
            0x2014 or 0x2026 or >= 0x2018 and <= 0x201D or 0xB7 when cjkTarget => script,
            >= 0x0E00 and <= 0x0E7F => "th",
            >= 0x0900 and <= 0x097F => "hi",
            >= 0x0600 and <= 0x06FF or >= 0x0750 and <= 0x077F or >= 0xFB50 and <= 0xFDFF or >= 0xFE70 and <= 0xFEFF => "ar",
            _ => "latin",
        };
        var candidates = Candidates(preferred, serif, bold, italic);
        foreach (string face in candidates.Concat(Fallbacks))
        {
            if (Resolve(face) is not null && Covers(face, codepoint))
                return face;
        }
        return candidates.FirstOrDefault(face => Resolve(face) is not null) ?? FaceFor(target, "", serif, bold);
    }

    private static List<string> Candidates(string script, bool serif, bool bold, bool italic)
    {
        bool hasSerif = script is "zh" or "zht" or "ja" or "ko" or "latin";
        string kind = serif && hasSerif ? "serif" : "sans";
        var faces = new List<string>();
        if (script == "latin" && italic)
            faces.Add($"latin-{kind}{(bold ? "-bold" : "")}-italic");
        faces.Add($"{script}-{kind}{(bold ? "-bold" : "")}");
        faces.Add($"{script}-{kind}");
        faces.Add($"{script}-sans");
        return faces;
    }

    /// <summary>True when the face's character map has the character (or the map couldn't be read).</summary>
    public static bool Covers(string face, int codepoint)
    {
        (int Start, int End)[]? ranges;
        lock (Gate)
        {
            if (!Coverage.TryGetValue(face, out ranges))
                Coverage[face] = ranges = Resolve(face) is { } data ? ReadCharacterMap(data) : [];
        }
        if (ranges is null)
            return true;
        int low = 0, high = ranges.Length - 1;
        while (low <= high)
        {
            int middle = (low + high) / 2;
            if (codepoint < ranges[middle].Start)
                high = middle - 1;
            else if (codepoint > ranges[middle].End)
                low = middle + 1;
            else
                return true;
        }
        return false;
    }

    /// <summary>
    /// The character ranges in a TrueType/OpenType font's cmap: the full-Unicode table (format 12) when there is one,
    /// otherwise the basic one (format 4). Null when the font can't be read.
    /// </summary>
    public static (int Start, int End)[]? ReadCharacterMap(byte[] font)
    {
        try
        {
            var data = font.AsSpan();
            int tables = BinaryPrimitives.ReadUInt16BigEndian(data[4..]);
            int cmap = -1;
            for (int i = 0; i < tables; i++)
            {
                if (BinaryPrimitives.ReadUInt32BigEndian(data[(12 + 16 * i)..]) == 0x636D6170) // "cmap"
                    cmap = (int)BinaryPrimitives.ReadUInt32BigEndian(data[(12 + 16 * i + 8)..]);
            }
            if (cmap < 0)
                return null;
            int count = BinaryPrimitives.ReadUInt16BigEndian(data[(cmap + 2)..]);
            int basic = -1, full = -1;
            for (int i = 0; i < count; i++)
            {
                var record = data[(cmap + 4 + 8 * i)..];
                int platform = BinaryPrimitives.ReadUInt16BigEndian(record), encoding = BinaryPrimitives.ReadUInt16BigEndian(record[2..]);
                int offset = cmap + (int)BinaryPrimitives.ReadUInt32BigEndian(record[4..]);
                int format = BinaryPrimitives.ReadUInt16BigEndian(data[offset..]);
                if (platform == 3 && encoding == 10 || platform == 0 && encoding >= 4)
                    full = format == 12 ? offset : full;
                else if (platform == 3 && encoding == 1 || platform == 0)
                    basic = format == 4 && basic < 0 ? offset : basic;
            }
            var ranges = new List<(int, int)>();
            if (full >= 0)
            {
                int groups = (int)BinaryPrimitives.ReadUInt32BigEndian(data[(full + 12)..]);
                for (int i = 0; i < groups; i++)
                {
                    var group = data[(full + 16 + 12 * i)..];
                    ranges.Add(((int)BinaryPrimitives.ReadUInt32BigEndian(group), (int)BinaryPrimitives.ReadUInt32BigEndian(group[4..])));
                }
            }
            else if (basic >= 0)
            {
                int segments = BinaryPrimitives.ReadUInt16BigEndian(data[(basic + 6)..]) / 2;
                for (int i = 0; i < segments; i++)
                {
                    int end = BinaryPrimitives.ReadUInt16BigEndian(data[(basic + 14 + 2 * i)..]);
                    int start = BinaryPrimitives.ReadUInt16BigEndian(data[(basic + 16 + 2 * segments + 2 * i)..]);
                    if (start != 0xFFFF)
                        ranges.Add((start, end));
                }
            }
            else
            {
                return null;
            }
            return ranges.OrderBy(r => r.Item1).ToArray();
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    public FontResolverInfo? ResolveTypeface(string familyName, bool bold, bool italic)
    {
        if (Resolve(familyName) is null)
            return null;
        // Simulate italics; bold faces are separate families here.
        return new FontResolverInfo(familyName, false, italic);
    }

    public byte[]? GetFont(string faceName) => Resolve(faceName);

    private static byte[]? Resolve(string face)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(face, out byte[]? cached))
                return cached;
            byte[]? data = null;
            var candidates = Override?.Invoke(face) is { } path ? [path] : Faces.GetValueOrDefault(face) ?? [];
            foreach (string candidate in candidates)
            {
                string file = candidate;
                int index = 0;
                int comma = candidate.LastIndexOf(',');
                if (comma > 0 && int.TryParse(candidate[(comma + 1)..], out int parsed))
                {
                    file = candidate[..comma];
                    index = parsed;
                }
                foreach (string directory in Path.IsPathRooted(file) ? [""] : Directories)
                {
                    string full = Path.Combine(directory, file);
                    if (!File.Exists(full))
                        continue;
                    try
                    {
                        byte[] bytes = File.ReadAllBytes(full);
                        data = IsCollection(bytes) ? ExtractFromCollection(bytes, index) : bytes;
                        break;
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or InvalidDataException)
                    {
                        Log.Error($"无法读取字体 {full}", ex);
                    }
                }
                if (data is not null)
                    break;
            }
            Cache[face] = data;
            return data;
        }
    }

    private static bool IsCollection(byte[] font) => font.Length > 12 && font[0] == 't' && font[1] == 't' && font[2] == 'c' && font[3] == 'f';

    /// <summary>
    /// Copies one font out of a TrueType collection (.ttc) into a stand-alone font file, since PDFsharp reads
    /// single fonts. Tables shared between the fonts of the collection are simply copied.
    /// </summary>
    public static byte[] ExtractFromCollection(byte[] collection, int index)
    {
        int count = (int)BinaryPrimitives.ReadUInt32BigEndian(collection.AsSpan(8));
        if (index < 0 || index >= count)
            index = 0;
        int offset = (int)BinaryPrimitives.ReadUInt32BigEndian(collection.AsSpan(12 + 4 * index));
        int tables = BinaryPrimitives.ReadUInt16BigEndian(collection.AsSpan(offset + 4));
        int headerLength = 12 + 16 * tables;
        var records = new List<(uint Tag, uint Checksum, int Offset, int Length)>();
        for (int i = 0; i < tables; i++)
        {
            var record = collection.AsSpan(offset + 12 + 16 * i);
            records.Add((BinaryPrimitives.ReadUInt32BigEndian(record), BinaryPrimitives.ReadUInt32BigEndian(record[4..]),
                (int)BinaryPrimitives.ReadUInt32BigEndian(record[8..]), (int)BinaryPrimitives.ReadUInt32BigEndian(record[12..])));
        }
        int total = headerLength + records.Sum(r => (r.Length + 3) & ~3);
        byte[] font = new byte[total];
        collection.AsSpan(offset, 12).CopyTo(font);
        int position = headerLength;
        for (int i = 0; i < records.Count; i++)
        {
            var (tag, checksum, tableOffset, length) = records[i];
            if (tableOffset < 0 || length < 0 || tableOffset + length > collection.Length)
                throw new InvalidDataException("Font table out of range");
            var record = font.AsSpan(12 + 16 * i);
            BinaryPrimitives.WriteUInt32BigEndian(record, tag);
            BinaryPrimitives.WriteUInt32BigEndian(record[4..], checksum);
            BinaryPrimitives.WriteUInt32BigEndian(record[8..], (uint)position);
            BinaryPrimitives.WriteUInt32BigEndian(record[12..], (uint)length);
            collection.AsSpan(tableOffset, length).CopyTo(font.AsSpan(position));
            position += (length + 3) & ~3;
        }
        return font;
    }
}
