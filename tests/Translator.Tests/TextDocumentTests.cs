using System.Text;
using Translator.Core;
using Translator.Core.FileTranslation;
using Xunit;

namespace Translator.Tests;

public class TextDocumentTests
{
    private static string Temp(string name, string text, Encoding? encoding = null)
    {
        string path = Path.Combine(Directory.CreateTempSubdirectory("qy-text").FullName, name);
        File.WriteAllText(path, text, encoding ?? new UTF8Encoding(false));
        return path;
    }

    /// <summary>Saves with a translation made by <paramref name="translate"/> and returns the written text.</summary>
    private static string SaveWith(TranslatableDocument document, Func<string, string> translate)
    {
        var translations = document.Segments.ToDictionary(s => s.Id, s => translate(s.Text.Text));
        string output = OutputPaths.For(document.SourcePath, Languages.SimplifiedChinese);
        document.Save(output, translations, new DocumentSaveOptions(Languages.SimplifiedChinese));
        return File.ReadAllText(output);
    }

    [Fact]
    public void PlainTextKeepsParagraphsAndUrls()
    {
        var document = new PlainTextDocument(Temp("notes.txt", "Meeting notes\n\n  First point, see https://example.com/a?b=1.\nIt continues here.\n\n\n2024\n"));
        Assert.Equal(["Meeting notes", "First point, see <1/>.\nIt continues here."], document.Segments.Select(s => s.Text.Text));
        Assert.Equal(SegmentRole.Title, document.Segments[0].Role);
        string output = SaveWith(document, text => text.Replace("Meeting notes", "会议记录").Replace("First point, see <1/>.\nIt continues here.", "第一点，见<1/>。这里继续。"));
        Assert.Equal("会议记录\n\n  第一点，见https://example.com/a?b=1。这里继续。\n\n\n2024\n", output);
    }

    [Fact]
    public void PlainTextInTheSystemCodePageComesBackAsUtf8WithTheSameLineBreaks()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var gbk = Encoding.GetEncoding(936);
        string path = Temp("gbk.txt", "你好，世界。\r\n\r\n第二段。\r\n", gbk);
        var document = new PlainTextDocument(path);
        Assert.Equal(["你好，世界。", "第二段。"], document.Segments.Select(s => s.Text.Text));
        string output = OutputPaths.For(path, Languages.English);
        document.Save(output, new Dictionary<int, string> { [0] = "Hello, world.", [1] = "Second\nparagraph." }, new DocumentSaveOptions(Languages.English));
        byte[] bytes = File.ReadAllBytes(output);
        Assert.Equal([0xEF, 0xBB, 0xBF], bytes[..3]);
        Assert.Equal("Hello, world.\r\n\r\nSecond\r\nparagraph.\r\n", Encoding.UTF8.GetString(bytes[3..]));
    }

    [Fact]
    public void MarkdownTranslatesTextButNotCodeOrSyntax()
    {
        const string source = """
            ---
            title: Guide
            ---
            # Getting started

            Install with `npm install x` and read [the docs](https://example.com/docs "Docs") or **this part**.

            - First item
              continues here
            1. Numbered $x^2$ item

            ```bash
            echo "do not translate"
            ```

            | Name | Value |
            |------|------:|
            | Speed | 42 |

            $$
            E = mc^2
            $$

            > Quoted text
            <!-- a comment -->
            Setext title
            ============
            """;
        var document = new MarkdownDocument(Temp("guide.md", source));
        Assert.Equal(
        [
            "Getting started",
            "Install with <1/> and read [the docs]<2/> or **this part**.",
            "First item\ncontinues here",
            "Numbered <1/> item",
            "Name", "Value", "Speed",
            "Quoted text",
            "Setext title",
        ], document.Segments.Select(s => s.Text.Text));
        Assert.Equal(SegmentRole.Title, document.Segments[0].Role);
        Assert.Equal(SegmentRole.Heading, document.Segments[8].Role);

        var map = new Dictionary<string, string>
        {
            ["Getting started"] = "入门",
            ["Install with <1/> and read [the docs]<2/> or **this part**."] = "用 <1/> 安装，并阅读[文档]<2/>或**这一部分**。",
            ["First item\ncontinues here"] = "第一项\n继续",
            ["Numbered <1/> item"] = "编号 <1/> 项",
            ["Name"] = "名称", ["Value"] = "值", ["Speed"] = "速度|快",
            ["Quoted text"] = "引用文字",
            ["Setext title"] = "标题",
        };
        string output = SaveWith(document, text => map[text]);
        Assert.Equal("""
            ---
            title: Guide
            ---
            # 入门

            用 `npm install x` 安装，并阅读[文档](https://example.com/docs "Docs")或**这一部分**。

            - 第一项
              继续
            1. 编号 $x^2$ 项

            ```bash
            echo "do not translate"
            ```

            | 名称 | 值 |
            |------|------:|
            | 速度\|快 | 42 |

            $$
            E = mc^2
            $$

            > 引用文字
            <!-- a comment -->
            标题
            ============
            """, output);
    }

    [Fact]
    public void SubtitlesKeepNumbersTimingsAndTags()
    {
        const string source = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello there,</i>\r\nmy friend.\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n♪ ♪\r\n\r\n3\r\n00:00:06,000 --> 00:00:08,000\r\nHow are you?\r\n";
        var document = new SubtitleDocument(Temp("movie.srt", source));
        Assert.Equal(["<1/>Hello there,<2/>\nmy friend.", "How are you?"], document.Segments.Select(s => s.Text.Text));
        Assert.Contains("subtitle", document.PromptHint);
        string output = SaveWith(document, text => text.StartsWith("<1/>") ? "<1/>你好，<2/>\n\n我的朋友。" : "你好吗？");
        Assert.Equal("1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>你好，</i>\r\n我的朋友。\r\n\r\n2\r\n00:00:04,000 --> 00:00:05,000\r\n♪ ♪\r\n\r\n3\r\n00:00:06,000 --> 00:00:08,000\r\n你好吗？\r\n", output);
    }

    [Fact]
    public void MissingPlaceholdersAreAppendedRatherThanLost()
    {
        var document = new PlainTextDocument(Temp("u.txt", "Visit https://example.com today"));
        string output = SaveWith(document, _ => "今天访问");
        Assert.Equal("今天访问 https://example.com", output);
    }
}
