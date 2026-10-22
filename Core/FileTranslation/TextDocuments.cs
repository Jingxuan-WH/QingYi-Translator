using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace Translator.Core.FileTranslation;

/// <summary>Reads a text file in UTF-8/UTF-16 or the system code page, and writes it back with the same line breaks.</summary>
internal sealed class TextFile
{
    private TextFile(string text, bool byteOrderMark, bool utf8, string newline)
    {
        Text = text;
        ByteOrderMark = byteOrderMark;
        Utf8 = utf8;
        Newline = newline;
    }

    /// <summary>The content with "\n" line breaks.</summary>
    public string Text { get; }

    private bool ByteOrderMark { get; }
    private bool Utf8 { get; }
    private string Newline { get; }

    public static TextFile Read(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        bool bom = (bytes.Length >= 2 && (bytes[0], bytes[1]) is (0xFF, 0xFE) or (0xFE, 0xFF))
            || (bytes.Length >= 3 && (bytes[0], bytes[1], bytes[2]) is (0xEF, 0xBB, 0xBF));
        string text;
        bool utf8 = true;
        if (bom)
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
                text = DecodeLegacy(bytes);
                utf8 = false;
            }
        }
        string newline = text.Contains("\r\n") ? "\r\n" : "\n";
        return new TextFile(text.Replace("\r\n", "\n").Replace('\r', '\n'), bom, utf8, newline);
    }

    /// <summary>
    /// A file in a legacy code page: the system's one if it is a CJK code page, else GB18030 when the bytes are
    /// valid GB18030 with Chinese in them (most non-UTF-8 files our users meet are GBK), else the system's code page.
    /// </summary>
    private static string DecodeLegacy(byte[] bytes)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        int system = CultureInfo.CurrentCulture.TextInfo.ANSICodePage;
        if (system is 936 or 950 or 932 or 949 && TryDecode(bytes, system) is { } local)
            return local;
        if (TryDecode(bytes, 54936) is { } chinese && chinese.Any(c => c is >= '\u4E00' and <= '\u9FFF'))
            return chinese;
        return Encoding.GetEncoding(system is 0 or 65001 ? 1252 : system).GetString(bytes);
    }

    private static string? TryDecode(byte[] bytes, int codePage)
    {
        try
        {
            return Encoding.GetEncoding(codePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
    }

    /// <summary>
    /// Writes UTF-8. A file that wasn't UTF-8 gets a byte order mark, so Notepad and other editors still recognize it.
    /// </summary>
    public void Write(Stream stream, string text)
    {
        var encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: ByteOrderMark || !Utf8);
        using var writer = new StreamWriter(stream, encoding);
        writer.Write(Newline == "\n" ? text : text.Replace("\n", Newline));
    }
}

/// <summary>
/// Splits a line of text into words to translate and parts that must stay exactly as they are (code, URLs, tags),
/// and puts the parts back into the translation.
/// </summary>
internal static class ProtectedText
{
    public static (List<InlinePiece> Pieces, List<string> Atoms) Split(string text, Regex keep)
    {
        var pieces = new List<InlinePiece>();
        var atoms = new List<string>();
        int position = 0;
        foreach (Match match in keep.Matches(text))
        {
            if (match.Length == 0)
                continue;
            if (match.Index > position)
                pieces.Add(InlinePiece.Of(text[position..match.Index], 0));
            pieces.Add(InlinePiece.Object(atoms.Count, match.Value));
            atoms.Add(match.Value);
            position = match.Index + match.Length;
        }
        if (position < text.Length)
            pieces.Add(InlinePiece.Of(text[position..], 0));
        return (pieces, atoms);
    }

    /// <summary>The translation with each placeholder replaced by its original; any the model dropped are added at the end.</summary>
    public static string Restore(TaggedText tagged, string translation, IReadOnlyList<string> atoms)
    {
        var result = new StringBuilder();
        var used = new HashSet<int>();
        foreach (var piece in tagged.Parse(translation))
        {
            if (!piece.IsAtom)
                result.Append(piece.Text);
            else if (piece.Atom < atoms.Count && used.Add(piece.Atom))
                result.Append(atoms[piece.Atom]);
        }
        for (int i = 0; i < atoms.Count; i++)
        {
            if (!used.Contains(i))
                result.Append(result.Length > 0 && !char.IsWhiteSpace(result[^1]) ? " " : "").Append(atoms[i]);
        }
        return result.ToString();
    }
}

/// <summary>Plain text: each paragraph (separated by blank lines) is translated on its own.</summary>
public sealed class PlainTextDocument : TranslatableDocument
{
    private static readonly Regex ParagraphBreak = new(@"\n[ \t]*\n(?:[ \t]*\n)*", RegexOptions.CultureInvariant);
    private static readonly Regex UrlPattern = new(@"\b(?:https?|ftp)://[^\s<>""]+[^\s<>"".,;:!?)\]}'，。；：！？）】]|\b[\w.+-]+@[\w-]+\.[\w.-]+\w",
        RegexOptions.CultureInvariant);

    private readonly TextFile _file;
    private readonly List<(string Literal, int Segment, List<string>? Atoms)> _parts = [];

    public PlainTextDocument(string path) : base(path)
    {
        _file = TextFile.Read(path);
        string text = _file.Text;
        int position = 0;
        foreach (Match? gap in ParagraphBreak.Matches(text).Append(null))
        {
            int end = gap?.Index ?? text.Length;
            AddParagraph(text[position..end]);
            if (gap is not null)
                _parts.Add((gap.Value, -1, null));
            position = gap is null ? text.Length : gap.Index + gap.Length;
        }
    }

    private void AddParagraph(string paragraph)
    {
        string core = paragraph.Trim();
        if (!HasWords(core))
        {
            _parts.Add((paragraph, -1, null));
            return;
        }
        int lead = paragraph.Length - paragraph.TrimStart().Length;
        int trail = paragraph.Length - paragraph.TrimEnd().Length;
        _parts.Add((paragraph[..lead], -1, null));
        var (pieces, atoms) = ProtectedText.Split(core, UrlPattern);
        bool first = Segments.Count == 0;
        // A short first line on its own is most likely the title.
        var role = first && core.Length <= 120 && !core.Contains('\n') ? SegmentRole.Title : SegmentRole.Body;
        _parts.Add(("", AddSegment(pieces, role).Id, atoms));
        _parts.Add((paragraph[^trail..], -1, null));
    }

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options)
    {
        var text = new StringBuilder();
        foreach (var (literal, segment, atoms) in _parts)
        {
            if (segment < 0)
                text.Append(literal);
            else if (translations.TryGetValue(segment, out string? translation))
                text.Append(ProtectedText.Restore(Segments[segment].Text, translation, atoms!).Replace("\r\n", "\n"));
            else
                text.Append(ProtectedText.Restore(Segments[segment].Text, Segments[segment].Text.Text, atoms!));
        }
        WriteAtomically(outputPath, stream => _file.Write(stream, text.ToString()));
    }
}

/// <summary>SubRip subtitles: numbers and timings stay, each cue's text is translated.</summary>
public sealed class SubtitleDocument : TranslatableDocument
{
    private static readonly Regex TagPattern = new(@"</?[A-Za-z][^<>]*>|\{\\[^{}]*\}", RegexOptions.CultureInvariant);
    private static readonly Regex BlockBreak = new(@"\n[ \t]*\n(?:[ \t]*\n)*", RegexOptions.CultureInvariant);

    private readonly TextFile _file;
    private readonly List<(string Literal, int Segment, List<string>? Atoms)> _parts = [];

    public SubtitleDocument(string path) : base(path)
    {
        _file = TextFile.Read(path);
        string text = _file.Text;
        int position = 0;
        foreach (Match? gap in BlockBreak.Matches(text).Append(null))
        {
            int end = gap?.Index ?? text.Length;
            AddCue(text[position..end]);
            if (gap is not null)
                _parts.Add((gap.Value, -1, null));
            position = gap is null ? text.Length : gap.Index + gap.Length;
        }
    }

    public override string PromptHint =>
        "The segments are consecutive subtitle cues. A sentence may run across several cues: translate each cue's own part of it, so every cue still matches its timing. Keep cues short enough to read on screen.";

    private void AddCue(string block)
    {
        string[] lines = block.Split('\n');
        // "12" / "00:01:02,000 --> 00:01:04,500" / text…; some files leave out the number.
        int header = lines.Length >= 2 && lines[1].Contains("-->") && int.TryParse(lines[0].Trim().TrimStart('﻿'), out _) ? 2
            : lines.Length >= 1 && lines[0].Contains("-->") ? 1
            : -1;
        string cueText = header < 0 ? "" : string.Join('\n', lines[header..]);
        if (header < 0 || !HasWords(cueText))
        {
            _parts.Add((block, -1, null));
            return;
        }
        // The line break at the very end of the file belongs after the cue.
        string core = cueText.TrimEnd('\n', ' ', '\t');
        _parts.Add((string.Join('\n', lines[..header]) + '\n', -1, null));
        var (pieces, atoms) = ProtectedText.Split(core, TagPattern);
        _parts.Add(("", AddSegment(pieces).Id, atoms));
        _parts.Add((cueText[core.Length..], -1, null));
    }

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options)
    {
        var text = new StringBuilder();
        foreach (var (literal, segment, atoms) in _parts)
        {
            if (segment < 0)
            {
                text.Append(literal);
                continue;
            }
            var tagged = Segments[segment].Text;
            string translated = translations.TryGetValue(segment, out string? translation) ? translation : tagged.Text;
            // A blank line would end the cue early.
            string restored = ProtectedText.Restore(tagged, translated, atoms!).Replace("\r\n", "\n");
            text.Append(string.Join('\n', restored.Split('\n').Where(line => line.Trim().Length > 0)));
        }
        WriteAtomically(outputPath, stream => _file.Write(stream, text.ToString()));
    }
}
