using System.Text;

namespace Translator.Core.FileTranslation;

/// <summary>One character on a PDF page, in PDF user space (origin bottom left, y up).</summary>
/// <param name="Color">0xRRGGBB.</param>
public readonly record struct PdfGlyph(string Text, double X0, double Y0, double X1, double Y1, double FontSize, string FontName, int Color)
{
    public double CenterY => (Y0 + Y1) / 2;
    public double Height => Y1 - Y0;
    public bool IsBold => PdfLayout.IsBoldFont(FontName);
}

/// <summary>A line of text within one column.</summary>
public sealed class PdfLine
{
    public PdfLine(IEnumerable<PdfGlyph> glyphs)
    {
        Glyphs = glyphs.ToList();
        X0 = Glyphs.Min(g => g.X0);
        X1 = Glyphs.Max(g => g.X1);
        Y0 = Glyphs.Min(g => g.Y0);
        Y1 = Glyphs.Max(g => g.Y1);
    }

    public List<PdfGlyph> Glyphs { get; }
    public double X0 { get; }
    public double X1 { get; }
    public double Y0 { get; }
    public double Y1 { get; }
    public double FontSize { get; set; }
    public bool Bold { get; set; }

    /// <summary>Which row of the page the line came from; lines of one row were split at wide gaps.</summary>
    public int Row { get; init; }

    /// <summary>Shares its row with other text on the same side of the column gap: a table cell, a label, an equation number.</summary>
    public bool Tabular { get; set; }
}

/// <summary>A paragraph (or heading, caption, table cell…) found on a page.</summary>
public sealed class PdfBlock
{
    private readonly List<PdfLine> _lines = [];

    public IReadOnlyList<PdfLine> Lines => _lines;
    public double X0 { get; private set; } = double.MaxValue;
    public double X1 { get; private set; } = double.MinValue;
    public double Y0 { get; private set; } = double.MaxValue;
    public double Y1 { get; private set; } = double.MinValue;

    public void Add(PdfLine line)
    {
        _lines.Add(line);
        X0 = Math.Min(X0, line.X0);
        X1 = Math.Max(X1, line.X1);
        Y0 = Math.Min(Y0, line.Y0);
        Y1 = Math.Max(Y1, line.Y1);
    }

    public double FontSize { get; set; }
    public bool Bold { get; set; }
    public bool Italic { get; set; }
    public bool Serif { get; set; }
    public int Color { get; set; }
    public bool Centered { get; set; }
    public bool Justified { get; set; }
    public bool IsFormula { get; set; }

    /// <summary>The text with inline formulas as objects; their text is kept for drawing.</summary>
    public List<InlinePiece> Pieces { get; set; } = [];
    public string Text => string.Concat(Pieces.Select(p => p.Text));
    public string WordsText => string.Concat(Pieces.Where(p => !p.IsAtom).Select(p => p.Text));

    /// <summary>How far the first line starts right of the others (a paragraph indent); 0 for single lines.</summary>
    public double FirstLineIndent { get; set; }

    /// <summary>Distance between the baselines of two lines; for a single line, 1.2 × the font size.</summary>
    public double LinePitch { get; set; }

    /// <summary>The page's background behind the text, 0xRRGGBB; used to cover the original text.</summary>
    public int Background { get; set; } = 0xFFFFFF;
}

/// <summary>
/// Finds lines, columns, paragraphs and formulas among the characters of a PDF page. The PDF only knows where
/// each character is drawn; this rebuilds the reading structure the way BabelDOC and PDFMathTranslate do in
/// spirit (written from scratch here): rows by vertical position, superscripts folded into their line, rows
/// split at column gaps, lines stacked into paragraphs by spacing, indentation and font, then ordered by column.
/// </summary>
public static class PdfLayout
{
    private static readonly string[] MathFonts =
        ["cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msam", "msbm", "math", "symbol", "mtextra", "mt extra", "stix", "euclid", "esint", "rsfs", "wasy", "lmmi", "lmsy", "mtmi", "mtsy", "mathematicalpi", "eufm", "eusm", "bbold", "dsrom"];

    private static readonly string[] SerifHints =
        ["times", "serif", "roman", "minion", "garamond", "georgia", "cambria", "palatino", "book", "cmr", "lmroman", "nimbusrom", "termes", "pagella", "song", "ming", "mincho", "kai", "fang", "batang", "charter", "century", "baskerville", "utopia", "stixtwo", "libertine", "sabon", "caslon", "bodoni", "simsun", "stsong", "fzss"];

    private const string Bullets = "•·▪▫◦●○■□♦◆➢➤►▶✓✔-–—*";

    public static bool IsBoldFont(string name)
    {
        string lower = name.ToLowerInvariant();
        return lower.Contains("bold") || lower.Contains("black") || lower.Contains("heavy") || lower.Contains("semibold")
            || lower.Contains("demi") || lower.EndsWith(",b", StringComparison.Ordinal) || lower.Contains("-bd") || lower.Contains("cmbx")
            || lower.Contains("medi") && !lower.Contains("medium") || lower.Contains("heiti") || lower.Contains("simhei");
    }

    public static bool IsItalicFont(string name)
    {
        string lower = name.ToLowerInvariant();
        return lower.Contains("italic") || lower.Contains("oblique") || lower.Contains("-it") || lower.Contains("cmti") || lower.EndsWith(",i", StringComparison.Ordinal);
    }

    public static bool IsSerifFont(string name)
    {
        string lower = name.ToLowerInvariant().Replace(" ", "").Replace("-", "");
        if (lower.Contains("sans") || lower.Contains("arial") || lower.Contains("helvetica") || lower.Contains("gothic") || lower.Contains("hei"))
            return false;
        return SerifHints.Any(lower.Contains);
    }

    public static bool IsMathGlyph(PdfGlyph glyph)
    {
        string font = glyph.FontName.ToLowerInvariant();
        // Subset prefixes such as "ABCDEF+CMMI10" keep the real name after the plus sign.
        int plus = font.IndexOf('+');
        if (plus >= 0)
            font = font[(plus + 1)..];
        if (MathFonts.Any(font.Contains))
            return true;
        foreach (char c in glyph.Text)
        {
            if (c is >= '∀' and <= '⋿' or >= '⟀' and <= '⟯' or >= '⦀' and <= '⫿' or >= 'Α' and <= 'ω'
                or '∂' or '∇' or '∞' or '√' or '∑' or '∏' or '∫' or '±' or '×' or '÷' or '≤' or '≥' or '≠' or '≈' or '→' or '←' or '↔' or '⇒' or '⇔')
                return true;
            if (char.IsSurrogate(c))
                return true; // mathematical alphanumerics (U+1D400…) and other symbols outside the basic plane
        }
        return false;
    }

    private static bool IsCjk(char c) =>
        c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿' or >= '＀' and <= '￯' or >= '　' and <= '〿';

    /// <summary>Finds the text blocks of one page, in reading order.</summary>
    public static List<PdfBlock> Analyze(IReadOnlyList<PdfGlyph> pageGlyphs, double pageWidth, double pageHeight)
    {
        var glyphs = Clean(pageGlyphs, pageWidth, pageHeight);
        if (glyphs.Count == 0)
            return [];
        double bodySize = Median(glyphs.Select(g => g.FontSize));
        var rows = BuildRows(glyphs);
        var segments = SplitRows(rows);
        double? gutter = FindGutter(segments, pageWidth);
        if (gutter is { } g)
            segments = segments.SelectMany(line => SplitAtGutter(line, g)).ToList();
        foreach (var row in segments.GroupBy(line => (line.Row, Side: gutter is { } at ? (line.X1 <= at ? -1 : line.X0 >= at ? 1 : 0) : 0)))
        {
            if (row.Count() > 1)
            {
                foreach (var line in row)
                    line.Tabular = true;
            }
        }
        var blocks = BuildBlocks(segments);
        foreach (var block in blocks)
            Describe(block, pageWidth);
        return Order(blocks, gutter, bodySize);
    }

    /// <summary>Drops spaces, empty boxes and characters drawn twice on top of each other (a common fake-bold trick).</summary>
    private static List<PdfGlyph> Clean(IReadOnlyList<PdfGlyph> glyphs, double width, double height)
    {
        var result = new List<PdfGlyph>(glyphs.Count);
        var seen = new Dictionary<string, List<PdfGlyph>>();
        foreach (var glyph in glyphs)
        {
            if (string.IsNullOrWhiteSpace(glyph.Text) || glyph.X1 <= glyph.X0 || glyph.Y1 <= glyph.Y0 || glyph.FontSize <= 0.5)
                continue;
            if (glyph.X1 < -10 || glyph.X0 > width + 10 || glyph.Y1 < -10 || glyph.Y0 > height + 10)
                continue;
            if (!seen.TryGetValue(glyph.Text, out var same))
                seen[glyph.Text] = same = [];
            double near = 0.15 * glyph.FontSize;
            if (same.Any(other => Math.Abs(other.X0 - glyph.X0) < near && Math.Abs(other.Y0 - glyph.Y0) < near))
                continue;
            same.Add(glyph);
            result.Add(glyph);
        }
        return result;
    }

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToList();
        return sorted.Count == 0 ? 0 : sorted[sorted.Count / 2];
    }

    /// <summary>Groups characters whose vertical centers agree, then folds superscripts and subscripts into the row they belong to.</summary>
    private static List<List<PdfGlyph>> BuildRows(List<PdfGlyph> glyphs)
    {
        // Characters of one line share a centre (their boxes span the font's height); lines are a font size or more apart.
        var sorted = glyphs.OrderByDescending(g => g.CenterY).ThenBy(g => g.X0).ToList();
        var rows = new List<List<PdfGlyph>>();
        var current = new List<PdfGlyph>();
        PdfGlyph previous = default;
        foreach (var glyph in sorted)
        {
            if (current.Count > 0 && previous.CenterY - glyph.CenterY <= 0.3 * Math.Max(previous.FontSize, glyph.FontSize))
            {
                current.Add(glyph);
            }
            else
            {
                if (current.Count > 0)
                    rows.Add(current);
                current = [glyph];
            }
            previous = glyph;
        }
        if (current.Count > 0)
            rows.Add(current);

        // A glyph clearly smaller than a neighbouring row, overlapping it vertically and close to one of its
        // glyphs horizontally, is a superscript or subscript of that row (citations¹, x_i).
        var rowSize = rows.Select(row => Median(row.Select(g => g.FontSize))).ToList();
        for (int r = 0; r < rows.Count; r++)
        {
            for (int i = rows[r].Count - 1; i >= 0; i--)
            {
                var glyph = rows[r][i];
                for (int q = Math.Max(0, r - 2); q <= Math.Min(rows.Count - 1, r + 2); q++)
                {
                    if (q == r || rows[q].Count == 0 || rowSize[q] < glyph.FontSize * 1.15)
                        continue;
                    double top = Math.Min(glyph.Y1, rows[q].Max(g => g.Y1));
                    double bottom = Math.Max(glyph.Y0, rows[q].Min(g => g.Y0));
                    if (top - bottom < 0.3 * glyph.Height)
                        continue;
                    double reach = 1.5 * rowSize[q];
                    if (!rows[q].Any(g => glyph.X0 - g.X1 < reach && g.X0 - glyph.X1 < reach))
                        continue;
                    rows[q].Add(glyph);
                    rows[r].RemoveAt(i);
                    break;
                }
            }
        }
        return rows.Where(row => row.Count > 0).ToList();
    }

    /// <summary>Splits each row where the horizontal gap is wider than a word space: columns, table cells, side notes.</summary>
    private static List<PdfLine> SplitRows(List<List<PdfGlyph>> rows)
    {
        var lines = new List<PdfLine>();
        for (int r = 0; r < rows.Count; r++)
        {
            var row = rows[r];
            var ordered = row.OrderBy(g => g.X0).ToList();
            double size = Median(ordered.Select(g => g.FontSize));
            var current = new List<PdfGlyph>();
            double right = double.MinValue;
            foreach (var glyph in ordered)
            {
                if (current.Count > 0 && glyph.X0 - right > 1.0 * size)
                {
                    lines.Add(new PdfLine(current) { Row = r });
                    current = [];
                    right = double.MinValue;
                }
                current.Add(glyph);
                right = Math.Max(right, glyph.X1);
            }
            if (current.Count > 0)
                lines.Add(new PdfLine(current) { Row = r });
        }
        foreach (var line in lines)
        {
            line.FontSize = Median(line.Glyphs.Where(g => !IsMathGlyph(g)).Select(g => g.FontSize).DefaultIfEmpty(line.Glyphs[0].FontSize));
            line.Bold = line.Glyphs.Count(g => g.IsBold) * 2 > line.Glyphs.Count;
        }
        return lines;
    }

    /// <summary>
    /// The gap between two columns: an x position in the middle of the page that few lines cross while many
    /// lines lie entirely on either side of it.
    /// </summary>
    private static double? FindGutter(List<PdfLine> lines, double pageWidth)
    {
        var body = lines.Where(line => line.Glyphs.Count >= 8).ToList();
        if (body.Count < 6)
            return null;
        double? best = null;
        int bestCrossing = int.MaxValue;
        for (double x = pageWidth * 0.3; x <= pageWidth * 0.7; x += 1)
        {
            int crossing = 0, left = 0, right = 0;
            foreach (var line in body)
            {
                if (line.X1 <= x)
                    left++;
                else if (line.X0 >= x)
                    right++;
                else
                    crossing++;
            }
            // Titles, abstracts and wide figures cross the gap on some pages, so allow a share of crossing lines.
            if (left >= body.Count * 0.25 && right >= body.Count * 0.25 && crossing <= body.Count * 0.2
                && (crossing < bestCrossing || crossing == bestCrossing && best is { } b && Math.Abs(x - pageWidth / 2) < Math.Abs(b - pageWidth / 2)))
            {
                bestCrossing = crossing;
                best = x;
            }
        }
        return best;
    }

    /// <summary>A line that runs across the column gap with a space at the gap is two lines (narrow gutters).</summary>
    private static IEnumerable<PdfLine> SplitAtGutter(PdfLine line, double gutter)
    {
        if (line.X0 >= gutter || line.X1 <= gutter)
            return [line];
        var left = line.Glyphs.Where(g => (g.X0 + g.X1) / 2 < gutter).ToList();
        var right = line.Glyphs.Where(g => (g.X0 + g.X1) / 2 >= gutter).ToList();
        if (left.Count == 0 || right.Count == 0 || right.Min(g => g.X0) - left.Max(g => g.X1) < 0.3 * line.FontSize)
            return [line];
        return [new PdfLine(left) { FontSize = line.FontSize, Bold = line.Bold, Row = line.Row }, new PdfLine(right) { FontSize = line.FontSize, Bold = line.Bold, Row = line.Row }];
    }

    private static bool StartsWithBullet(PdfLine line)
    {
        string text = string.Concat(line.Glyphs.Take(4).Select(g => g.Text));
        if (text.Length == 0)
            return false;
        if (Bullets.Contains(text[0]))
            return true;
        // "1.", "2)", "(a)", "[3]", "a)"
        int i = 0;
        if (text[0] is '(' or '[')
            i++;
        int start = i;
        while (i < text.Length && (char.IsDigit(text[i]) || i == start && char.IsLetter(text[i]) && text.Length > i + 1 && !char.IsLetter(text[i + 1])))
            i++;
        return i > start && i < text.Length && text[i] is '.' or ')' or ']' && !(i + 1 < text.Length && char.IsDigit(text[i + 1]));
    }

    /// <summary>Stacks lines into paragraphs: close below each other, overlapping horizontally, same size and weight.</summary>
    private static List<PdfBlock> BuildBlocks(List<PdfLine> lines)
    {
        var blocks = new List<PdfBlock>();
        foreach (var line in lines.OrderByDescending(l => l.Y1).ThenBy(l => l.X0))
        {
            PdfBlock? target = null;
            double bestGap = double.MaxValue;
            foreach (var block in blocks)
            {
                var last = block.Lines[^1];
                double size = Math.Max(block.FontSize, line.FontSize);
                double gap = last.Y0 - line.Y1;
                if (gap < -0.4 * size || gap > 0.9 * size)
                    continue;
                if (Math.Abs(line.FontSize - block.FontSize) > 0.1 * block.FontSize || line.Bold != block.Bold)
                    continue;
                // Table cells and labels sit next to other text on the same row; they don't continue each other.
                if (line.Tabular || last.Tabular)
                    continue;
                double overlap = Math.Min(block.X1, line.X1) - Math.Max(block.X0, line.X0);
                if (overlap < 0.5 * Math.Min(block.X1 - block.X0, line.X1 - line.X0))
                    continue;
                // A new paragraph: an indented first line after lines that start at the margin, or a list item.
                double margin = block.X0;
                if (block.Lines.Count >= 2 && line.X0 - margin > 0.8 * line.FontSize && last.X0 - margin < 0.3 * line.FontSize)
                    continue;
                if (StartsWithBullet(line) && block.Lines.Count >= 1)
                    continue;
                if (gap < bestGap)
                {
                    bestGap = gap;
                    target = block;
                }
            }
            if (target is null)
            {
                target = new PdfBlock { FontSize = line.FontSize, Bold = line.Bold };
                blocks.Add(target);
            }
            target.Add(line);
        }
        return blocks;
    }

    /// <summary>Text, inline formulas, font, colour and alignment of a block.</summary>
    private static void Describe(PdfBlock block, double pageWidth)
    {
        var glyphs = block.Lines.SelectMany(line => line.Glyphs).ToList();
        int math = glyphs.Count(IsMathGlyph);
        int letters = glyphs.Count(g => !IsMathGlyph(g) && g.Text.Any(char.IsLetter));
        block.IsFormula = math >= 0.4 * glyphs.Count || math > 0 && letters <= 3;
        var textGlyphs = glyphs.Where(g => !IsMathGlyph(g)).DefaultIfEmpty(glyphs[0]).ToList();
        block.FontSize = Median(textGlyphs.Select(g => g.FontSize));
        block.Bold = textGlyphs.Count(g => g.IsBold) * 2 > textGlyphs.Count;
        block.Italic = textGlyphs.Count(g => IsItalicFont(g.FontName)) * 2 > textGlyphs.Count;
        block.Serif = textGlyphs.Count(g => IsSerifFont(g.FontName)) * 2 > textGlyphs.Count;
        block.Color = textGlyphs.GroupBy(g => g.Color).OrderByDescending(group => group.Count()).First().Key;

        var lines = block.Lines;
        // Measured on characters of the line's own size, so superscripts don't skew it.
        double Middle(PdfLine line) => Median(line.Glyphs.Where(g => Math.Abs(g.FontSize - line.FontSize) <= 0.1 * line.FontSize)
            .Select(g => g.CenterY).DefaultIfEmpty(line.Glyphs[0].CenterY));
        block.LinePitch = lines.Count >= 2
            ? Math.Clamp((Middle(lines[0]) - Middle(lines[^1])) / (lines.Count - 1), 0.9 * block.FontSize, 2.5 * block.FontSize)
            : 1.2 * block.FontSize;

        double x0 = block.X0, x1 = block.X1, width = x1 - x0;
        if (lines.Count >= 2)
        {
            double indent = lines[0].X0 - x0;
            if (indent > 0.5 * block.FontSize && indent < 4 * block.FontSize)
                block.FirstLineIndent = indent;
            bool symmetric = lines.All(l => Math.Abs((l.X0 - x0) - (x1 - l.X1)) < 2.5);
            block.Centered = symmetric && lines.Any(l => l.X1 - l.X0 < width - 6);
            // With two lines the first one defines the right edge, so it takes three to tell.
            block.Justified = !block.Centered && lines.Count >= 3 && lines.Take(lines.Count - 1).Count(l => x1 - l.X1 < 2.0) >= 0.7 * (lines.Count - 1);
        }
        else
        {
            block.Centered = Math.Abs((x0 + x1) / 2 - pageWidth / 2) < pageWidth * 0.03 && width < pageWidth * 0.7;
        }

        block.Pieces = BuildPieces(lines);
    }

    /// <summary>The block's text: spaces where the gap between characters is wide, hyphenation at line ends undone, formulas as objects.</summary>
    private static List<InlinePiece> BuildPieces(IReadOnlyList<PdfLine> lines)
    {
        var pieces = new List<InlinePiece>();
        var text = new StringBuilder();
        var formula = new StringBuilder();
        int atoms = 0;
        char last = '\0';

        void FlushText()
        {
            if (text.Length > 0)
                pieces.Add(InlinePiece.Of(text.ToString(), 0));
            text.Clear();
        }

        void FlushFormula()
        {
            if (formula.Length == 0)
                return;
            FlushText();
            string value = formula.ToString();
            pieces.Add(InlinePiece.Object(atoms++, value.Trim()));
            formula.Clear();
            if (value.EndsWith(' '))
                text.Append(' ');
        }

        void Space()
        {
            if (formula.Length > 0)
                formula.Append(' ');
            else if (text.Length > 0 && text[^1] != ' ')
                text.Append(' ');
            else if (text.Length == 0 && pieces.Count > 0)
                text.Append(' ');
        }

        for (int l = 0; l < lines.Count; l++)
        {
            var glyphs = lines[l].Glyphs.OrderBy(g => g.X0).ToList();
            double size = lines[l].FontSize;
            if (l > 0)
            {
                char first = glyphs[0].Text[0];
                // "trans-" + "lation" → "translation"; CJK lines join without a space.
                if (last == '-' && char.IsLower(first) && text.Length > 1 && char.IsLetter(text[^2]))
                    text.Length--;
                else if (!(IsCjk(last) && IsCjk(first)))
                    Space();
            }
            for (int i = 0; i < glyphs.Count; i++)
            {
                var glyph = glyphs[i];
                if (i > 0)
                {
                    double gap = glyph.X0 - glyphs[i - 1].X1;
                    if (gap > 0.15 * size && !(IsCjk(glyphs[i - 1].Text[^1]) && IsCjk(glyph.Text[0])))
                        Space();
                }
                if (IsMathGlyph(glyph))
                {
                    if (formula.Length == 0)
                        FlushText();
                    formula.Append(glyph.Text);
                }
                else
                {
                    // Plain letters and digits right after a formula symbol (x², f(x) = …) keep the formula together.
                    if (formula.Length > 0 && (glyph.Text.All(c => !char.IsLetter(c)) && glyph.Text != "," && glyph.Text != "." || text.Length == 0 && glyph.FontSize < size * 0.85))
                    {
                        formula.Append(glyph.Text);
                    }
                    else
                    {
                        FlushFormula();
                        text.Append(glyph.Text);
                    }
                }
                last = glyph.Text[^1];
            }
        }
        FlushFormula();
        FlushText();
        if (pieces.Count > 0 && !pieces[^1].IsAtom)
            pieces[^1] = InlinePiece.Of(pieces[^1].Text.TrimEnd(), 0);
        return pieces;
    }

    /// <summary>Reading order: blocks spanning both columns cut the page into bands; in each band the left column comes first.</summary>
    private static List<PdfBlock> Order(List<PdfBlock> blocks, double? gutter, double bodySize)
    {
        if (gutter is not { } g)
            return blocks.OrderByDescending(b => Math.Round(b.Y1 / Math.Max(1, bodySize * 0.5))).ThenBy(b => b.X0).ToList();
        var result = new List<PdfBlock>();
        var band = new List<PdfBlock>();
        void FlushBand()
        {
            result.AddRange(band.Where(b => b.X1 <= g + 1).OrderByDescending(b => b.Y1));
            result.AddRange(band.Where(b => b.X1 > g + 1).OrderByDescending(b => b.Y1));
            band.Clear();
        }
        foreach (var block in blocks.OrderByDescending(b => b.Y1))
        {
            bool spanning = block.X0 < g - 1 && block.X1 > g + 1;
            if (spanning)
            {
                FlushBand();
                result.Add(block);
            }
            else
            {
                band.Add(block);
            }
        }
        FlushBand();
        return result;
    }
}
