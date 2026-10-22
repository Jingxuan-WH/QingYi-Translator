using System.IO;
using Translator.Core;
using Translator.Core.FileTranslation;
using Xunit;

namespace Translator.Tests;

public class SegmentBatcherTests
{
    [Fact]
    public void PlanRespectsCharacterAndCountLimits()
    {
        var batches = SegmentBatcher.Plan(new[] { 500, 500, 2000, 3000, 10, 10 }, n => n, maxChars: 2400, maxItems: 3);
        Assert.Equal([[500, 500], [2000], [3000], [10, 10]], batches);
        Assert.Equal(4, SegmentBatcher.Plan(Enumerable.Repeat(1, 10), n => n, maxItems: 3).Count);
    }

    [Fact]
    public void MessageAndResponseRoundTrip()
    {
        string message = SegmentBatcher.BuildUserMessage(["Hello <1>world</1>", "Second"]);
        Assert.Equal("<seg id=\"1\">Hello <1>world</1></seg>\n<seg id=\"2\">Second</seg>\n", message);
        var parsed = SegmentBatcher.ParseResponse("Sure:\n<seg id=\"2\"> 第二 </seg>\n<seg id='1'>你好<1>世界</1></seg>", 2);
        Assert.Equal("你好<1>世界</1>", parsed[0]);
        Assert.Equal("第二", parsed[1]);
    }

    [Fact]
    public void MissingSegmentsAreLeftOut()
    {
        var parsed = SegmentBatcher.ParseResponse("<seg id=\"1\">a</seg><seg id=\"3\">c</seg><seg id=\"9\">x</seg>", 3);
        Assert.Equal([0, 2], parsed.Keys.Order());
    }

    [Fact]
    public void SingleSegmentMayComeBackBare()
    {
        Assert.Equal("你好", SegmentBatcher.ParseResponse("你好", 1)[0]);
        Assert.Empty(SegmentBatcher.ParseResponse("<seg id=\"1\">cut o", 1, complete: false));
        Assert.Empty(SegmentBatcher.ParseResponse("bare", 2));
    }

    [Fact]
    public void PromptCarriesFieldStyleAndGlossary()
    {
        var profile = new DomainProfile("电气工程", "电力系统", "学术论文", []);
        string prompt = SegmentBatcher.BuildSystemPrompt(Languages.SimplifiedChinese, profile,
            [new GlossaryEntry { Source = "power flow", Target = "潮流" }], "Subtitles hint.", "Be formal.");
        Assert.Contains("into Simplified Chinese", prompt);
        Assert.Contains("Field: 电气工程 · 电力系统", prompt);
        Assert.Contains("Style of the document: 学术论文", prompt);
        Assert.Contains("- power flow = 潮流", prompt);
        Assert.Contains("8. Subtitles hint.", prompt);
        Assert.EndsWith("Additional requirements from the user:\nBe formal.\n", prompt.ReplaceLineEndings("\n"));
    }
}

public class DomainAnalyzerTests
{
    [Fact]
    public void ParsesFencedJsonWithChatter()
    {
        var profile = DomainAnalyzer.Parse("""
            Here is the analysis:
            ```json
            {"domain": "电气工程", "subdomain": "电力系统", "style": "学术论文，正式",
             "terms": [{"source": "power flow", "target": "潮流"}, {"source": "MATLAB", "target": "MATLAB"}, {"source": "droop control", "target": "下垂控制"},]}
            ```
            """);
        Assert.NotNull(profile);
        Assert.Equal("电气工程 · 电力系统", profile.DomainText);
        Assert.Equal("学术论文，正式", profile.Style);
        // Terms that stay unchanged are left out.
        Assert.Equal(["power flow", "droop control"], profile.Terms.Select(t => t.Source));
    }

    [Fact]
    public void ParsesOtherShapes()
    {
        var map = DomainAnalyzer.Parse("""{"Domain":"Law","terms":{"tort":"侵权","estoppel":"禁反言"}}""");
        Assert.Equal("Law", map!.DomainText);
        Assert.Equal(2, map.Terms.Count);
        var pairs = DomainAnalyzer.Parse("""{"field":"Medicine","glossary":[["stent","支架"],{"term":"angioplasty","translation":"血管成形术"}]}""");
        Assert.Equal(["stent", "angioplasty"], pairs!.Terms.Select(t => t.Source));
        Assert.Null(DomainAnalyzer.Parse("I cannot help with that."));
        Assert.Null(DomainAnalyzer.Parse("{not json"));
    }

    [Fact]
    public void UserGlossaryWinsOverDetectedTerms()
    {
        var merged = DomainAnalyzer.MergeTerms(
            [new GlossaryEntry { Source = "power flow", Target = "潮流" }, new GlossaryEntry { Source = "电网", Target = "power grid" }],
            [new GlossaryEntry { Source = "Power Flow", Target = "功率流" }, new GlossaryEntry { Source = "power grid", Target = "电力网" },
             new GlossaryEntry { Source = "inverter", Target = "逆变器" }]);
        Assert.Equal([("power flow", "潮流", true), ("电网", "power grid", true), ("inverter", "逆变器", false)],
            merged.Select(t => (t.Source, t.Target, t.FromGlossary)));
    }

    [Fact]
    public void SampleCoversTitleAbstractHeadingsAndSpreadOutParagraphs()
    {
        var segments = new List<DocumentSegment>
        {
            Segment(0, "A Study of Power Flow", SegmentRole.Title),
            Segment(1, "Abstract", SegmentRole.Heading),
            Segment(2, "We study the power flow problem in distribution grids."),
            Segment(3, "1. Introduction", SegmentRole.Heading),
        };
        for (int i = 4; i < 200; i++)
            segments.Add(Segment(i, $"Paragraph {i} " + new string('x', 300)));
        segments.Add(Segment(200, "References", SegmentRole.Heading));
        segments.Add(new DocumentSegment(201, TaggedText.Build([InlinePiece.Of("[1] A. Author, Old paper.", 0)])) { IsReference = true });

        string sample = DomainAnalyzer.BuildSample(segments, 6000);
        Assert.True(sample.Length <= 6000);
        Assert.StartsWith("[Title] A Study of Power Flow\n[Abstract] We study the power flow problem", sample);
        Assert.Contains("- 1. Introduction", sample);
        Assert.Contains("Paragraph 4 ", sample);
        Assert.DoesNotContain("Old paper", sample);
        // Besides the opening paragraphs, some from the middle and the end are sampled.
        Assert.Contains(segments.Skip(80).Take(40), s => sample.Contains(s.PlainText[..14]));
        Assert.Contains(segments.Skip(150).Take(50), s => sample.Contains(s.PlainText[..14]));
    }

    private static DocumentSegment Segment(int id, string text, SegmentRole role = SegmentRole.Body) =>
        new(id, TaggedText.Build([InlinePiece.Of(text, 0)]), role);
}

public class ReferenceAndOutputTests
{
    [Theory]
    [InlineData("References", true)]
    [InlineData("REFERENCES", true)]
    [InlineData("7. References", true)]
    [InlineData("VII. REFERENCES", true)]
    [InlineData("参考文献", true)]
    [InlineData("References to earlier work show that", false)]
    [InlineData("Introduction", false)]
    public void RecognizesReferenceHeadings(string text, bool expected) => Assert.Equal(expected, ReferenceSection.IsHeading(text));

    [Fact]
    public void OutputGoesNextToTheOriginalWithoutOverwriting()
    {
        string dir = Directory.CreateTempSubdirectory("qy-out").FullName;
        string source = Path.Combine(dir, "paper.pdf");
        File.WriteAllText(source, "x");
        Assert.Equal(Path.Combine(dir, "paper.zh-Hans.pdf"), OutputPaths.For(source, Languages.SimplifiedChinese));
        File.WriteAllText(Path.Combine(dir, "paper.zh-Hans.pdf"), "x");
        Assert.Equal(Path.Combine(dir, "paper.zh-Hans (2).pdf"), OutputPaths.For(source, Languages.SimplifiedChinese));
        Assert.Equal(Path.Combine(dir, "paper.en.bilingual.pdf"), OutputPaths.For(source, Languages.English, "bilingual"));
        Directory.Delete(dir, recursive: true);
    }
}
