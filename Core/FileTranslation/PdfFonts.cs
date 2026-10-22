using System.Buffers.Binary;
using System.IO;
using PdfSharp.Fonts;

namespace Translator.Core.FileTranslation;

/// <summary>
/// Fonts for the translated PDF, taken from the Windows font folder: 宋体 / 微软雅黑 for Chinese, Yu Mincho /
/// Yu Gothic for Japanese, Malgun Gothic for Korean, Times New Roman / Arial for most other languages.
/// PDFsharp embeds only the characters used.
/// </summary>
public sealed class PdfFonts : IFontResolver
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, byte[]?> Cache = [];
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
