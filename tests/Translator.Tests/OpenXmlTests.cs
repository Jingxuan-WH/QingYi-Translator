using System.IO.Compression;
using System.Text;
using System.Xml.Linq;
using Translator.Core;
using Translator.Core.FileTranslation;
using Xunit;

namespace Translator.Tests;

/// <summary>Builds small Office files for the tests.</summary>
internal static class OfficeFiles
{
    public const string WNs = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    public const string ANs = "http://schemas.openxmlformats.org/drawingml/2006/main";
    public const string PNs = "http://schemas.openxmlformats.org/presentationml/2006/main";
    public const string XNs = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string Rels = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>""";

    public static string Write(string extension, string contentTypes, params (string Name, string Xml)[] parts)
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-office").FullName, "sample" + extension);
        using var zip = ZipFile.Open(path, ZipArchiveMode.Create);
        void Add(string name, string text)
        {
            using var writer = new StreamWriter(zip.CreateEntry(name).Open(), new UTF8Encoding(false));
            writer.Write(text);
        }
        Add("[Content_Types].xml", $"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>{contentTypes}</Types>""");
        Add("_rels/.rels", Rels);
        foreach (var (name, xml) in parts)
            Add(name, """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""" + xml);
        using (var image = zip.CreateEntry("word/media/image1.png").Open())
            image.Write([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
        return path;
    }

    public static XDocument Read(string path, string part)
    {
        using var zip = ZipFile.OpenRead(path);
        using var stream = zip.GetEntry(part)!.Open();
        return XDocument.Load(stream);
    }

    public static string Override(string part, string type) => $"""<Override PartName="/{part}" ContentType="{type}"/>""";
}

public class OpenXmlTests
{
    private static readonly XNamespace W = OfficeFiles.WNs;
    private static readonly XNamespace A = OfficeFiles.ANs;
    private static readonly XNamespace X = OfficeFiles.XNs;
    private const string Wml = "application/vnd.openxmlformats-officedocument.wordprocessingml.";

    private static string WordSample() => OfficeFiles.Write(".docx",
        OfficeFiles.Override("word/document.xml", Wml + "document.main+xml") + OfficeFiles.Override("word/styles.xml", Wml + "styles+xml")
        + OfficeFiles.Override("word/footnotes.xml", Wml + "footnotes+xml") + OfficeFiles.Override("word/header1.xml", Wml + "header+xml"),
        ("word/document.xml", $"""
            <w:document xmlns:w="{OfficeFiles.WNs}" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
            <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Power Flow Study</w:t></w:r></w:p>
            <w:p><w:r><w:t xml:space="preserve">The </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>New</w:t></w:r><w:r><w:rPr><w:b/><w:lang w:val="en-US"/></w:rPr><w:t>ton</w:t></w:r><w:r><w:rPr><w:lang w:val="en-US"/></w:rPr><w:t xml:space="preserve"> method </w:t></w:r><w:hyperlink r:id="rId9"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>converges</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> fast</w:t></w:r><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:r><w:t>.</w:t></w:r></w:p>
            <w:p><w:r><w:t xml:space="preserve">Energy is </w:t></w:r><m:oMath><m:r><m:t>E=mc^2</m:t></m:r></m:oMath><w:r><w:t xml:space="preserve"> as shown in </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> REF _Ref1 \h </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Figure 1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t>.</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Voltage</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>12345</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            <w:p><w:r><w:drawing><w:txbxContent><w:p><w:r><w:t>Text box words</w:t></w:r></w:p></w:txbxContent></w:drawing></w:r></w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>References</w:t></w:r></w:p>
            <w:p><w:r><w:t>[1] J. Smith, Power systems.</w:t></w:r></w:p>
            </w:body></w:document>
            """),
        ("word/styles.xml", $"""<w:styles xmlns:w="{OfficeFiles.WNs}"><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style></w:styles>"""),
        ("word/footnotes.xml", $"""<w:footnotes xmlns:w="{OfficeFiles.WNs}"><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> See the appendix.</w:t></w:r></w:p></w:footnote></w:footnotes>"""),
        ("word/header1.xml", $"""<w:hdr xmlns:w="{OfficeFiles.WNs}"><w:p><w:r><w:t>Confidential draft</w:t></w:r></w:p></w:hdr>"""));

    [Fact]
    public void WordSegmentsKeepFormattingAsTags()
    {
        var document = new WordDocument(WordSample());
        var texts = document.Segments.Select(s => s.Text.Text).ToList();
        Assert.Equal(
        [
            "Power Flow Study",
            "The <1>Newton</1> method <2>converges</2> fast<3/>.",
            "Energy is <1/> as shown in <2/>.",
            "Voltage",
            "Text box words",
            "References",
            "[1] J. Smith, Power systems.",
            "Confidential draft",
            "<1/> See the appendix.",
        ], texts);
        Assert.Equal(SegmentRole.Title, document.Segments[0].Role);
        Assert.Equal(SegmentRole.Heading, document.Segments[5].Role);
        Assert.True(document.Segments[6].IsReference);
        Assert.False(document.Segments[4].IsReference);
    }

    [Fact]
    public void WordTranslationIsWrittenIntoTheRunsInItsOwnOrder()
    {
        string path = WordSample();
        var document = new WordDocument(path);
        string output = path.Replace(".docx", ".zh-Hans.docx");
        document.Save(output, new Dictionary<int, string>
        {
            [0] = "潮流研究",
            [1] = "<2>收敛</2>很快<3/>，<1>牛顿</1>法。",
            [2] = "如<2/>所示，能量为<1/>。",
            [4] = "文本框文字",
            [7] = "机密草稿",
            [8] = "<1/> 见附录。",
        }, new DocumentSaveOptions(Languages.SimplifiedChinese));

        var body = OfficeFiles.Read(output, "word/document.xml").Root!.Element(W + "body")!;
        var paragraphs = body.Elements(W + "p").ToList();
        Assert.Equal("潮流研究", paragraphs[0].Value);

        // Order follows the translation; bold, the hyperlink and the footnote mark survive.
        var second = paragraphs[1];
        Assert.Equal("收敛很快，牛顿法。", string.Concat(second.Descendants(W + "t").Select(t => t.Value)));
        Assert.Equal("收敛", second.Element(W + "hyperlink")!.Value);
        Assert.Equal("rId9", (string?)second.Element(W + "hyperlink")!.Attributes().First(a => a.Name.LocalName == "id"));
        var bold = second.Elements(W + "r").Where(r => r.Element(W + "rPr")?.Element(W + "b") is not null).ToList();
        Assert.Equal("牛顿", Assert.Single(bold).Value);
        var children = second.Elements().Select(e => e.Name.LocalName == "hyperlink" ? "link" : e.Descendants(W + "footnoteReference").Any() ? "note" : e.Value).ToList();
        Assert.Equal(["link", "很快", "note", "，", "牛顿", "法。"], children);

        // The formula moved after the text it now follows; the field (Figure 1) is untouched.
        var third = paragraphs[2];
        var parts = third.Elements().Select(e => e.Name.LocalName == "oMath" ? "math" : e.Element(W + "fldChar") is { } f ? (string)f.Attribute(W + "fldCharType")! : e.Element(W + "instrText") is not null ? "instr" : e.Value).ToList();
        Assert.Equal(["如", "begin", "instr", "separate", "Figure 1", "end", "所示，能量为", "math", "。"], parts);

        // (The table sits between the paragraphs, so the text box's paragraph is the fourth.)
        Assert.Equal("文本框文字", paragraphs[3].Descendants(W + "txbxContent").Single().Value);
        Assert.Equal("12345", body.Descendants(W + "tc").Last().Value);
        Assert.Equal("[1] J. Smith, Power systems.", paragraphs[5].Value); // not translated
        Assert.Equal("机密草稿", OfficeFiles.Read(output, "word/header1.xml").Root!.Value);
        var note = OfficeFiles.Read(output, "word/footnotes.xml").Root!.Elements(W + "footnote").Last();
        Assert.NotNull(note.Descendants(W + "footnoteRef").SingleOrDefault());
        Assert.Equal(" 见附录。", note.Value);
        Assert.Equal("preserve", (string?)note.Descendants(W + "t").Single().Attribute(XNamespace.Xml + "space"));

        // Everything else is copied unchanged.
        using var zip = ZipFile.OpenRead(output);
        Assert.Equal([0x89, 0x50, 0x4E, 0x47, 1, 2, 3], ReadAll(zip.GetEntry("word/media/image1.png")!));
    }

    private static byte[] ReadAll(ZipArchiveEntry entry)
    {
        using var stream = entry.Open();
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    }

    [Fact]
    public void UntranslatedParagraphsStayExactlyTheSame()
    {
        string path = WordSample();
        var document = new WordDocument(path);
        string output = path.Replace(".docx", ".out.docx");
        document.Save(output, new Dictionary<int, string>(), new DocumentSaveOptions(Languages.English));
        string Text(string file) => string.Concat(OfficeFiles.Read(file, "word/document.xml").Descendants(W + "t").Select(t => t.Value));
        Assert.Equal(Text(path), Text(output));
    }

    private const string Pml = "application/vnd.openxmlformats-officedocument.presentationml.";

    [Fact]
    public void PowerPointKeepsRunsAndShrinksTextThatGrew()
    {
        string sp(string type, string paragraphs, string bodyPr = "<a:bodyPr/>") => $"""
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="s"/><p:cNvSpPr/><p:nvPr>{(type.Length > 0 ? $"<p:ph type=\"{type}\"/>" : "")}</p:nvPr></p:nvSpPr><p:spPr/><p:txBody>{bodyPr}<a:lstStyle/>{paragraphs}</p:txBody></p:sp>
            """;
        string slide(string shapes) => $"""<p:sld xmlns:a="{OfficeFiles.ANs}" xmlns:p="{OfficeFiles.PNs}"><p:cSld><p:spTree>{shapes}</p:spTree></p:cSld></p:sld>""";
        string path = OfficeFiles.Write(".pptx",
            OfficeFiles.Override("ppt/slides/slide1.xml", Pml + "slide+xml") + OfficeFiles.Override("ppt/slides/slide2.xml", Pml + "slide+xml")
            + OfficeFiles.Override("ppt/notesSlides/notesSlide1.xml", Pml + "notesSlide+xml"),
            ("ppt/slides/slide1.xml", slide(sp("ctrTitle", """<a:p><a:r><a:rPr lang="en-US"/><a:t>Results</a:t></a:r></a:p>""")
                + sp("", """<a:p><a:r><a:rPr lang="en-US" b="1"/><a:t>Revenue</a:t></a:r><a:r><a:rPr lang="en-US"/><a:t xml:space="preserve"> grew</a:t></a:r><a:br><a:rPr lang="en-US"/></a:br><a:r><a:rPr lang="en-US" dirty="0"/><a:t>in Q3</a:t></a:r><a:endParaRPr lang="en-US"/></a:p>"""))),
            ("ppt/slides/slide2.xml", slide($"""<p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>Cost</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>""")),
            ("ppt/notesSlides/notesSlide1.xml", $"""<p:notes xmlns:a="{OfficeFiles.ANs}" xmlns:p="{OfficeFiles.PNs}"><p:cSld><p:spTree>{sp("body", "<a:p><a:r><a:t>Speak slowly.</a:t></a:r></a:p>")}</p:spTree></p:cSld></p:notes>"""));

        var document = new PresentationDocument(path);
        Assert.Equal(["Results", "<1>Revenue</1> grew<2/>in Q3", "Cost", "Speak slowly."], document.Segments.Select(s => s.Text.Text));
        Assert.Equal(SegmentRole.Title, document.Segments[0].Role);

        string output = path.Replace(".pptx", ".en.pptx");
        document.Save(output, new Dictionary<int, string>
        {
            [0] = "结果",
            [1] = "<1>Revenue from all of our regional product lines</1> grew substantially and steadily<2/>during the third quarter of the year",
            [2] = "成本",
            [3] = "慢慢讲。",
        }, new DocumentSaveOptions(Languages.English));

        var slide1 = OfficeFiles.Read(output, "ppt/slides/slide1.xml");
        var bodies = slide1.Descendants(A.GetName("txBody")).Concat(slide1.Descendants(XName.Get("txBody", OfficeFiles.PNs))).ToList();
        var body = bodies.Single(b => b.Value.Contains("Revenue"));
        var runs = body.Descendants(A + "r").ToList();
        Assert.Equal("1", (string?)runs[0].Element(A + "rPr")!.Attribute("b"));
        Assert.Equal("Revenue from all of our regional product lines", runs[0].Value);
        Assert.NotNull(body.Descendants(A + "br").SingleOrDefault());
        var autofit = body.Element(A + "bodyPr")!.Element(A + "normAutofit");
        Assert.NotNull(autofit);
        Assert.InRange(int.Parse((string)autofit.Attribute("fontScale")!), 25000, 70000);
        // The title got shorter: no autofit.
        Assert.Null(slide1.Descendants(A + "bodyPr").First().Element(A + "normAutofit"));
        Assert.Equal("成本", OfficeFiles.Read(output, "ppt/slides/slide2.xml").Descendants(A + "t").Single().Value);
        Assert.Equal("慢慢讲。", OfficeFiles.Read(output, "ppt/notesSlides/notesSlide1.xml").Descendants(A + "t").Single().Value);
    }

    [Fact]
    public void ExcelTranslatesTextCellsButNotFormulasOrNumbers()
    {
        const string Sml = "application/vnd.openxmlformats-officedocument.spreadsheetml.";
        string path = OfficeFiles.Write(".xlsx",
            OfficeFiles.Override("xl/sharedStrings.xml", Sml + "sharedStrings+xml") + OfficeFiles.Override("xl/worksheets/sheet1.xml", Sml + "worksheet+xml"),
            ("xl/sharedStrings.xml", $"""<sst xmlns="{OfficeFiles.XNs}" count="3" uniqueCount="3"><si><t>Revenue</t></si><si><r><rPr><b/></rPr><t>Net</t></r><r><t xml:space="preserve"> income</t></r></si><si><t>2024-Q3</t></si></sst>"""),
            ("xl/worksheets/sheet1.xml", $"""<worksheet xmlns="{OfficeFiles.XNs}"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><f>SUM(C1:C2)</f><v>3</v></c><c r="C1" t="str"><f>"total"&amp;"s"</f><v>totals</v></c><c r="D1" t="inlineStr"><is><t>Inline note</t></is></c></row></sheetData></worksheet>"""));

        var document = new SpreadsheetDocument(path);
        // "2024-Q3" has no words to translate.
        Assert.Equal(["Revenue", "<1>Net</1> income", "Inline note"], document.Segments.Select(s => s.Text.Text));
        string output = path.Replace(".xlsx", ".zh-Hans.xlsx");
        document.Save(output, new Dictionary<int, string> { [0] = "收入", [1] = "<1>净</1>收入", [2] = "内联备注" }, new DocumentSaveOptions(Languages.SimplifiedChinese));

        var strings = OfficeFiles.Read(output, "xl/sharedStrings.xml").Root!.Elements(X + "si").ToList();
        Assert.Equal("收入", strings[0].Value);
        Assert.Equal("净", strings[1].Elements(X + "r").First().Value);
        Assert.NotNull(strings[1].Elements(X + "r").First().Element(X + "rPr")!.Element(X + "b"));
        Assert.Equal("2024-Q3", strings[2].Value);
        var sheet = OfficeFiles.Read(output, "xl/worksheets/sheet1.xml");
        Assert.Equal("SUM(C1:C2)", sheet.Descendants(X + "f").First().Value);
        Assert.Equal("totals", sheet.Descendants(X + "c").ElementAt(2).Element(X + "v")!.Value);
        Assert.Equal("内联备注", sheet.Descendants(X + "is").Single().Value);
    }

    [Fact]
    public void EncryptedOrBrokenFilesGiveAClearError()
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-bad").FullName, "locked.docx");
        File.WriteAllBytes(path, [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0, 0, 0]);
        var error = Assert.Throws<DocumentException>(() => DocumentLoader.Open(path));
        Assert.Contains(Loc.T("加密", "encrypted"), error.Message);
        Assert.Contains(".docx", Assert.Throws<DocumentException>(() => DocumentLoader.Open(path.Replace(".docx", ".doc"))).Message);
    }
}
