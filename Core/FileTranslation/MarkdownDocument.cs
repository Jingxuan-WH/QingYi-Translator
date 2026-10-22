using System.Text;
using System.Text.RegularExpressions;

namespace Translator.Core.FileTranslation;

/// <summary>
/// Markdown: headings, paragraphs, list items, quotes and table cells are translated; code blocks, math blocks,
/// front matter, HTML blocks and link definitions stay as they are. Inside the text, code spans, inline math,
/// URLs and HTML tags are kept exactly.
/// </summary>
public sealed class MarkdownDocument : TranslatableDocument
{
    private static readonly Regex InlineKeep = new(string.Join('|',
        @"(?<t>`+)(?:(?!\k<t>).)+?\k<t>(?!`)",                             // `code`
        @"\$\$[^$]+\$\$",                                                   // $$math$$ within a line
        @"(?<![\\\w$])\$(?=[^\s$])[^$\n]*?[^\s\\$]\$(?![\w$])",             // $math$
        @"<!--.*?-->",
        @"<(?:https?|ftp|mailto):[^<>\s]+>",                                // <https://…>
        @"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>",                        // <br>, <sup>…
        @"(?<=\])\((?:[^()\s]|\([^()\s]*\))*(?:\s+(?:""[^""]*""|'[^']*'))?\s*\)", // ](url "title")
        @"(?<=\])\[[^\]]*\]",                                               // [text][ref]
        @"\[\^[^\]]+\]",                                                    // [^1]
        @"\{#[^}\s]*\}",                                                    // {#heading-id}
        @"\b(?:https?|ftp)://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'""]"),        // bare URL
        RegexOptions.CultureInvariant);

    private static readonly Regex Fence = new(@"^(\s{0,3})(`{3,}|~{3,})", RegexOptions.CultureInvariant);
    private static readonly Regex AtxHeading = new(@"^(\s{0,3}#{1,6})([ \t]+)(.*?)([ \t]+#+[ \t]*)?$", RegexOptions.CultureInvariant);
    private static readonly Regex SetextUnderline = new(@"^\s{0,3}(=+|-+)\s*$", RegexOptions.CultureInvariant);
    private static readonly Regex Rule = new(@"^\s{0,3}([-*_])(?:\s*\1){2,}\s*$", RegexOptions.CultureInvariant);
    private static readonly Regex ListItem = new(@"^(\s*(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex Quote = new(@"^(\s{0,3}>[ \t]?(?:>[ \t]?)*)(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex HtmlBlock = new(
        @"^\s{0,3}(?:<!--|</?(?:address|article|aside|blockquote|center|details|dialog|div|dl|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|iframe|li|main|nav|ol|p|picture|pre|script|section|style|summary|table|tbody|td|tfoot|th|thead|tr|ul|video)(?:[\s/>]|$)|</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>\s*$)",
        RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);
    private static readonly Regex UnescapedPipe = new(@"(?<!\\)\|", RegexOptions.CultureInvariant);
    private static readonly Regex LinkDefinition = new(@"^\s{0,3}\[[^\]]+\]:\s*\S", RegexOptions.CultureInvariant);
    private static readonly Regex TableSeparator = new(@"^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$", RegexOptions.CultureInvariant);

    private abstract record Part;

    private sealed record Literal(string Line) : Part;

    /// <summary>One or more lines of translated text; the first line gets <paramref name="FirstPrefix"/>, the others <paramref name="NextPrefix"/>.</summary>
    private sealed record Block(int Segment, string FirstPrefix, string NextPrefix, string Suffix, List<string> Atoms) : Part;

    private sealed record Row(List<(string Literal, int Segment, List<string>? Atoms)> Cells) : Part;

    private readonly TextFile _file;
    private readonly List<Part> _parts = [];
    private bool _titleSeen;

    public MarkdownDocument(string path) : base(path)
    {
        _file = TextFile.Read(path);
        Parse(_file.Text.Split('\n'));
    }

    public override string PromptHint =>
        "The segments are Markdown. Keep emphasis markers (**, *, _, ~~), link brackets and other Markdown syntax around the corresponding translated words.";

    private void Parse(string[] lines)
    {
        int i = 0;
        // YAML front matter.
        if (lines.Length > 1 && lines[0].Trim() == "---")
        {
            int end = Array.FindIndex(lines, 1, line => line.Trim() is "---" or "...");
            if (end > 0)
            {
                for (; i <= end; i++)
                    _parts.Add(new Literal(lines[i]));
            }
        }

        bool previousBlank = true, inList = false;
        while (i < lines.Length)
        {
            string line = lines[i];
            if (line.Trim().Length == 0)
            {
                _parts.Add(new Literal(line));
                previousBlank = true;
                i++;
                continue;
            }

            if (Fence.Match(line) is { Success: true } fence)
            {
                string marker = fence.Groups[2].Value;
                _parts.Add(new Literal(line));
                for (i++; i < lines.Length; i++)
                {
                    _parts.Add(new Literal(lines[i]));
                    string trimmed = lines[i].Trim();
                    if (trimmed.Length >= marker.Length && trimmed.All(c => c == marker[0]))
                    {
                        i++;
                        break;
                    }
                }
            }
            else if (line.TrimStart().StartsWith("$$", StringComparison.Ordinal))
            {
                // A math block runs until the line that ends with $$ (possibly the same one).
                string rest = line.TrimStart()[2..];
                _parts.Add(new Literal(line));
                i++;
                if (!rest.TrimEnd().EndsWith("$$", StringComparison.Ordinal))
                {
                    for (; i < lines.Length; i++)
                    {
                        _parts.Add(new Literal(lines[i]));
                        if (lines[i].TrimEnd().EndsWith("$$", StringComparison.Ordinal))
                        {
                            i++;
                            break;
                        }
                    }
                }
            }
            else if (previousBlank && !inList && IsIndentedCode(line))
            {
                for (; i < lines.Length && (lines[i].Trim().Length == 0 || IsIndentedCode(lines[i])); i++)
                    _parts.Add(new Literal(lines[i]));
            }
            else if (line.TrimStart().StartsWith("<!--", StringComparison.Ordinal))
            {
                // A comment runs to the line that closes it.
                for (; i < lines.Length; i++)
                {
                    _parts.Add(new Literal(lines[i]));
                    if (lines[i].Contains("-->"))
                    {
                        i++;
                        break;
                    }
                }
            }
            else if (HtmlBlock.IsMatch(line) || Rule.IsMatch(line) || LinkDefinition.IsMatch(line))
            {
                // Other HTML blocks run to the next blank line.
                bool html = HtmlBlock.IsMatch(line);
                _parts.Add(new Literal(line));
                for (i++; html && i < lines.Length && lines[i].Trim().Length > 0; i++)
                    _parts.Add(new Literal(lines[i]));
            }
            else if (line.Contains('|') && i + 1 < lines.Length && TableSeparator.IsMatch(lines[i + 1]) && lines[i + 1].Contains('-'))
            {
                AddRow(lines[i]);
                _parts.Add(new Literal(lines[i + 1]));
                for (i += 2; i < lines.Length && lines[i].Trim().Length > 0 && lines[i].Contains('|'); i++)
                    AddRow(lines[i]);
            }
            else if (AtxHeading.Match(line) is { Success: true } heading)
            {
                bool title = heading.Groups[1].Value.Trim() == "#" && !_titleSeen;
                AddBlock(heading.Groups[3].Value, heading.Groups[1].Value + heading.Groups[2].Value, "", heading.Groups[4].Value,
                    title ? SegmentRole.Title : SegmentRole.Heading);
                inList = false;
                i++;
            }
            else if (Quote.Match(line) is { Success: true } quote)
            {
                string prefix = quote.Groups[1].Value;
                var content = new List<string>();
                for (; i < lines.Length && Quote.Match(lines[i]) is { Success: true } next && lines[i].Trim().Length > 0; i++)
                    content.Add(next.Groups[2].Value);
                AddBlock(string.Join('\n', content), prefix, prefix, "", SegmentRole.Body);
            }
            else if (ListItem.Match(line) is { Success: true } item)
            {
                string prefix = item.Groups[1].Value;
                var content = new List<string> { item.Groups[2].Value };
                for (i++; i < lines.Length && lines[i].Trim().Length > 0 && !StartsBlock(lines[i]); i++)
                    content.Add(lines[i].Trim());
                AddBlock(string.Join('\n', content), prefix, new string(' ', prefix.Length), "", SegmentRole.Body);
                inList = true;
            }
            else
            {
                // A paragraph, or a setext heading (a line underlined with === or ---).
                string indent = line[..(line.Length - line.TrimStart().Length)];
                var content = new List<string> { line.Trim() };
                for (i++; i < lines.Length && lines[i].Trim().Length > 0 && !StartsBlock(lines[i]) && !SetextUnderline.IsMatch(lines[i]); i++)
                    content.Add(lines[i].Trim());
                if (i < lines.Length && SetextUnderline.IsMatch(lines[i]) && content.Count == 1)
                {
                    bool title = lines[i].Trim()[0] == '=' && !_titleSeen;
                    AddBlock(content[0], indent, indent, "", title ? SegmentRole.Title : SegmentRole.Heading);
                    _parts.Add(new Literal(lines[i]));
                    i++;
                }
                else
                {
                    AddBlock(string.Join('\n', content), indent, indent, "", SegmentRole.Body);
                }
                if (indent.Length == 0)
                    inList = false;
            }
            previousBlank = false;
        }
    }

    private static bool IsIndentedCode(string line) => line.StartsWith("    ", StringComparison.Ordinal) || line.StartsWith('\t');

    private static bool StartsBlock(string line) =>
        Fence.IsMatch(line) || AtxHeading.IsMatch(line) || Quote.IsMatch(line) || ListItem.IsMatch(line) || Rule.IsMatch(line)
        || HtmlBlock.IsMatch(line) || line.TrimStart().StartsWith("$$", StringComparison.Ordinal) || line.TrimStart().StartsWith('|');

    private void AddBlock(string content, string firstPrefix, string nextPrefix, string suffix, SegmentRole role)
    {
        if (!HasWords(InlineKeep.Replace(content, " ")))
        {
            _parts.Add(new Literal(firstPrefix + content.Replace("\n", "\n" + nextPrefix) + suffix));
            return;
        }
        if (role == SegmentRole.Title)
            _titleSeen = true;
        var (pieces, atoms) = ProtectedText.Split(content, InlineKeep);
        _parts.Add(new Block(AddSegment(pieces, role).Id, firstPrefix, nextPrefix, suffix, atoms));
    }

    private void AddRow(string line)
    {
        var cells = new List<(string, int, List<string>?)>();
        var current = new StringBuilder();
        bool code = false;
        void Flush(bool separator)
        {
            string cell = current.ToString();
            current.Clear();
            string core = cell.Trim();
            if (HasWords(InlineKeep.Replace(core, " ")))
            {
                int lead = cell.Length - cell.TrimStart().Length;
                var (pieces, atoms) = ProtectedText.Split(core, InlineKeep);
                cells.Add((cell[..lead], -1, null));
                cells.Add(("", AddSegment(pieces, SegmentRole.Other).Id, atoms));
                cells.Add((cell[(lead + core.Length)..], -1, null));
            }
            else
            {
                cells.Add((cell, -1, null));
            }
            if (separator)
                cells.Add(("|", -1, null));
        }
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '`')
                code = !code;
            if (c == '|' && !code && (i == 0 || line[i - 1] != '\\'))
                Flush(separator: true);
            else
                current.Append(c);
        }
        Flush(separator: false);
        _parts.Add(new Row(cells));
    }

    private string Translated(int segment, List<string> atoms, IReadOnlyDictionary<int, string> translations)
    {
        var tagged = Segments[segment].Text;
        string text = translations.TryGetValue(segment, out string? translation) ? translation : tagged.Text;
        return ProtectedText.Restore(tagged, text, atoms).Replace("\r\n", "\n");
    }

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options)
    {
        var lines = new List<string>();
        foreach (var part in _parts)
        {
            switch (part)
            {
                case Literal literal:
                    lines.Add(literal.Line);
                    break;
                case Block block:
                    // Blank lines inside a block would end it (and break a list or quote).
                    var translated = Translated(block.Segment, block.Atoms, translations).Split('\n').Where(line => line.Trim().Length > 0).ToList();
                    if (translated.Count == 0)
                        translated.Add("");
                    for (int i = 0; i < translated.Count; i++)
                        lines.Add((i == 0 ? block.FirstPrefix : block.NextPrefix) + translated[i].Trim() + (i == translated.Count - 1 ? block.Suffix : ""));
                    break;
                case Row row:
                    var text = new StringBuilder();
                    foreach (var (literal, segment, atoms) in row.Cells)
                        text.Append(segment < 0 ? literal : UnescapedPipe.Replace(Translated(segment, atoms!, translations).Replace('\n', ' '), @"\|"));
                    lines.Add(text.ToString());
                    break;
            }
        }
        WriteAtomically(outputPath, stream => _file.Write(stream, string.Join('\n', lines)));
    }
}
