using Translator.Core;
using Xunit;
using static Translator.Tests.AudioSignals;

namespace Translator.Tests;

public class SpeechSegmenterTests
{
    private static List<SegmentEvent> Run(float[] samples, SpeechSegmenter? segmenter = null, int chunk = 480)
    {
        segmenter ??= new SpeechSegmenter(Rate);
        var events = new List<SegmentEvent>();
        for (int i = 0; i < samples.Length; i += chunk)
            events.AddRange(segmenter.Process(samples.AsSpan(i, Math.Min(chunk, samples.Length - i))));
        return events;
    }

    [Fact]
    public void SilenceAndQuietNoiseProduceNothing()
    {
        Assert.Empty(Run(Silence(3)));
        Assert.Empty(Run(Noise(3, 0.002f)));
    }

    [Fact]
    public void OneUtteranceWithPreRollAndTail()
    {
        var events = Run(Concat(Silence(0.5), Speech(1.5), Silence(1.5)));
        var started = Assert.Single(events, e => e.Kind == SegmentEventKind.Started);
        var ended = Assert.Single(events, e => e.Kind == SegmentEventKind.Ended);
        Assert.Equal(started.Utterance, ended.Utterance);
        Assert.InRange(started.Sample, (long)(0.15 * Rate), (long)(0.5 * Rate));       // pre-roll before the first loud frame
        Assert.InRange(ended.Sample, (long)(1.95 * Rate), (long)(2.25 * Rate));        // last voiced frame + ~200 ms
        long audio = events.Where(e => e.Kind == SegmentEventKind.Audio).Sum(e => (long)e.Samples!.Length);
        Assert.InRange(started.Sample + audio, (long)(2.6 * Rate), (long)(2.7 * Rate)); // audio runs until the pause is long enough
        Assert.DoesNotContain(events, e => e.Kind == SegmentEventKind.Discarded);
        // Every event of the utterance comes between Started and Ended.
        Assert.Equal(SegmentEventKind.Started, events[0].Kind);
        Assert.Equal(SegmentEventKind.Ended, events[^1].Kind);
    }

    [Fact]
    public void ShortClickIsDiscarded()
    {
        var events = Run(Concat(Silence(0.5), Speech(0.1), Silence(1.5)));
        Assert.Contains(events, e => e.Kind == SegmentEventKind.Started);
        Assert.Contains(events, e => e.Kind == SegmentEventKind.Discarded);
        Assert.DoesNotContain(events, e => e.Kind == SegmentEventKind.Ended);
    }

    [Fact]
    public void TwoSentencesWithAPause()
    {
        var events = Run(Concat(Silence(0.3), Speech(1.2), Silence(1), Speech(0.8), Silence(1)));
        var ended = events.Where(e => e.Kind == SegmentEventKind.Ended).ToList();
        Assert.Equal(2, ended.Count);
        Assert.Equal([1, 2], ended.Select(e => e.Utterance));
    }

    [Fact]
    public void ShortPauseOnlySplitsAfterSoftMax()
    {
        var shortPause = Concat(Speech(5), Silence(0.36), Speech(2), Silence(1.5));
        Assert.Single(Run(shortPause), e => e.Kind == SegmentEventKind.Ended);

        var afterSoftMax = Concat(Speech(13), Silence(0.36), Speech(2), Silence(1.5));
        var ended = Run(afterSoftMax).Where(e => e.Kind == SegmentEventKind.Ended).ToList();
        Assert.Equal(2, ended.Count);
        Assert.InRange(ended[0].Sample, 13 * Rate, (long)(13.4 * Rate));
    }

    [Fact]
    public void LongSpeechIsCutAtTheMaximum()
    {
        var events = Run(Speech(40));
        var first = events.First(e => e.Kind == SegmentEventKind.Ended);
        long length = events.Where(e => e.Kind == SegmentEventKind.Audio && e.Utterance == first.Utterance).Sum(e => (long)e.Samples!.Length);
        Assert.InRange(length, 27.9 * Rate, 28.1 * Rate);
        Assert.Contains(events, e => e.Kind == SegmentEventKind.Started && e.Utterance == 2);
    }

    [Fact]
    public void SteadyNoiseStopsCountingAsSpeech()
    {
        var segmenter = new SpeechSegmenter(Rate);
        var noise = Noise(8, 0.02f);
        var events = Run(noise, segmenter);
        Assert.False(segmenter.IsSpeaking);
        Assert.DoesNotContain(events, e => e.Kind == SegmentEventKind.Started && e.Sample > 3 * Rate);
        Assert.InRange(segmenter.NoiseFloor, 0.012f, 0.03f);

        // Speech over the same noise is still found.
        var later = Run(Concat(Add(Speech(1.5), Noise(1.5, 0.02f, 2)), Noise(1.5, 0.02f, 3)), segmenter);
        Assert.Contains(later, e => e.Kind == SegmentEventKind.Ended);
    }

    [Fact]
    public void FlushEndsTheCurrentUtterance()
    {
        var segmenter = new SpeechSegmenter(Rate);
        Run(Concat(Silence(0.2), Speech(1)), segmenter);
        Assert.True(segmenter.IsSpeaking);
        var events = segmenter.Flush();
        Assert.Equal(SegmentEventKind.Ended, events[^1].Kind);
        Assert.False(segmenter.IsSpeaking);
        Assert.Empty(segmenter.Flush());
    }

    [Fact]
    public void ChunkSizeDoesNotMatter()
    {
        var signal = Concat(Silence(0.4), Speech(1.3), Silence(1), Speech(0.7), Silence(1));
        static string Describe(List<SegmentEvent> events) => string.Join(",",
            events.Where(e => e.Kind != SegmentEventKind.Audio).Select(e => $"{e.Kind}{e.Utterance}@{e.Sample}"));
        Assert.Equal(Describe(Run(signal, chunk: 100)), Describe(Run(signal, chunk: 4096)));
    }
}
