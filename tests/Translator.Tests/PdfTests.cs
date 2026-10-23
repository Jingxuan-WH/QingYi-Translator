using PdfSharp.Drawing;
using PdfSharp.Pdf;
using Translator.Core;
using Translator.Core.FileTranslation;
using Xunit;
using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace Translator.Tests;

/// <summary>Characters laid out like a typesetter would, for testing the layout analysis without a PDF.</summary>
internal static class Glyphs
{
    public static bool IsCjk(char c) => c >= '⺀';

    public static double Width(string text, double size) => text.Sum(c => c == ' ' ? 0.25 * size : IsCjk(c) ? size : 0.5 * size);

    public static List<PdfGlyph> Line(string text, double x, double baseline, double size = 10, string font = "Times-Roman")
    {
        var glyphs = new List<PdfGlyph>();
        foreach (char c in text)
        {
            double width = c == ' ' ? 0.25 * size : IsCjk(c) ? size : 0.5 * size;
            if (c != ' ')
                glyphs.Add(new PdfGlyph(c.ToString(), x, baseline - 0.2 * size, x + width, baseline + 0.7 * size, size, font, 0));
            x += width;
        }
        return glyphs;
    }

    /// <summary>Wraps words into lines between x0 and x1, the first line indented.</summary>
    public static List<PdfGlyph> Paragraph(string text, double x0, double x1, double baseline, double pitch, double indent = 10, double size = 10)
    {
        var glyphs = new List<PdfGlyph>();
        var line = "";
        double start = x0 + indent;
        foreach (string word in text.Split(' '))
        {
            string candidate = line.Length == 0 ? word : line + " " + word;
            if (start + Width(candidate, size) > x1 && line.Length > 0)
            {
                glyphs.AddRange(Line(line, start, baseline, size));
                baseline -= pitch;
                start = x0;
                line = word;
            }
            else
            {
                line = candidate;
            }
        }
        glyphs.AddRange(Line(line, start, baseline, size));
        return glyphs;
    }

    public const string Text1 = "Microgrids are small power systems that can run connected to the main grid or on their own, and they have been studied";
    public const string Text2 = "Their control is usually organised in three layers, from fast local loops to slow economic dispatch of all the units.";
    public static readonly string[] Text3 =
    [
        "Droop control shares the load among",
        "inverters without any communication,",
        "which keeps the distri-",
        "bution of power robust and simple.",
    ];

    /// <summary>A two-column page: title, two paragraphs on the left, a paragraph, a formula, a heading and a reference on the right.</summary>
    public static List<PdfGlyph> TwoColumnPage()
    {
        var glyphs = new List<PdfGlyph>();
        const string title = "A Study of Microgrids";
        glyphs.AddRange(Line(title, 300 - Width(title, 20) / 2, 760, 20, "Times-Bold"));
        glyphs.AddRange(Paragraph(Text1, 50, 290, 700, 12));
        // A superscript footnote mark after "studied".
        var last = glyphs[^1];
        glyphs.Add(new PdfGlyph("1", last.X1, last.Y0 + 4, last.X1 + 3, last.Y0 + 9, 6, "Times-Roman", 0));
        double next = glyphs.Where(g => g.FontSize == 10).Min(g => g.Y0) + 0.2 * 10 - 12;
        glyphs.AddRange(Paragraph(Text2, 50, 290, next, 12));
        for (int i = 0; i < Text3.Length; i++)
            glyphs.AddRange(Line(Text3[i], i == 0 ? 320 : 310, 700 - 12 * i));
        glyphs.AddRange(Line("∑ α ≤ β + γ", 400, 630, 10, "CMMI10"));
        glyphs.AddRange(Line("References", 310, 600, 10, "Times-Bold"));
        glyphs.AddRange(Line("[1] A. Author, A paper on grids, 2020.", 310, 585, 10));
        return glyphs;
    }
}

public class PdfLayoutTests
{
    [Fact]
    public void FindsColumnsParagraphsFormulasAndReadingOrder()
    {
        var blocks = PdfLayout.Analyze(Glyphs.TwoColumnPage(), 600, 800);
        var texts = blocks.Select(b => b.Text).ToList();
        Assert.Equal(7, blocks.Count);
        Assert.Equal("A Study of Microgrids", texts[0]);
        Assert.StartsWith("Microgrids are small power systems", texts[1]);
        Assert.EndsWith("have been studied1", texts[1]); // the superscript stays in its line
        Assert.StartsWith("Their control is usually organised", texts[2]);
        Assert.Contains("the distribution of power", texts[3]); // hyphenation undone
        Assert.True(blocks[4].IsFormula);
        Assert.Equal("References", texts[5]);
        Assert.True(blocks[5].Bold);
        Assert.StartsWith("[1] A. Author", texts[6]);

        Assert.True(blocks[0].Centered);
        Assert.Equal(20, blocks[0].FontSize);
        Assert.Equal(12, blocks[1].LinePitch, 3);
        Assert.InRange(blocks[1].X1, 280, 290);
        Assert.InRange(blocks[3].X0, 309, 311);
    }

    [Fact]
    public void ChineseLinesJoinWithoutSpaces()
    {
        var glyphs = Glyphs.Line("微电网是一种小型电力系统，", 50, 700).Concat(Glyphs.Line("可以并网运行。", 50, 687)).ToList();
        var block = Assert.Single(PdfLayout.Analyze(glyphs, 600, 800));
        Assert.Equal("微电网是一种小型电力系统，可以并网运行。", block.Text);
    }

    [Fact]
    public void InlineMathBecomesAnObject()
    {
        var glyphs = Glyphs.Line("where", 50, 700).Concat(Glyphs.Line("α", 80, 700, 10, "CMMI10")).Concat(Glyphs.Line("is the angle", 90, 700)).ToList();
        var block = Assert.Single(PdfLayout.Analyze(glyphs, 600, 800));
        Assert.False(block.IsFormula);
        Assert.Equal([InlinePiece.Of("where ", 0), InlinePiece.Object(0, "α"), InlinePiece.Of(" is the angle", 0)], block.Pieces);
    }

    /// <summary>"V_cell = E_Nernst − η_act − η_ohm − η_conc   (1)" as a typesetter draws it: italic letters, smaller and lower subscripts.</summary>
    private static List<PdfGlyph> FormulaLine(double baseline, bool numbered)
    {
        var glyphs = new List<PdfGlyph>();
        double x = 200;
        void Put(string text, double size = 10, string font = "Times-Italic", double dy = 0)
        {
            glyphs.AddRange(Glyphs.Line(text, x, baseline + dy, size, font));
            x += Glyphs.Width(text, size);
        }
        Put("V");
        Put("cell", 7, "Times-Roman", -2.5);
        Put(" = ", font: "Times-Roman");
        Put("E");
        Put("Nernst", 7, "Times-Roman", -2.5);
        foreach (string loss in new[] { "act", "ohm", "conc" })
        {
            Put(" − ", font: "Times-Roman");
            Put("η");
            Put(loss, 7, "Times-Roman", -2.5);
        }
        if (numbered)
            glyphs.AddRange(Glyphs.Line("(1)", 520, baseline));
        return glyphs;
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void DisplayFormulasAreLeftAloneWithOrWithoutANumber(bool numbered)
    {
        // Close below and above paragraph lines: the formula must not join them.
        var glyphs = Glyphs.Line("The cell voltage follows from the Nernst voltage minus three losses,", 50, 700)
            .Concat(FormulaLine(688, numbered))
            .Concat(Glyphs.Line("where each loss grows with the current drawn from the stack.", 50, 676)).ToList();
        var blocks = PdfLayout.Analyze(glyphs, 600, 800);
        var formula = Assert.Single(blocks, b => b.Text.Contains('='));
        Assert.True(formula.IsFormula);
        Assert.Contains("Nernst", formula.Text);
        Assert.Equal(2, blocks.Count(b => !b.IsFormula));
        Assert.All(blocks.Where(b => !b.IsFormula), b => Assert.DoesNotContain("η", b.Text));
    }

    [Fact]
    public void ProseWithAnEqualsSignIsNotAFormula()
    {
        var block = Assert.Single(PdfLayout.Analyze(Glyphs.Line("The rated power P = 5 kW is reached at noon on most sunny days.", 50, 700), 600, 800));
        Assert.False(block.IsFormula);
    }

    [Fact]
    public void SubscriptsBecomeObjectsThatKeepTheirPlace()
    {
        var glyphs = Glyphs.Line("The voltage", 50, 700).Concat(Glyphs.Line("V", 108, 700, 10, "Times-Italic"))
            .Concat(Glyphs.Line("cell", 113, 697.5, 7)).Concat(Glyphs.Line("drops by 5%.", 130, 700)).ToList();
        var block = Assert.Single(PdfLayout.Analyze(glyphs, 600, 800));
        Assert.Equal([InlinePiece.Of("The voltage ", 0), InlinePiece.Object(0, "Vcell"), InlinePiece.Of(" drops by 5%.", 0)], block.Pieces);
        var atom = block.Atoms[0];
        Assert.Equal(["V", "c", "e", "l", "l"], atom.Glyphs.Select(g => g.Text));
        Assert.Equal(0, atom.Glyphs[0].Dx);
        Assert.InRange(atom.Glyphs[0].Dy, -0.5, 0.5);
        Assert.Equal(5, atom.Glyphs[1].Dx, 3);
        Assert.InRange(atom.Glyphs[1].Dy, -3, -2); // lower
        Assert.Equal(7, atom.Glyphs[1].FontSize);
        Assert.Equal(19, atom.Width, 3);
    }

    [Fact]
    public void BoldTextGetsItsOwnStyle()
    {
        var glyphs = Glyphs.Line("Abstract—", 50, 700, 10, "Times-Bold").Concat(Glyphs.Line("This paper studies small grids.", 100, 700)).ToList();
        var block = Assert.Single(PdfLayout.Analyze(glyphs, 600, 800));
        Assert.Equal([InlinePiece.Of("Abstract— ", 1), InlinePiece.Of("This paper studies small grids.", 0)], block.Pieces);
    }

    [Fact]
    public void ListItemsAndIndentedParagraphsAreSeparateBlocks()
    {
        var glyphs = Glyphs.Line("• First item of the list", 50, 700).Concat(Glyphs.Line("• Second item of the list", 50, 688)).ToList();
        Assert.Equal(2, PdfLayout.Analyze(glyphs, 600, 800).Count);
    }

    [Fact]
    public void FontNamesAreClassified()
    {
        Assert.True(PdfLayout.IsBoldFont("ABCDEF+TimesNewRomanPS-BoldMT"));
        Assert.False(PdfLayout.IsBoldFont("Times-Roman"));
        Assert.True(PdfLayout.IsSerifFont("ABCDEF+CMR10"));
        Assert.True(PdfLayout.IsSerifFont("SimSun"));
        Assert.False(PdfLayout.IsSerifFont("Arial-BoldMT"));
        Assert.True(PdfLayout.IsMathGlyph(new PdfGlyph("x", 0, 0, 1, 1, 10, "XYZABC+CMMI10", 0)));
        Assert.False(PdfLayout.IsMathGlyph(new PdfGlyph("x", 0, 0, 1, 1, 10, "Times-Italic", 0)));
    }
}

public class PdfTextFitterTests
{
    private static double Measure(string text) => Glyphs.Width(text, 1);

    [Fact]
    public void ChineseBreaksAnywhereButNotBeforeClosingPunctuation()
    {
        var fitted = PdfTextFitter.Fit("一二三四五，六七八", 50, 100, 10, 1.2, Measure, justify: false);
        Assert.Equal(10, fitted.FontSize);
        Assert.Equal(["一二三四", "五，六七八"], fitted.Lines.Select(l => string.Concat(l.Pieces.Select(p => p.Text))));
    }

    [Fact]
    public void LatinBreaksAtSpacesAndShrinksToFit()
    {
        var roomy = PdfTextFitter.Fit("alpha beta gamma delta", 200, 20, 10, 1.2, Measure, justify: false);
        Assert.Single(roomy.Lines);
        Assert.Equal(10, roomy.FontSize);
        var tight = PdfTextFitter.Fit("alpha beta gamma delta epsilon zeta eta theta", 60, 22, 10, 1.2, Measure, justify: false);
        Assert.True(tight.FontSize < 10);
        Assert.False(tight.Overflows);
        Assert.True((tight.Lines.Count - 1) * tight.LinePitch + tight.FontSize <= 22 + 0.15 * tight.FontSize);
        Assert.All(tight.Lines, line => Assert.True(line.Width <= 60.01));
    }

    [Fact]
    public void GivesUpShrinkingAtHalfSize()
    {
        var fitted = PdfTextFitter.Fit(string.Concat(Enumerable.Repeat("很长的文字", 40)), 50, 10, 10, 1.2, Measure, justify: false);
        Assert.True(fitted.Overflows);
        Assert.InRange(fitted.FontSize, 5, 5.3);
    }

    [Fact]
    public void RunsKeepTheirStyles()
    {
        // Style 1 is twice as wide, like a bigger font.
        var fitted = PdfTextFitter.Fit([new TextRun("alpha ", 0), new TextRun("beta", 1), new TextRun(" gamma", 0)], 200, 20, 10, 1.2,
            (text, style) => Glyphs.Width(text, 1) * (style == 1 ? 2 : 1), justify: false);
        var line = Assert.Single(fitted.Lines);
        Assert.Equal([("alpha", 0), ("beta", 1), ("gamma", 0)], line.Pieces.Select(p => (p.Text, p.Style)));
        Assert.Equal([0, 30, 72.5], line.Pieces.Select(p => Math.Round(p.X, 3)));
        Assert.Equal(97.5, line.Width, 3);
    }

    [Fact]
    public void JustifiedLinesFillTheWidthExceptTheLast()
    {
        var fitted = PdfTextFitter.Fit("aaaa bbbb cccc dddd eeee ffff", 70, 100, 10, 1.2, Measure, justify: true);
        Assert.True(fitted.Lines.Count >= 2);
        Assert.Equal(70, fitted.Lines[0].Width, 3);
        Assert.True(fitted.Lines[^1].Width < 70);
    }
}

public class PdfDocumentTests
{
    static PdfDocumentTests()
    {
        // Use fonts that exist on Linux test machines; on Windows the normal lookup finds Times New Roman, Arial and the CJK fonts.
        const string liberation = "/usr/share/fonts/truetype/liberation/";
        const string chinese = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc";
        const string dejavu = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
        if (File.Exists(liberation + "LiberationSerif-Regular.ttf"))
        {
            PdfFonts.Override = face => face switch
            {
                "latin-serif" => liberation + "LiberationSerif-Regular.ttf",
                "latin-serif-bold" => liberation + "LiberationSerif-Bold.ttf",
                "latin-sans" => liberation + "LiberationSans-Regular.ttf",
                "latin-sans-bold" => liberation + "LiberationSans-Bold.ttf",
                "latin-serif-italic" => liberation + "LiberationSerif-Italic.ttf",
                "latin-serif-bold-italic" => liberation + "LiberationSerif-BoldItalic.ttf",
                "latin-sans-italic" => liberation + "LiberationSans-Italic.ttf",
                "latin-sans-bold-italic" => liberation + "LiberationSans-BoldItalic.ttf",
                "math" or "symbol" when File.Exists(dejavu) => dejavu,
                _ when face.StartsWith("zh") && File.Exists(chinese) => chinese,
                _ => null,
            };
        }
        PdfFonts.Install();
    }

    private static string CreateSamplePdf()
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-pdf").FullName, "paper.pdf");
        using var document = new PdfSharp.Pdf.PdfDocument();
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(595);
        page.Height = XUnit.FromPoint(842);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            var title = new XFont("latin-serif-bold", 18);
            var body = new XFont("latin-serif", 10);
            gfx.DrawRectangle(new XSolidBrush(XColor.FromArgb(230, 240, 255)), 60, 140, 475, 60);
            gfx.DrawString("Control of Small Power Grids", title, XBrushes.Black, new XRect(0, 80, 595, 30), XStringFormats.Center);
            string[] lines =
            [
                "Small power grids can run connected to the main grid or alone.",
                "Their control is organised in layers, from fast local loops",
                "to the slow economic dispatch of all generating units.",
            ];
            for (int i = 0; i < lines.Length; i++)
                gfx.DrawString(lines[i], body, XBrushes.Black, 70, 160 + 12 * i, XStringFormats.BaseLineLeft);
            gfx.DrawLine(XPens.Black, 60, 260, 535, 260);
        }
        document.Save(path);
        return path;
    }

    [Fact]
    public void ReadsBlocksAndWritesTheTranslationIntoTheSameBoxes()
    {
        string path = CreateSamplePdf();
        var document = new PdfDocumentFile(path);
        Assert.Equal(2, document.Segments.Count);
        Assert.Equal("Control of Small Power Grids", document.Segments[0].PlainText);
        Assert.Equal(SegmentRole.Title, document.Segments[0].Role);
        Assert.StartsWith("Small power grids can run connected", document.Segments[1].PlainText);
        Assert.Contains("from fast local loops to the slow", document.Segments[1].PlainText);

        string output = OutputPaths.For(path, Languages.English);
        string bilingual = OutputPaths.For(path, Languages.English, "bilingual");
        document.Save(output, new Dictionary<int, string>
        {
            [0] = "GRID CONTROL",
            [1] = "TRANSLATED PARAGRAPH that is a good deal longer than the original paragraph was, so the font has to shrink to fit the box. "
                + "It goes on for a while longer, adding more and more words, until it clearly can't fit at the original size any more.",
        }, new DocumentSaveOptions(Languages.English, bilingual));

        using var result = PigDocument.Open(output);
        Assert.Equal(1, result.NumberOfPages);
        var page = result.GetPage(1);
        string text = string.Concat(page.Letters.Select(l => l.Value));
        Assert.Contains("GRIDCONTROL", text.Replace(" ", ""));
        Assert.Contains("TRANSLATEDPARAGRAPH", text.Replace(" ", ""));
        // The original text is gone, not just covered.
        Assert.DoesNotContain("Smallpowergrids", text.Replace(" ", ""));
        Assert.DoesNotContain("Control of Small", text);
        // The new paragraph stays within the original paragraph's box (x 70…~350, y 842-184…842-150).
        var translated = page.Letters.Where(l => l.BoundingBox.Top < 842 - 140 && l.BoundingBox.Bottom > 842 - 200 && l.PointSize < 10.5).ToList();
        Assert.NotEmpty(translated);
        Assert.All(translated, l => Assert.InRange(l.BoundingBox.Left, 69, 360));
        Assert.True(translated.Max(l => l.PointSize) < 10, "the font was shrunk");
        Assert.Contains(page.Paths, p => p.IsFilled && p.FillColor is { } c && Math.Abs(c.ToRGBValues().b - 1) < 0.01 && c.ToRGBValues().r < 0.95);

        using var both = PigDocument.Open(bilingual);
        Assert.Equal(2, both.NumberOfPages);
    }

    [Fact]
    public void WritesChineseWithAnEmbeddedFont()
    {
        if (!PdfFonts.FaceFor(Languages.SimplifiedChinese, "中文", false, false).StartsWith("zh"))
            return; // no Chinese font on this machine
        string path = CreateSamplePdf();
        var document = new PdfDocumentFile(path);
        string output = OutputPaths.For(path, Languages.SimplifiedChinese);
        document.Save(output, new Dictionary<int, string> { [0] = "小型电网的控制", [1] = "小型电网可以并网运行，也可以独立运行。" },
            new DocumentSaveOptions(Languages.SimplifiedChinese));
        using var result = PigDocument.Open(output);
        string text = string.Concat(result.GetPage(1).Letters.Select(l => l.Value));
        Assert.Contains("小型电网的控制", text);
        Assert.Contains("独立运行", text);
        Assert.True(new FileInfo(output).Length < 2_000_000, "only the used characters are embedded");
    }

    /// <summary>
    /// A paragraph, a numbered display formula (italic letters, subscripts, minus signs, Greek letters) and a paragraph
    /// with an inline Greek letter with a subscript and a symbol that only the math font has.
    /// </summary>
    private static string CreateFormulaPdf()
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-formula").FullName, "formula.pdf");
        using var document = new PdfSharp.Pdf.PdfDocument();
        var page = document.AddPage();
        page.Width = XUnit.FromPoint(595);
        page.Height = XUnit.FromPoint(842);
        using (var gfx = XGraphics.FromPdfPage(page))
        {
            var body = new XFont("latin-serif", 10);
            var bold = new XFont("latin-serif-bold", 10);
            var italic = new XFont("latin-serif-italic", 10);
            var small = new XFont("latin-serif", 7);
            var math = new XFont("math", 10);
            double x = 0, y = 0;
            void At(double left, double baseline) => (x, y) = (left, baseline);
            void Put(string text, XFont font, double dy = 0)
            {
                gfx.DrawString(text, font, XBrushes.Black, x, y + dy, XStringFormats.BaseLineLeft);
                x += gfx.MeasureString(text, font).Width;
            }

            At(70, 160);
            Put("Abstract—", bold);
            Put(" The cell voltage follows from the Nernst voltage minus three losses of the stack,", body);
            At(70, 172);
            Put("as given in the equation below for every operating point of the system.", body);
            At(200, 200);
            Put("V", italic);
            Put("cell", small, 2.5);
            Put(" = ", body);
            Put("E", italic);
            Put("Nernst", small, 2.5);
            foreach (string loss in new[] { "act", "ohm", "conc" })
            {
                Put(" − ", body);
                Put("η", italic);
                Put(loss, small, 2.5);
            }
            At(515, 200);
            Put("(1)", body);
            At(70, 230);
            Put("The loss ", body);
            Put("η", italic);
            Put("act", small, 2.5);
            Put(" grows with the current, while the product a", body);
            Put("⋅", math);
            Put("b stays small at every load.", body);
        }
        document.Save(path);
        return path;
    }

    /// <summary>Saves a Chinese translation of the two paragraphs, keeping the objects of the second one.</summary>
    private static string TranslateFormulaPdf(string path, PdfDocumentFile document)
    {
        var intro = Assert.Single(document.Segments, s => s.PlainText.Contains("Nernst voltage"));
        var paragraph = Assert.Single(document.Segments, s => s.PlainText.Contains("grows with the current"));
        var atoms = System.Text.RegularExpressions.Regex.Matches(paragraph.Text.Text, "<\\d+/>").Select(m => m.Value).ToList();
        Assert.Equal(2, atoms.Count);
        string output = OutputPaths.For(path, Languages.SimplifiedChinese);
        document.Save(output, new Dictionary<int, string>
        {
            [intro.Id] = "摘要—电堆电压等于能斯特电压减去三种损耗，见下式。",
            [paragraph.Id] = $"损耗{atoms[0]}随电流增大，而乘积 a{atoms[1]}b 在各种负荷下都很小。",
        }, new DocumentSaveOptions(Languages.SimplifiedChinese));
        return output;
    }

    /// <summary>The characters of the formula's line (baseline 842 − 200), with their positions and sizes.</summary>
    private static List<(string, double, double, double)> FormulaLetters(UglyToad.PdfPig.Content.Page page) =>
        page.Letters.Where(l => l.StartBaseLine.Y is > 842 - 206 and < 842 - 194)
            .Select(l => (l.Value, Math.Round(l.StartBaseLine.X, 1), Math.Round(l.StartBaseLine.Y, 1), Math.Round(l.PointSize, 1))).ToList();

    [Fact]
    public void DisplayFormulasStayExactlyAsTheyWere()
    {
        string path = CreateFormulaPdf();
        var document = new PdfDocumentFile(path);
        // The two paragraphs; the formula and its number aren't sent for translation.
        Assert.Equal(2, document.Segments.Count);
        Assert.DoesNotContain(document.Segments, s => s.PlainText.Contains('='));
        string output = TranslateFormulaPdf(path, document);

        using var before = PigDocument.Open(path);
        using var after = PigDocument.Open(output);
        var original = FormulaLetters(before.GetPage(1));
        Assert.Equal(3, original.Count(l => l.Item1 == "−"));
        Assert.Equal(original, FormulaLetters(after.GetPage(1)));
    }

    [Fact]
    public void SymbolsAndSubscriptsInTheTextAreNeverDropped()
    {
        string path = CreateFormulaPdf();
        string output = TranslateFormulaPdf(path, new PdfDocumentFile(path));

        using var result = PigDocument.Open(output);
        var letters = result.GetPage(1).Letters.Where(l => l.StartBaseLine.Y < 842 - 210).ToList(); // the translated last paragraph
        Assert.Contains("随电流增大", string.Concat(letters.Select(l => l.Value)));
        Assert.DoesNotContain("grows", string.Concat(letters.Select(l => l.Value)));
        Assert.Contains(letters, l => l.Value == "⋅"); // the CJK and Latin fonts lack it; the math font has it
        // η keeps its subscript: smaller and lower.
        int eta = letters.FindIndex(l => l.Value == "η");
        Assert.True(eta >= 0);
        Assert.Equal("act", string.Concat(letters.Skip(eta + 1).Take(3).Select(l => l.Value)));
        Assert.All(letters.Skip(eta + 1).Take(3), l =>
        {
            Assert.True(l.PointSize < letters[eta].PointSize * 0.85);
            Assert.True(l.StartBaseLine.Y < letters[eta].StartBaseLine.Y - 1);
        });
        // Latin letters come from a Latin font, not the CJK font's half-width forms.
        var b = Assert.Single(letters, l => l.Value == "b");
        Assert.DoesNotContain("zenhei", b.FontName.ToLowerInvariant());
        Assert.DoesNotContain("simsun", b.FontName.ToLowerInvariant());
        Assert.DoesNotContain("yahei", b.FontName.ToLowerInvariant());
    }

    [Fact]
    public void BoldTextStaysBold()
    {
        string path = CreateFormulaPdf();
        var document = new PdfDocumentFile(path);
        Assert.StartsWith("<1>Abstract—</1>", document.Segments[0].Text.Text);
        string output = OutputPaths.For(path, Languages.English);
        document.Save(output, new Dictionary<int, string> { [0] = "<1>Summary—</1> We derive the voltage of the stack." },
            new DocumentSaveOptions(Languages.English));
        using var result = PigDocument.Open(output);
        var letters = result.GetPage(1).Letters.Where(l => l.StartBaseLine.Y > 842 - 180).ToList();
        Assert.Contains("bold", Assert.Single(letters, l => l.Value == "S").FontName.ToLowerInvariant());
        Assert.DoesNotContain("bold", Assert.Single(letters, l => l.Value == "W").FontName.ToLowerInvariant());
    }

    [Fact]
    public void ScannedPdfsAreRejected()
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-scan").FullName, "scan.pdf");
        using (var document = new PdfSharp.Pdf.PdfDocument())
        {
            document.AddPage();
            document.AddPage();
            document.Save(path);
        }
        var error = Assert.Throws<DocumentException>(() => DocumentLoader.Open(path));
        Assert.Contains("OCR", error.Message);
    }

    [Fact]
    public void ExtractsOneFontFromACollection()
    {
        const string collection = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc";
        string windows = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "msyh.ttc");
        string? file = File.Exists(collection) ? collection : File.Exists(windows) ? windows : null;
        if (file is null)
            return;
        byte[] font = PdfFonts.ExtractFromCollection(File.ReadAllBytes(file), 0);
        Assert.Equal([0, 1, 0, 0], font[..4]); // a TrueType font header
        Assert.True(font.Length > 100_000);
    }
}
