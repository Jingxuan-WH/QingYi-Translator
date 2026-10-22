using System.Text;
using System.Xml.Linq;

namespace Translator.Core.FileTranslation;

/// <summary>The element names of one Office markup language (WordprocessingML, DrawingML or SpreadsheetML).</summary>
internal sealed class InlineDialect
{
    public required XName Run { get; init; }
    public required XName RunProperties { get; init; }
    public required XName Text { get; init; }

    /// <summary>Whether <see cref="Text"/> needs xml:space="preserve" to keep leading and trailing spaces.</summary>
    public bool PreserveSpace { get; init; }

    /// <summary>Elements whose runs belong to the paragraph's text, e.g. hyperlinks. They become part of the format.</summary>
    public HashSet<XName> Containers { get; init; } = [];

    /// <summary>For containers whose runs sit in a child (w:sdt → w:sdtContent).</summary>
    public Dictionary<XName, XName> ContainerContent { get; init; } = [];

    /// <summary>Paragraph-level elements that are objects, e.g. formulas and line breaks.</summary>
    public HashSet<XName> Atoms { get; init; } = [];

    /// <summary>Run children that are only caches and can be dropped (w:lastRenderedPageBreak).</summary>
    public HashSet<XName> Disposable { get; init; } = [];

    /// <summary>Complex field markers (w:fldChar, w:instrText); everything between begin and end stays as one object.</summary>
    public XName? FieldChar { get; init; }
    public XName? FieldCharType { get; init; }
    public XName? FieldInstruction { get; init; }

    /// <summary>Containers that may be removed once empty.</summary>
    public HashSet<XName> RemovableWhenEmpty { get; init; } = [];

    /// <summary>The run properties as a comparable key, without attributes that don't change the look (language, proofing).</summary>
    public required Func<XElement?, string> StyleKey { get; init; }
}

/// <summary>
/// One paragraph of an Office document prepared for translation. Runs are split so each holds one piece of text
/// or one object, runs that look the same are merged, and the result is offered as tagged text. The translation is
/// written back by filling the existing runs in order and cloning a run only when the translation needs a format
/// in a place the original didn't have it, so everything that isn't text (images, formulas, footnote marks,
/// fields, bookmarks) stays in the paragraph.
/// </summary>
internal sealed class InlineParagraph
{
    private readonly XElement _paragraph;
    private readonly InlineDialect _dialect;
    private readonly List<Slot> _slots = [];
    private readonly List<string> _styleKeys = [];

    private sealed class Slot
    {
        public required List<XElement> Nodes { get; init; } // a text run, or the element(s) of an object
        public int Style { get; init; } = -1;                // -1 for objects
        public int Atom { get; init; } = -1;
        public bool IsText => Style >= 0;
        public XElement Run => Nodes[0];
    }

    /// <param name="fieldDepth">Complex fields can span paragraphs; the depth carries over from the previous paragraph.</param>
    public InlineParagraph(XElement paragraph, InlineDialect dialect, ref int fieldDepth)
    {
        _paragraph = paragraph;
        _dialect = dialect;
        var items = new List<(XElement Node, string? Style)>(); // Style null: object
        var field = new List<XElement>();
        int depth = fieldDepth;

        void CloseField()
        {
            if (field.Count > 0)
                items.Add((field[0], "\u0001field" + items.Count));
        }

        void Walk(XElement parent, string chain)
        {
            foreach (var child in parent.Elements().ToList())
            {
                if (child.Name == dialect.Run || child.Name == dialect.Text && parent == paragraph)
                {
                    foreach (var run in child.Name == dialect.Run ? SplitRun(child) : [child])
                    {
                        var content = run.Name == dialect.Text ? run : run.Elements().FirstOrDefault(e => e.Name != dialect.RunProperties);
                        if (content is null)
                            continue;
                        if (dialect.FieldChar is not null && content.Name == dialect.FieldChar)
                        {
                            string type = (string?)content.Attribute(dialect.FieldCharType!) ?? "";
                            if (type == "begin")
                                depth++;
                            field.Add(run);
                            if (type == "end" && --depth <= 0)
                            {
                                depth = 0;
                                _fields.Add(field.ToList());
                                CloseField();
                                field.Clear();
                            }
                            continue;
                        }
                        if (depth > 0)
                        {
                            field.Add(run);
                            continue;
                        }
                        if (content.Name == dialect.Text)
                            items.Add((run, chain + "|" + dialect.StyleKey(run.Element(dialect.RunProperties))));
                        else
                            items.Add((run, null));
                    }
                }
                else if (dialect.Containers.Contains(child.Name))
                {
                    var inner = dialect.ContainerContent.TryGetValue(child.Name, out var contentName) ? child.Element(contentName) : child;
                    if (inner is not null)
                        Walk(inner, chain + "/" + ContainerKey(child));
                }
                else if (dialect.Atoms.Contains(child.Name))
                {
                    if (depth > 0)
                        field.Add(child);
                    else
                        items.Add((child, null));
                }
                // Anything else (paragraph properties, bookmarks, comment ranges, deletions…) stays where it is.
            }
        }

        Walk(paragraph, "");
        // A field still open at the end continues in the next paragraph (e.g. a table of contents).
        if (field.Count > 0)
        {
            _fields.Add(field.ToList());
            CloseField();
        }
        fieldDepth = depth;

        // Merge neighbouring runs that look the same, so "Hel" + "lo" (split by spell checking or editing) is one piece.
        for (int i = 0; i < items.Count; i++)
        {
            var (node, style) = items[i];
            if (style is null || style.StartsWith('\u0001'))
            {
                var nodes = style is null ? [node] : _fields.First(f => f[0] == node);
                _slots.Add(new Slot { Nodes = nodes, Atom = AtomCount++ });
                continue;
            }
            if (_slots.Count > 0 && _slots[^1].IsText && _styleKeys[_slots[^1].Style] == style && _slots[^1].Run.Parent == node.Parent)
            {
                SetText(_slots[^1].Run, GetText(_slots[^1].Run) + GetText(node));
                node.Remove();
                continue;
            }
            int index = _styleKeys.IndexOf(style);
            if (index < 0)
            {
                index = _styleKeys.Count;
                _styleKeys.Add(style);
            }
            _slots.Add(new Slot { Nodes = [node], Style = index });
        }
    }

    private readonly List<List<XElement>> _fields = [];

    public int AtomCount { get; private set; }

    public bool HasWords => _slots.Any(slot => slot.IsText && TranslatableDocument.HasWords(GetText(slot.Run)));

    public string PlainText => string.Concat(_slots.Where(slot => slot.IsText).Select(slot => GetText(slot.Run)));

    public List<InlinePiece> Pieces() =>
        _slots.Select(slot => slot.IsText ? InlinePiece.Of(GetText(slot.Run), slot.Style) : InlinePiece.Object(slot.Atom)).ToList();

    private static string ContainerKey(XElement container) =>
        container.Name.LocalName + string.Concat(container.Attributes().OrderBy(a => a.Name.ToString()).Select(a => $" {a.Name.LocalName}={a.Value}"));

    /// <summary>Gives every text or object its own run (with a copy of the run properties); returns the runs in order.</summary>
    private List<XElement> SplitRun(XElement run)
    {
        foreach (var cache in run.Elements().Where(e => _dialect.Disposable.Contains(e.Name)).ToList())
            cache.Remove();
        var contents = run.Elements().Where(e => e.Name != _dialect.RunProperties).ToList();
        if (contents.Count <= 1)
            return [run];
        var properties = run.Element(_dialect.RunProperties);
        var runs = new List<XElement>();
        foreach (var content in contents)
        {
            content.Remove();
            var single = new XElement(run.Name, run.Attributes(), properties is null ? null : new XElement(properties), content);
            run.AddBeforeSelf(single);
            runs.Add(single);
        }
        run.Remove();
        return runs;
    }

    private string GetText(XElement run) => (run.Name == _dialect.Text ? run : run.Element(_dialect.Text))?.Value ?? "";

    private void SetText(XElement run, string text)
    {
        var element = run.Name == _dialect.Text ? run : run.Element(_dialect.Text)!;
        element.Value = text;
        if (_dialect.PreserveSpace)
        {
            bool needed = text.Length > 0 && (char.IsWhiteSpace(text[0]) || char.IsWhiteSpace(text[^1]));
            element.SetAttributeValue(XNamespace.Xml + "space", needed ? "preserve" : null);
        }
    }

    /// <summary>The direct child of the paragraph that holds <paramref name="node"/>.</summary>
    private XElement TopLevel(XElement node)
    {
        while (node.Parent is { } parent && parent != _paragraph)
            node = parent;
        return node;
    }

    /// <summary>Writes the translation (tagged text) into the paragraph.</summary>
    public void Apply(TaggedText tagged, string translation)
    {
        string flat = translation.Replace("\r\n", " ").Replace('\n', ' ');
        var pieces = tagged.Parse(flat);
        var used = new bool[_slots.Count];
        int cursor = -1;
        XElement? anchor = null; // the last node written, at any depth

        void InsertAfterAnchor(XElement node)
        {
            if (anchor is null)
            {
                var first = _slots.Count > 0 ? TopLevel(_slots[0].Nodes[0]) : null;
                if (first is not null)
                    first.AddBeforeSelf(node);
                else
                    _paragraph.Add(node);
            }
            else
            {
                var top = TopLevel(anchor);
                top.AddAfterSelf(node);
                // Slots still inside that container now come before the insertion point.
                for (int i = cursor + 1; i < _slots.Count; i++)
                {
                    if (_slots[i].Nodes.Any(n => n.Parent is not null && TopLevel(n) == top))
                        cursor = i;
                }
            }
            anchor = node;
        }

        foreach (var piece in pieces)
        {
            if (!piece.IsAtom)
            {
                if (piece.Text.Length == 0)
                    continue;
                int style = piece.Style;
                int next = -1;
                for (int i = cursor + 1; i < _slots.Count; i++)
                {
                    if (_slots[i].Style == style && !used[i])
                    {
                        next = i;
                        break;
                    }
                }
                if (next >= 0)
                {
                    SetText(_slots[next].Run, piece.Text);
                    used[next] = true;
                    cursor = next;
                    anchor = _slots[next].Run;
                }
                else if (_slots.FirstOrDefault(slot => slot.Style == style) is { } template)
                {
                    var clone = new XElement(template.Run);
                    SetText(clone, piece.Text);
                    InsertAfterAnchor(clone);
                }
            }
            else
            {
                int index = _slots.FindIndex(slot => slot.Atom == piece.Atom);
                if (index < 0 || used[index])
                    continue;
                used[index] = true;
                if (index > cursor)
                {
                    cursor = index;
                    anchor = _slots[index].Nodes[^1];
                }
                else if (_slots[index].Nodes.Count == 1)
                {
                    // The translation moved an object before text that came first: move it along.
                    var node = _slots[index].Nodes[0];
                    node.Remove();
                    InsertAfterAnchor(node);
                }
            }
        }

        for (int i = 0; i < _slots.Count; i++)
        {
            if (_slots[i].IsText && !used[i])
            {
                var parent = _slots[i].Run.Parent;
                _slots[i].Run.Remove();
                // An emptied hyperlink would be invisible but still clickable in some viewers.
                while (parent is not null && parent != _paragraph && _dialect.RemovableWhenEmpty.Contains(parent.Name) && !parent.Elements().Any())
                {
                    var up = parent.Parent;
                    parent.Remove();
                    parent = up;
                }
            }
        }
    }

    /// <summary>Text width in "half-em" units: CJK and other full-width characters count twice. Used to judge whether text grew.</summary>
    public static int DisplayWidth(string text)
    {
        int width = 0;
        foreach (char c in text)
            width += c >= 'ᄀ' && (c <= 'ᅟ' || c >= '⺀' && c <= '꓏' || c >= '가' && c <= '힣' || c >= '豈' && c <= '﫿' || c >= '︰' && c <= '﹏' || c >= '＀' && c <= '｠' || c >= '￠' && c <= '￦') ? 2 : 1;
        return width;
    }

    /// <summary>Key of the run properties: their XML without the listed attributes and child elements.</summary>
    public static string PropertiesKey(XElement? properties, ISet<string> dropElements, ISet<string> dropAttributes)
    {
        if (properties is null)
            return "";
        var copy = new XElement(properties);
        foreach (var element in copy.DescendantsAndSelf().ToList())
        {
            if (element != copy && dropElements.Contains(element.Name.LocalName))
            {
                element.Remove();
                continue;
            }
            foreach (var attribute in element.Attributes().Where(a => dropAttributes.Contains(a.Name.LocalName)).ToList())
                attribute.Remove();
        }
        if (!copy.HasElements && !copy.Attributes().Any(a => !a.IsNamespaceDeclaration))
            return ""; // empty properties look like none
        var key = new StringBuilder();
        Append(copy, key);
        return key.ToString();

        static void Append(XElement element, StringBuilder key)
        {
            key.Append('<').Append(element.Name.LocalName);
            foreach (var attribute in element.Attributes().Where(a => !a.IsNamespaceDeclaration).OrderBy(a => a.Name.ToString()))
                key.Append(' ').Append(attribute.Name.LocalName).Append('=').Append(attribute.Value);
            key.Append('>');
            foreach (var child in element.Elements())
                Append(child, key);
            key.Append("</>");
        }
    }
}
