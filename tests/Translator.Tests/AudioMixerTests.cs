using Translator.Core;
using Xunit;

namespace Translator.Tests;

public class AudioMixerTests
{
    private static float[] Fill(int count, float value) => Enumerable.Repeat(value, count).ToArray();

    [Fact]
    public void SingleSourcePassesThrough()
    {
        var mixer = new AudioMixer(1);
        mixer.Push(0, Fill(160, 0.25f), 0);
        Assert.Equal(Fill(160, 0.25f), mixer.Drain(0));
        Assert.Empty(mixer.Drain(10));
    }

    [Fact]
    public void WaitsForTheSlowerSourceAndSums()
    {
        var mixer = new AudioMixer(2);
        mixer.Push(0, Fill(320, 0.25f), 0);
        mixer.Push(1, Fill(160, 0.5f), 0);
        Assert.Equal(Fill(160, 0.75f), mixer.Drain(0));
        mixer.Push(1, Fill(160, 0.9f), 10);
        Assert.Equal(Fill(160, 1f), mixer.Drain(10)); // 0.25 + 0.9, clipped
    }

    [Fact]
    public void ASourceThatNeverDeliveredDoesNotBlock()
    {
        var mixer = new AudioMixer(2);
        mixer.Push(0, Fill(160, 0.1f), 0);
        Assert.Equal(160, mixer.Drain(0).Length);
    }

    [Fact]
    public void StalledSourceCountsAsSilence()
    {
        var mixer = new AudioMixer(2);
        mixer.Push(1, Fill(160, 0.5f), 0);
        int total = 0;
        for (long t = 0; t <= 600; t += 10)
        {
            mixer.Push(0, Fill(160, 0.1f), t);
            total += mixer.Drain(t).Length;
        }
        // Source 1 stopped after its first 10 ms; source 0 flows again once source 1 counts as stalled.
        Assert.Equal(61 * 160, total);
    }

    [Fact]
    public void FillsSilenceWhenEverythingIsQuiet()
    {
        var mixer = new AudioMixer(1);
        mixer.Push(0, Fill(160, 0.1f), 0);
        Assert.Equal(160, mixer.Drain(0).Length);
        Assert.Empty(mixer.Drain(100));
        var silence = mixer.Drain(600);
        Assert.Equal(600 * 16, silence.Length);
        Assert.All(silence, sample => Assert.Equal(0f, sample));
        Assert.Empty(mixer.Drain(700));                 // silence comes in chunks of at least the stall time
        Assert.Equal(300 * 16, mixer.Drain(900).Length);
    }

    [Fact]
    public void BuffersAtMostOneSecondAhead()
    {
        var mixer = new AudioMixer(2);
        int mixed = 0;
        for (long t = 0; t < 3000; t += 10)
        {
            mixer.Push(0, Fill(160, 0.1f), t);
            mixer.Push(1, Fill(1, 0.1f), t); // a source that delivers far too little
            mixed += mixer.Drain(t).Length;
        }
        Assert.Equal(300, mixed);
        Assert.InRange(mixer.Drain(3300).Length, 15_900, 16_000); // both stalled now: flushes what was kept (one second)
    }
}
