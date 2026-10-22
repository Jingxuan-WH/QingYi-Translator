using System.IO;

namespace Translator.Core.FileTranslation;

public enum SegmentRole
{
    Body,
    Title,
    Heading,
    Other,
}

/// <summary>One paragraph, table cell, slide text or subtitle of a document, as sent for translation.</summary>
public sealed class DocumentSegment(int id, TaggedText text, SegmentRole role = SegmentRole.Body)
{
    public int Id { get; } = id;

    public TaggedText Text { get; } = text;

    public SegmentRole Role { get; } = role;

    /// <summary>Part of a reference list; skipped unless the user wants references translated.</summary>
    public bool IsReference { get; set; }

    public string PlainText => TaggedText.StripTags(Text.Text);
}

public sealed record DocumentSaveOptions(Language Target, string? BilingualPath = null);

/// <summary>Couldn't open, read or save a document; the message is shown to the user as is.</summary>
public sealed class DocumentException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>A document opened for translation: its segments, and how to write the translated copy.</summary>
public abstract class TranslatableDocument
{
    private readonly List<DocumentSegment> _segments = [];

    protected TranslatableDocument(string path) => SourcePath = path;

    public string SourcePath { get; }

    public IReadOnlyList<DocumentSegment> Segments => _segments;

    /// <summary>Things the user should know, e.g. pages that are scanned images and stay untranslated.</summary>
    public List<string> Warnings { get; } = [];

    /// <summary>Extra rule for the model about this kind of document, e.g. that subtitles run across cues.</summary>
    public virtual string? PromptHint => null;

    /// <summary>True for PDF, which can also be written as alternating original and translated pages.</summary>
    public virtual bool SupportsBilingual => false;

    /// <summary>
    /// Writes the translated copy. <paramref name="translations"/> maps segment ids to translated tagged text;
    /// segments without a translation keep their original text.
    /// </summary>
    public abstract void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options);

    protected DocumentSegment AddSegment(IReadOnlyList<InlinePiece> pieces, SegmentRole role = SegmentRole.Body)
    {
        var segment = new DocumentSegment(_segments.Count, TaggedText.Build(pieces), role);
        _segments.Add(segment);
        return segment;
    }

    protected DocumentSegment AddSegment(string text, SegmentRole role = SegmentRole.Body) =>
        AddSegment([InlinePiece.Of(text, 0)], role);

    /// <summary>True when the text has something to translate: at least one letter that isn't part of a lone code or number.</summary>
    public static bool HasWords(string text)
    {
        int letters = 0;
        foreach (char c in text)
        {
            if (char.IsLetter(c) && ++letters >= 2)
                return true;
            // A single CJK character is a word.
            if (c >= '⺀' && char.IsLetter(c))
                return true;
        }
        return false;
    }

    /// <summary>Writes through a temporary file next to the target, so a failure never leaves a half-written document.</summary>
    protected static void WriteAtomically(string path, Action<Stream> write)
    {
        string temp = path + ".partial";
        try
        {
            using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
                write(stream);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            try
            {
                File.Delete(temp);
            }
            catch
            {
                // Nothing more we can do.
            }
            throw;
        }
    }
}

public static class ReferenceSection
{
    private static readonly HashSet<string> Headings = new(StringComparer.OrdinalIgnoreCase)
    {
        "references", "reference", "bibliography", "works cited", "literature cited", "literature", "references and notes",
        "参考文献", "参考资料", "引用文献", "參考文獻", "参考文献：", "literaturverzeichnis", "références", "bibliographie", "referencias",
    };

    /// <summary>"References", "7. References", "VII. REFERENCES", "参考文献"…</summary>
    public static bool IsHeading(string text)
    {
        string trimmed = text.Trim().TrimEnd(':', '：').Trim();
        if (trimmed.Length is 0 or > 40)
            return false;
        // Drop numbering such as "7.", "VII.", "A." in front.
        int space = trimmed.IndexOf(' ');
        if (space > 0 && space <= 5 && trimmed[..space].TrimEnd('.').All(c => char.IsDigit(c) || "IVXLivxl".Contains(c)))
            trimmed = trimmed[(space + 1)..].Trim();
        return Headings.Contains(trimmed);
    }
}

/// <summary>Where the translated copy goes: next to the original, never over it.</summary>
public static class OutputPaths
{
    /// <summary>"paper.pdf" → "paper.zh-Hans.pdf"; "paper.zh-Hans (2).pdf" if that exists already.</summary>
    public static string For(string sourcePath, Language target, string? variant = null)
    {
        string directory = Path.GetDirectoryName(sourcePath) ?? "";
        string name = Path.GetFileNameWithoutExtension(sourcePath);
        string extension = Path.GetExtension(sourcePath);
        string stem = variant is null ? $"{name}.{target.Code}" : $"{name}.{target.Code}.{variant}";
        string path = Path.Combine(directory, stem + extension);
        for (int n = 2; File.Exists(path) || string.Equals(path, sourcePath, StringComparison.OrdinalIgnoreCase); n++)
            path = Path.Combine(directory, $"{stem} ({n}){extension}");
        return path;
    }
}
