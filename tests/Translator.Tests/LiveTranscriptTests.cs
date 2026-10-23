using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class LiveTranscriptTests
{
    [Fact]
    public void PartialResultsAreReplacedByTheFinalOne()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        var line = transcript.UpdatePartial(1, "hel", 0.5)!;
        Assert.Same(line, transcript.UpdatePartial(1, " hello wor ", 0.5));
        Assert.Equal("hello wor", line.Text);
        Assert.False(line.IsFinal);

        Assert.Same(line, transcript.Finalize(1, "Hello, world.", 0.5, 2.25, "en"));
        Assert.True(line.IsFinal);
        Assert.Equal("Hello, world.", line.Text);
        Assert.Equal(2.25, line.End);
        Assert.Equal("en", line.Language);

        Assert.Null(transcript.UpdatePartial(1, "hello wo", 0.5)); // late partial
        Assert.Equal("Hello, world.", line.Text);
        Assert.Single(transcript.Lines);
    }

    [Fact]
    public void EmptyResultsDoNotLeaveLines()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        Assert.Null(transcript.UpdatePartial(1, "  ", 0));
        Assert.Empty(transcript.Lines);
        transcript.UpdatePartial(2, "uh", 1);
        Assert.Null(transcript.Finalize(2, "", 1, 2));
        Assert.Empty(transcript.Lines);
        transcript.UpdatePartial(3, "noise", 3);
        transcript.Discard(3);
        Assert.Empty(transcript.Lines);
    }

    [Fact]
    public void LinesStayInOrderAndDiscardKeepsFinalLines()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        transcript.UpdatePartial(2, "second", 3);
        transcript.UpdatePartial(1, "first", 1);
        Assert.Equal(["first", "second"], transcript.Lines.Select(line => line.Text));
        transcript.Finalize(1, "First.", 1, 2);
        transcript.Discard(1);
        Assert.Equal(2, transcript.Lines.Count);
        Assert.Equal(["First."], transcript.FinalLines.Select(line => line.Text));
    }

    [Fact]
    public void ANewSessionContinuesAfterTheOldOne()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        transcript.Finalize(1, "One.", 0, 5.2);
        transcript.BeginSession();
        var line = transcript.Finalize(1, "Again.", 0.5, 1.5)!;
        Assert.Equal(2, transcript.Lines.Count);
        Assert.Equal(7.5, line.Start);
        Assert.Equal(8.5, line.End);
        Assert.Equal("One.", transcript.Lines[0].Text);

        transcript.Clear();
        transcript.BeginSession();
        Assert.Equal(1.0, transcript.Finalize(1, "Fresh.", 1, 2)!.Start);
    }

    [Fact]
    public void ChangesAreAnnounced()
    {
        var transcript = new LiveTranscript();
        transcript.BeginSession();
        var line = transcript.UpdatePartial(1, "a", 0)!;
        var changed = new List<string?>();
        line.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        transcript.Finalize(1, "a b", 0, 1);
        line.Translation = "甲乙";
        Assert.Contains(nameof(TranscriptLine.Text), changed);
        Assert.Contains(nameof(TranscriptLine.IsFinal), changed);
        Assert.Contains(nameof(TranscriptLine.Translation), changed);
    }
}

public class LiveTranslationContextTests
{
    [Fact]
    public void KeepsTheLastFewTurns()
    {
        var context = new LiveTranslationContext();
        for (int i = 1; i <= 5; i++)
            context.Add($"s{i}", $"t{i}");
        context.Add(" ", "ignored");
        Assert.Equal(["s3", "s4", "s5"], context.Turns.Select(turn => turn.Source));
        context.Clear();
        Assert.Empty(context.Turns);
    }

    [Fact]
    public void StaysWithinTheCharacterBudget()
    {
        var context = new LiveTranslationContext();
        context.Add(new string('a', 900), "x");
        context.Add(new string('b', 900), "y");
        Assert.Equal("y", Assert.Single(context.Turns).Translation);
        context.Add(new string('c', 2000), "z");
        Assert.Equal("z", Assert.Single(context.Turns).Translation); // the latest is kept even when too long
    }

    [Fact]
    public void InstructionsAndLanguages()
    {
        Assert.Equal(LiveTranslationContext.Instructions, LiveTranslationContext.BuildInstructions(" "));
        Assert.StartsWith("formal\n", LiveTranslationContext.BuildInstructions(" formal "));

        var zh = Languages.SimplifiedChinese;
        Assert.Equal(Languages.English, LiveTranslationContext.ResolveLanguages("今天我们讨论潮流计算", null, zh).Target);
        Assert.Equal(zh, LiveTranslationContext.ResolveLanguages("Today we talk about power flow", null, zh).Target);
        var fixedSource = LiveTranslationContext.ResolveLanguages("whatever", Languages.English, Languages.English);
        Assert.Equal(Languages.English, fixedSource.PromptSource);
        Assert.Equal(zh, fixedSource.Target);
    }
}
