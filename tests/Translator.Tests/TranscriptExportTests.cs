using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class TranscriptExportTests
{
    private static LiveTranscript Sample()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        transcript.Finalize(1, "Hello everyone.", 1.2, 2.0)!.Translation = "大家好。";
        transcript.Finalize(2, "Today: power flow.", 2.5, 5.75)!.Translation = "今天讲潮流。";
        var draft = transcript.Finalize(3, "No translation yet.", 6, 7.5)!;
        draft.Translation = "草稿";
        draft.TranslationIsDraft = true;
        transcript.UpdatePartial(4, "still talking", 8);
        return transcript;
    }

    [Fact]
    public void TimeFormats()
    {
        Assert.Equal("00:00:00,000", TranscriptExport.FormatSrtTime(0));
        Assert.Equal("01:01:01,235", TranscriptExport.FormatSrtTime(3661.2346));
        Assert.Equal("00:00:00,000", TranscriptExport.FormatSrtTime(-3));
        Assert.Equal("01:05", TranscriptExport.FormatClock(65.9));
        Assert.Equal("1:02:05", TranscriptExport.FormatClock(3725));
    }

    [Fact]
    public void BilingualSrt()
    {
        string srt = TranscriptExport.Build(Sample().Lines, TranscriptFormat.Srt, TranscriptContent.Bilingual);
        Assert.Equal(
            "1\r\n00:00:01,200 --> 00:00:02,000\r\nHello everyone.\r\n大家好。\r\n\r\n" +
            "2\r\n00:00:02,500 --> 00:00:05,750\r\nToday: power flow.\r\n今天讲潮流。\r\n\r\n" +
            "3\r\n00:00:06,000 --> 00:00:07,500\r\nNo translation yet.\r\n\r\n", srt);
    }

    [Fact]
    public void TranslationOnlySkipsUntranslatedLinesAndRenumbers()
    {
        string srt = TranscriptExport.Build(Sample().Lines, TranscriptFormat.Srt, TranscriptContent.Translation);
        Assert.Equal(
            "1\r\n00:00:01,200 --> 00:00:02,000\r\n大家好。\r\n\r\n" +
            "2\r\n00:00:02,500 --> 00:00:05,750\r\n今天讲潮流。\r\n\r\n", srt);
    }

    [Fact]
    public void ShortCuesAreStretchedWithoutOverlapping()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        transcript.Finalize(1, "Hi.", 1.0, 1.1);
        transcript.Finalize(2, "Yes.", 1.5, 1.6);
        transcript.Finalize(3, "Ok.", 4.0, 4.1);
        string srt = TranscriptExport.Build(transcript.Lines, TranscriptFormat.Srt, TranscriptContent.Original);
        Assert.Contains("00:00:01,000 --> 00:00:01,500", srt);
        Assert.Contains("00:00:01,500 --> 00:00:02,300", srt);
        Assert.Contains("00:00:04,000 --> 00:00:04,800", srt);
    }

    [Fact]
    public void PlainText()
    {
        Assert.Equal("[00:01] Hello everyone.\r\n[00:02] Today: power flow.\r\n[00:06] No translation yet.\r\n",
            TranscriptExport.Build(Sample().Lines, TranscriptFormat.Text, TranscriptContent.Original));
        Assert.Equal("[00:01] Hello everyone.\r\n    大家好。\r\n\r\n[00:02] Today: power flow.\r\n    今天讲潮流。\r\n\r\n[00:06] No translation yet.\r\n\r\n",
            TranscriptExport.Build(Sample().Lines, TranscriptFormat.Text, TranscriptContent.Bilingual));
    }
}
