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
        if (File.Exists(liberation + "LiberationSerif-Regular.ttf"))
        {
            PdfFonts.Override = face => face switch
            {
                "latin-serif" => liberation + "LiberationSerif-Regular.ttf",
                "latin-serif-bold" => liberation + "LiberationSerif-Bold.ttf",
                "latin-sans" => liberation + "LiberationSans-Regular.ttf",
                "latin-sans-bold" => liberation + "LiberationSans-Bold.ttf",
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
