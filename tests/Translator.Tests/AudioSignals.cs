namespace Translator.Tests;

internal static class AudioSignals
{
    public const int Rate = 16000;

    public static float[] Silence(double seconds) => new float[(int)(seconds * Rate)];

    /// <summary>Speech-like bursts: 200 ms of a loud tone, then 40 ms of near silence, repeated.</summary>
    public static float[] Speech(double seconds, float amplitude = 0.3f)
    {
        var samples = new float[(int)(seconds * Rate)];
        for (int i = 0; i < samples.Length; i++)
        {
            bool gap = i % (Rate * 240 / 1000) >= Rate * 200 / 1000;
            samples[i] = (gap ? amplitude * 0.07f : amplitude) * MathF.Sin(2 * MathF.PI * 220 * i / Rate);
        }
        return samples;
    }

    public static float[] Noise(double seconds, float rms, int seed = 1)
    {
        var random = new Random(seed);
        var samples = new float[(int)(seconds * Rate)];
        float scale = rms * MathF.Sqrt(3); // uniform noise in [-a, a] has an RMS of a/√3
        for (int i = 0; i < samples.Length; i++)
            samples[i] = (float)(random.NextDouble() * 2 - 1) * scale;
        return samples;
    }

    public static float[] Concat(params float[][] parts) => parts.SelectMany(part => part).ToArray();

    public static float[] Add(float[] a, float[] b) => a.Select((value, i) => value + (i < b.Length ? b[i] : 0)).ToArray();
}
