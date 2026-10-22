using System.IO;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Exceptions;
using PigDocument = UglyToad.PdfPig.PdfDocument;
using SharpDocument = PdfSharp.Pdf.PdfDocument;

namespace Translator.Core.FileTranslation;

/// <summary>
/// A PDF with real text (not a scan). PdfPig reads where every character is; <see cref="PdfLayout"/> turns
/// them into paragraphs. The translated copy is the original file with each translated paragraph covered in
/// its background colour and the translation set into the same box (shrunk to fit), so figures, vector
/// graphics, table rules and formulas stay untouched. PDFsharp writes it.
/// </summary>
public sealed class PdfDocumentFile : TranslatableDocument
{
    private sealed record PageInfo(int Number, double Width, double Height, double Left, double Bottom);

    private readonly List<PageInfo> _pages = [];
    private readonly List<(int Page, PdfBlock Block, int Segment)> _blocks = [];

    public PdfDocumentFile(string path) : base(path)
    {
        PigDocument pdf;
        try
        {
            pdf = PigDocument.Open(path, new ParsingOptions { UseLenientParsing = true, SkipMissingFonts = true });
        }
        catch (PdfDocumentEncryptedException ex)
        {
            throw new DocumentException(Loc.T("这个 PDF 设置了打开密码，请先去掉密码再翻译。", "This PDF is password-protected. Please remove the password first."), ex);
        }

        using (pdf)
        {
            var allBlocks = new List<(int Page, PdfBlock Block)>();
            int glyphCount = 0, imagePages = 0, rotated = 0;
            var scannedPages = new List<int>();
            for (int number = 1; number <= pdf.NumberOfPages; number++)
            {
                var page = pdf.GetPage(number);
                var media = page.MediaBox.Bounds;
                _pages.Add(new PageInfo(number, page.Width, page.Height, media.Left, media.Bottom));
                var letters = page.Letters.Where(l => l.TextOrientation == TextOrientation.Horizontal).ToList();
                glyphCount += letters.Count;
                bool hasImages = page.GetImages().Any();
                if (letters.Count < 20 && hasImages)
                {
                    imagePages++;
                    scannedPages.Add(number);
                }
                if (letters.Count == 0)
                    continue;
                if (page.Rotation.Value != 0)
                {
                    // Turned pages (landscape tables) keep their original text.
                    rotated++;
                    continue;
                }
                var glyphs = letters.Select(ToGlyph).ToList();
                var blocks = PdfLayout.Analyze(glyphs, page.Width, page.Height);
                FindBackgrounds(page, blocks);
                allBlocks.AddRange(blocks.Select(block => (number, block)));
            }

            if (pdf.NumberOfPages > 0 && (glyphCount < 30 * pdf.NumberOfPages && imagePages * 2 >= pdf.NumberOfPages || glyphCount == 0))
                throw new DocumentException(Loc.T(
                    "这是扫描版 PDF（页面是图片，没有可提取的文字），暂不支持。可以先用 WPS、Adobe Acrobat 等软件做文字识别（OCR），再翻译识别后的文件。",
                    "This is a scanned PDF (its pages are images without text), which isn’t supported. Run text recognition (OCR) on it first, e.g. in Adobe Acrobat, then translate the result."));
            if (scannedPages.Count > 0)
                Warnings.Add(Loc.T($"第 {Pages(scannedPages)} 页是扫描图片，没有翻译。", $"Page {Pages(scannedPages)} is a scanned image and wasn’t translated."));
            if (rotated > 0)
                Warnings.Add(Loc.T($"{rotated} 个旋转过的页面（例如横向表格）保留了原文。", $"{rotated} rotated page(s) (e.g. landscape tables) kept their original text."));
            AddSegments(allBlocks);
        }
    }

    private static string Pages(List<int> pages) =>
        pages.Count <= 8 ? string.Join(", ", pages) : string.Join(", ", pages.Take(8)) + "…";

    /// <summary>
    /// The character's box from its baseline and advance width rather than its outline: every character of a line
    /// then has the same height (so "g" and "h" line up), and letters within a word touch (so "fl" isn't read as "f l").
    /// </summary>
    private static PdfGlyph ToGlyph(Letter letter)
    {
        var box = letter.BoundingBox;
        int color = 0;
        if (letter.Color is { } c)
        {
            var (r, g, b) = c.ToRGBValues();
            color = ((int)(r * 255) << 16) | ((int)(g * 255) << 8) | (int)(b * 255);
        }
        // Some PDFs report a zero point size for text scaled by the text matrix; the glyph height is a fair stand-in.
        double size = letter.PointSize > 0.5 ? letter.PointSize : Math.Max(box.Height * 1.4, 1);
        double x0 = letter.StartBaseLine.X, x1 = letter.EndBaseLine.X;
        if (x1 - x0 < 0.05 * size)
        {
            x0 = box.Left;
            x1 = Math.Max(box.Right, box.Left + 0.3 * size);
        }
        double baseline = letter.StartBaseLine.Y;
        return new PdfGlyph(letter.Value, x0, baseline - 0.25 * size, x1, baseline + 0.8 * size, size, letter.FontName ?? "", color);
    }

    /// <summary>The fill colour of the topmost filled shape behind each block, so coloured boxes and slides get a matching cover.</summary>
    private static void FindBackgrounds(Page page, List<PdfBlock> blocks)
    {
        IReadOnlyList<UglyToad.PdfPig.Graphics.PdfPath> paths;
        try
        {
            paths = page.Paths;
        }
        catch (Exception ex)
        {
            Log.Info($"读取 PDF 第 {page.Number} 页的图形失败：{ex.Message}");
            return;
        }
        var filled = new List<(UglyToad.PdfPig.Core.PdfRectangle Box, int Color)>();
        foreach (var path in paths)
        {
            if (!path.IsFilled || path.FillColor is null || path.GetBoundingRectangle() is not { } box)
                continue;
            var (r, g, b) = path.FillColor.ToRGBValues();
            filled.Add((box, ((int)(r * 255) << 16) | ((int)(g * 255) << 8) | (int)(b * 255)));
        }
        foreach (var block in blocks)
        {
            for (int i = filled.Count - 1; i >= 0; i--)
            {
                var box = filled[i].Box;
                if (box.Left <= block.X0 + 1 && box.Right >= block.X1 - 1 && box.Bottom <= block.Y0 + 1 && box.Top >= block.Y1 - 1)
                {
                    block.Background = filled[i].Color;
                    break;
                }
            }
        }
    }

    private void AddSegments(List<(int Page, PdfBlock Block)> blocks)
    {
        var text = blocks.Where(item => !item.Block.IsFormula && HasWords(item.Block.WordsText)).ToList();
        if (text.Count == 0)
            return;
        // The size of most of the text, weighted by length.
        var sizes = text.SelectMany(item => Enumerable.Repeat(Math.Round(item.Block.FontSize, 1), Math.Max(1, item.Block.WordsText.Length / 20))).Order().ToList();
        double body = sizes[sizes.Count / 2];
        double largestOnFirstPage = text.Where(item => item.Page == 1).Select(item => item.Block.FontSize).DefaultIfEmpty(0).Max();

        bool inReferences = false, titleFound = false;
        foreach (var (page, block) in text)
        {
            string words = block.WordsText;
            bool shortText = block.Lines.Count <= 2 && words.Length <= 120;
            var role = SegmentRole.Body;
            if (!titleFound && page == 1 && block.FontSize >= body * 1.3 && block.FontSize >= largestOnFirstPage - 0.1 && shortText)
            {
                role = SegmentRole.Title;
                titleFound = true;
            }
            else if (shortText && (block.FontSize >= body * 1.12 || block.Bold && block.Lines.Count == 1 && !words.TrimEnd().EndsWith('.')))
            {
                role = SegmentRole.Heading;
            }

            var segment = AddSegment(block.Pieces, role);
            _blocks.Add((page, block, segment.Id));
            if (ReferenceSection.IsHeading(words))
            {
                inReferences = true;
                continue;
            }
            if (inReferences && role != SegmentRole.Body)
                inReferences = false;
            segment.IsReference = inReferences;
        }
    }

    public override bool SupportsBilingual => true;

    public override void Save(string outputPath, IReadOnlyDictionary<int, string> translations, DocumentSaveOptions options)
    {
        PdfFonts.Install();
        SharpDocument pdf = OpenForWriting();
        try
        {
            foreach (var group in _blocks.Where(item => translations.ContainsKey(item.Segment)).GroupBy(item => item.Page))
            {
                var info = _pages[group.Key - 1];
                var page = pdf.Pages[group.Key - 1];
                // Take the original text out where it is translated; lines whose text couldn't be found are covered instead.
                var lines = group.SelectMany(item => item.Block.Lines).ToList();
                bool Inside(PdfLine line, double x, double y) =>
                    x >= line.X0 - 0.6 * line.FontSize && x <= line.X1 + 0.3 * line.FontSize
                    && y >= line.Y0 - 0.3 * line.FontSize && y <= line.Y1 + 0.3 * line.FontSize;
                var removed = PdfTextRemover.Remove(page, (x, y) => lines.Any(line => Inside(line, x - info.Left, y - info.Bottom))) ?? [];
                var cleared = lines.Where(line => removed.Any(point => Inside(line, point.X - info.Left, point.Y - info.Bottom))).ToHashSet();

                using var gfx = XGraphics.FromPdfPage(page, XGraphicsPdfPageOptions.Append);
                // PdfPig measures from the media box's corner; PDFsharp draws in user space with y pointing down.
                double height = page.Height.Point;
                XPoint Map(double x, double y) => new(x + info.Left, height - (y + info.Bottom));
                foreach (var (_, block, segment) in group)
                    DrawBlock(gfx, block, Segments[segment].Text, translations[segment], options.Target, Map, cleared);
            }
            WriteAtomically(outputPath, stream => pdf.Save(stream, closeStream: false));
        }
        finally
        {
            pdf.Dispose();
        }

        if (options.BilingualPath is { } bilingual)
            SaveBilingual(outputPath, bilingual);
    }

    /// <summary>
    /// Opens the original for changing it in place, which keeps links, bookmarks and form fields. A PDF with an
    /// owner password can't be changed that way; its pages are copied into a new document instead.
    /// </summary>
    private SharpDocument OpenForWriting()
    {
        try
        {
            return PdfReader.Open(SourcePath, PdfDocumentOpenMode.Modify);
        }
        catch (Exception first)
        {
            Log.Info($"PDFsharp 无法直接修改 PDF，改为复制页面：{first.Message}");
            try
            {
                using var source = PdfReader.Open(SourcePath, PdfDocumentOpenMode.Import);
                var copy = new SharpDocument();
                foreach (var page in source.Pages)
                    copy.AddPage(page);
                return copy;
            }
            catch (Exception ex)
            {
                Log.Error("PDFsharp 无法打开 PDF", ex);
                throw new DocumentException(Loc.T($"无法写入这个 PDF：{first.Message}", $"Couldn’t write this PDF: {first.Message}"), ex);
            }
        }
    }

    private void DrawBlock(XGraphics gfx, PdfBlock block, TaggedText tagged, string translation, Language target, Func<double, double, XPoint> map,
        ISet<PdfLine> cleared)
    {
        // Objects (inline formulas) are drawn with their own text.
        var formulas = block.Pieces.Where(p => p.IsAtom).ToDictionary(p => p.Atom, p => p.Text);
        string text = string.Concat(tagged.Parse(translation).Select(p => p.IsAtom ? formulas.GetValueOrDefault(p.Atom, "") : p.Text)).Trim();
        if (text.Length == 0)
            return;

        // Cover original lines that are still there (slightly larger than the characters, for accents and anti-aliasing).
        var cover = new XSolidBrush(ToXColor(block.Background));
        foreach (var line in block.Lines.Where(line => !cleared.Contains(line)))
        {
            double pad = 0.08 * line.FontSize;
            var topLeft = map(line.X0 - 0.6, line.Y1 + pad);
            gfx.DrawRectangle(cover, topLeft.X, topLeft.Y, line.X1 - line.X0 + 1.2, line.Y1 - line.Y0 + 2 * pad);
        }

        string face = PdfFonts.FaceFor(target, text, block.Serif, block.Bold);
        var style = block.Italic ? XFontStyleEx.Italic : XFontStyleEx.Regular;
        var options = new XPdfFontOptions(PdfFontEncoding.Unicode);
        var probe = new XFont(face, 10, style, options);
        double width = block.X1 - block.X0, height = block.Y1 - block.Y0;
        var fitted = PdfTextFitter.Fit(text, width, height, block.FontSize, block.LinePitch / block.FontSize,
            piece => gfx.MeasureString(piece, probe).Width / 10, block.Justified, firstIndent: block.FirstLineIndent);

        var font = new XFont(face, fitted.FontSize, style, options);
        var brush = new XSolidBrush(ToXColor(block.Color));
        // CJK glyphs reach higher than Latin capitals; put the first line's top where the original's was.
        bool cjk = text.Any(c => c is >= '⺀' and <= '鿿' or >= '가' and <= '힯');
        double rise = cjk ? 0.86 : Math.Clamp(font.Metrics.CapHeight / (double)font.Metrics.UnitsPerEm, 0.6, 0.8);
        double baseline = block.Y1 - rise * fitted.FontSize;
        foreach (var line in fitted.Lines)
        {
            double x = block.X0 + (block.Centered ? (width - line.Width) / 2 : 0);
            foreach (var (piece, offset) in line.Pieces)
            {
                var point = map(x + offset, baseline);
                gfx.DrawString(piece, font, brush, point.X, point.Y, XStringFormats.BaseLineLeft);
            }
            baseline -= fitted.LinePitch;
        }
    }

    private static XColor ToXColor(int rgb) => XColor.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);

    /// <summary>Original and translated pages alternating, for checking the translation side by side.</summary>
    private void SaveBilingual(string translatedPath, string bilingualPath)
    {
        try
        {
            using var original = PdfReader.Open(SourcePath, PdfDocumentOpenMode.Import);
            using var translated = PdfReader.Open(translatedPath, PdfDocumentOpenMode.Import);
            using var both = new SharpDocument();
            for (int i = 0; i < translated.PageCount; i++)
            {
                if (i < original.PageCount)
                    both.AddPage(original.Pages[i]);
                both.AddPage(translated.Pages[i]);
            }
            WriteAtomically(bilingualPath, stream => both.Save(stream, closeStream: false));
        }
        catch (Exception ex)
        {
            Log.Error("生成双语对照 PDF 失败", ex);
            Warnings.Add(Loc.T($"双语对照版没能生成：{ex.Message}", $"The bilingual version couldn’t be created: {ex.Message}"));
        }
    }
}
