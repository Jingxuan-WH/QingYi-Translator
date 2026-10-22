using System.Xml.Linq;

namespace Translator.Core.FileTranslation;

/// <summary>
/// Word, PowerPoint and Excel files. The text is replaced inside the existing XML, so styles, tables, images,
/// headers and footers, footnotes and text boxes are left exactly as they were.
/// </summary>
public abstract class OpenXmlDocument : TranslatableDocument
{
    protected static readonly XNamespace W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    protected static readonly XNamespace A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    protected static readonly XNamespace P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    protected static readonly XNamespace X = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    protected static readonly XNamespace M = "http://schemas.openxmlformats.org/officeDocument/2006/math";
    protected static readonly XNamespace MC = "http://schemas.openxmlformats.org/markup-compatibility/2006";

    private static readonly HashSet<string> NoDrop = [];

    internal static readonly InlineDialect WordDialect = new()
    {
        Run = W + "r",
        RunProperties = W + "rPr",
        Text = W + "t",
        PreserveSpace = true,
        Containers = [W + "hyperlink", W + "smartTag", W + "customXml", W + "sdt", W + "ins", W + "moveTo", W + "dir", W + "bdo"],
        ContainerContent = new() { [W + "sdt"] = W + "sdtContent" },
        Atoms = [M + "oMath", M + "oMathPara", W + "fldSimple", MC + "AlternateContent"],
        Disposable = [W + "lastRenderedPageBreak"],
        FieldChar = W + "fldChar",
        FieldCharType = W + "fldCharType",
        FieldInstruction = W + "instrText",
        RemovableWhenEmpty = [W + "hyperlink", W + "smartTag", W + "ins", W + "moveTo"],
        // Language, proofing and complex-script variants don't change how Latin or CJK text looks.
        StyleKey = properties => InlineParagraph.PropertiesKey(properties, new HashSet<string> { "lang", "noProof", "szCs", "bCs", "iCs", "rtl", "cs" },
            new HashSet<string> { "hint", "rsidRPr" }),
    };

    internal static readonly InlineDialect DrawingDialect = new()
    {
        Run = A + "r",
        RunProperties = A + "rPr",
        Text = A + "t",
        Atoms = [A + "br", A + "fld", MC + "AlternateContent"],
        StyleKey = properties => InlineParagraph.PropertiesKey(properties, NoDrop,
            new HashSet<string> { "lang", "altLang", "dirty", "err", "smtClean", "smtId", "noProof", "bmk" }),
    };

    internal static readonly InlineDialect SpreadsheetDialect = new()
    {
        Run = X + "r",
        RunProperties = X + "rPr",
        Text = X + "t",
        PreserveSpace = true,
        StyleKey = properties => InlineParagraph.PropertiesKey(properties, NoDrop, NoDrop),
    };

    private readonly List<(InlineParagraph Paragraph, int Segment)> _paragraphs = [];

    private protected OpenXmlDocument(string path) : base(path) => Package = OpenXmlPackage.Open(path);

    private protected OpenXmlPackage Package { get; }

    /// <summary>Adds the paragraphs of one part; returns the segments that were created, in order.</summary>
    private protected List<(XElement Element, InlineParagraph Paragraph, DocumentSegment Segment)> AddParagraphs(
        IEnumerable<XElement> paragraphs, InlineDialect dialect, Func<XElement, SegmentRole> role)
    {
        var added = new List<(XElement, InlineParagraph, DocumentSegment)>();
        int fieldDepth = 0;
        foreach (var element in paragraphs.ToList())
        {
            var paragraph = new InlineParagraph(element, dialect, ref fieldDepth);
            if (!paragraph.HasWords)
                continue;
            var segment = AddSegment(paragraph.Pieces(), role(element));
            _paragraphs.Add((paragraph, segment.Id));
            added.Add((element, paragraph, segment));
        }
        return added;
    }

    /// <summary>Called after the translations are written and before the file is saved.</summary>
    private protected virtual void AfterApply(IReadOnlyDictionary<int, string> translations)
    {
    }

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options)
    {
        foreach (var (paragraph, segment) in _paragraphs)
        {
            if (translations.TryGetValue(segment, out string? translation))
                paragraph.Apply(Segments[segment].Text, translation);
        }
        AfterApply(translations);
        WriteAtomically(outputPath, Package.Save);
    }

    public static OpenXmlDocument Open(string path) => System.IO.Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".docx" or ".docm" or ".dotx" => new WordDocument(path),
        ".pptx" or ".pptm" or ".ppsx" => new PresentationDocument(path),
        _ => new SpreadsheetDocument(path),
    };
}

/// <summary>.docx: body, headers, footers, footnotes and endnotes, including text boxes and tables.</summary>
public sealed class WordDocument : OpenXmlDocument
{
    private const string Ns = "application/vnd.openxmlformats-officedocument.wordprocessingml.";

    public WordDocument(string path) : base(path)
    {
        var mainParts = Package.PartsOfType(Ns + "document.main+xml", "application/vnd.ms-word.document.macroEnabled.main+xml",
            Ns + "template.main+xml", "application/vnd.ms-word.template.macroEnabledTemplate.main+xml");
        if (mainParts.Count == 0)
            throw new DocumentException(Loc.T("这不是有效的 Word 文档。", "This isn’t a valid Word document."));
        var styles = ReadStyles();

        SegmentRole RoleOf(XElement paragraph)
        {
            var properties = paragraph.Element(W + "pPr");
            string? styleId = (string?)properties?.Element(W + "pStyle")?.Attribute(W + "val");
            var style = styleId is not null && styles.TryGetValue(styleId, out var found) ? found : default;
            if (style.Name is "title")
                return SegmentRole.Title;
            if (style.Name?.StartsWith("heading", StringComparison.Ordinal) == true || style.Outline
                || properties?.Element(W + "outlineLvl") is { } level && (string?)level.Attribute(W + "val") != "9")
                return SegmentRole.Heading;
            return SegmentRole.Body;
        }

        foreach (string part in mainParts.Take(1)
                     .Concat(Package.PartsOfType(Ns + "header+xml", Ns + "footer+xml", Ns + "footnotes+xml", Ns + "endnotes+xml")))
        {
            var root = Package.Load(part).Root!;
            var added = AddParagraphs(root.Descendants(W + "p"), WordDialect, RoleOf);
            if (part != mainParts[0])
                continue;
            // Reference lists usually stay in the original language; they run from the "References" heading to the next heading.
            bool inReferences = false;
            foreach (var (_, paragraph, segment) in added)
            {
                if (ReferenceSection.IsHeading(paragraph.PlainText))
                {
                    inReferences = true;
                    continue;
                }
                if (inReferences && segment.Role is SegmentRole.Heading or SegmentRole.Title)
                    inReferences = false;
                segment.IsReference = inReferences;
            }
        }
    }

    /// <summary>Style id → lower-case style name and whether it is an outline (heading) level.</summary>
    private Dictionary<string, (string? Name, bool Outline)> ReadStyles()
    {
        var styles = new Dictionary<string, (string?, bool)>();
        foreach (string part in Package.PartsOfType(Ns + "styles+xml"))
        {
            foreach (var style in Package.Load(part).Root!.Elements(W + "style"))
            {
                if ((string?)style.Attribute(W + "styleId") is not { } id)
                    continue;
                string? name = ((string?)style.Element(W + "name")?.Attribute(W + "val"))?.ToLowerInvariant();
                var level = style.Element(W + "pPr")?.Element(W + "outlineLvl");
                styles[id] = (name, level is not null && (string?)level.Attribute(W + "val") != "9");
            }
        }
        return styles;
    }
}

/// <summary>.pptx: slides and speaker notes, including tables and grouped shapes.</summary>
public sealed class PresentationDocument : OpenXmlDocument
{
    private const string Ns = "application/vnd.openxmlformats-officedocument.presentationml.";

    private readonly List<(XElement Paragraph, DocumentSegment Segment)> _slideParagraphs = [];

    public PresentationDocument(string path) : base(path)
    {
        var slides = Package.PartsOfType(Ns + "slide+xml");
        if (slides.Count == 0)
            throw new DocumentException(Loc.T("演示文稿里没有幻灯片。", "The presentation has no slides."));
        bool first = true;
        foreach (string part in slides)
        {
            var root = Package.Load(part).Root!;
            bool firstSlide = first;
            var added = AddParagraphs(root.Descendants(A + "p"), DrawingDialect, paragraph => RoleOf(paragraph, firstSlide));
            _slideParagraphs.AddRange(added.Select(item => (item.Element, item.Segment)));
            first = false;
        }
        foreach (string part in Package.PartsOfType(Ns + "notesSlide+xml"))
            AddParagraphs(Package.Load(part).Root!.Descendants(A + "p"), DrawingDialect, _ => SegmentRole.Body);
    }

    private static SegmentRole RoleOf(XElement paragraph, bool firstSlide)
    {
        var shape = paragraph.Ancestors(P + "sp").FirstOrDefault();
        string? type = (string?)shape?.Element(P + "nvSpPr")?.Element(P + "nvPr")?.Element(P + "ph")?.Attribute("type");
        if (paragraph.Ancestors(A + "tbl").Any())
            return SegmentRole.Other;
        return type switch
        {
            "ctrTitle" when firstSlide => SegmentRole.Title,
            "title" or "ctrTitle" => SegmentRole.Heading,
            _ => SegmentRole.Body,
        };
    }

    /// <summary>
    /// Text that got longer (e.g. Chinese → English) would overflow its box. PowerPoint applies a stored
    /// "shrink text on overflow" scale when it opens the file, so text boxes get a scale that makes room.
    /// </summary>
    private protected override void AfterApply(IReadOnlyDictionary<int, string> translations)
    {
        foreach (var body in _slideParagraphs.GroupBy(item => item.Paragraph.Parent))
        {
            if (body.Key is not { } textBody || textBody.Name != P + "txBody")
                continue;
            int before = 0, after = 0;
            foreach (var (_, segment) in body)
            {
                before += InlineParagraph.DisplayWidth(segment.PlainText);
                after += InlineParagraph.DisplayWidth(translations.TryGetValue(segment.Id, out string? translation)
                    ? TaggedText.StripTags(translation) : segment.PlainText);
            }
            double ratio = before == 0 ? 1 : (double)after / before;
            var properties = textBody.Element(A + "bodyPr");
            if (ratio <= 1.15 || properties is null || properties.Element(A + "spAutoFit") is not null)
                continue;
            var existing = properties.Element(A + "normAutofit");
            double scale = existing is not null && int.TryParse((string?)existing.Attribute("fontScale"), out int stored) ? stored / 100000.0 : 1.0;
            scale = Math.Clamp(scale / Math.Sqrt(ratio), 0.25, 1.0);
            existing?.Remove();
            properties.Element(A + "noAutofit")?.Remove();
            var autofit = new XElement(A + "normAutofit", new XAttribute("fontScale", (int)Math.Round(scale * 100000 / 2500) * 2500));
            if (scale < 0.8)
                autofit.Add(new XAttribute("lnSpcReduction", "10000"));
            // Schema order: prstTxWarp comes before the autofit element.
            if (properties.Element(A + "prstTxWarp") is { } warp)
                warp.AddAfterSelf(autofit);
            else
                properties.AddFirst(autofit);
        }
    }
}

/// <summary>.xlsx: text cells (shared and inline strings) and text boxes. Numbers, dates and formulas are not touched.</summary>
public sealed class SpreadsheetDocument : OpenXmlDocument
{
    private const string Ns = "application/vnd.openxmlformats-officedocument.spreadsheetml.";

    public SpreadsheetDocument(string path) : base(path)
    {
        foreach (string part in Package.PartsOfType(Ns + "sharedStrings+xml"))
            AddParagraphs(Package.Load(part).Root!.Elements(X + "si"), SpreadsheetDialect, _ => SegmentRole.Body);
        foreach (string part in Package.PartsOfType(Ns + "worksheet+xml"))
        {
            var inline = Package.Load(part).Root!.Descendants(X + "c")
                .Where(cell => (string?)cell.Attribute("t") == "inlineStr" && cell.Element(X + "f") is null)
                .Select(cell => cell.Element(X + "is")).OfType<XElement>();
            AddParagraphs(inline, SpreadsheetDialect, _ => SegmentRole.Body);
        }
        foreach (string part in Package.PartsOfType("application/vnd.openxmlformats-officedocument.drawing+xml"))
            AddParagraphs(Package.Load(part).Root!.Descendants(A + "p"), DrawingDialect, _ => SegmentRole.Body);
    }
}
