namespace Translator.Core;

public enum SegmentEventKind
{
    /// <summary>Speech began. <see cref="SegmentEvent.Sample"/> is where the utterance starts, pre-roll included.</summary>
    Started,

    /// <summary>More audio of the current utterance, in <see cref="SegmentEvent.Samples"/>.</summary>
    Audio,

    /// <summary>The utterance is over. <see cref="SegmentEvent.Sample"/> is just after its last voiced frame.</summary>
    Ended,

    /// <summary>The "utterance" was only a click or a cough; whatever was recognized from it should be dropped.</summary>
    Discarded,
}

public readonly record struct SegmentEvent(SegmentEventKind Kind, int Utterance, long Sample, float[]? Samples = null);

/// <summary>
/// Cuts a continuous mono stream into utterances by loudness: speech starts after a few loud frames (with a short
/// pre-roll so the first syllable isn't clipped) and ends after a pause. The noise floor adapts, so a fan or a quiet
/// room doesn't count as speech. After a long stretch without a pause a shorter one is enough, and nothing grows past
/// <see cref="MaxUtteranceMilliseconds"/>, so a lecture is still split into sentences that Whisper (≤ 30 s) can take.
/// </summary>
public sealed class SpeechSegmenter
{
    public const int FrameMilliseconds = 20;

    /// <summary>About -44 dBFS: quieter frames are never speech, however quiet the room is.</summary>
    public const float MinSpeechLevel = 0.006f;

    private const float SpeechOverNoise = 3.2f;   // about +10 dB above the noise floor
    private const float ReleaseRatio = 0.6f;      // speech goes on until the level drops well below the start level
    private const int StartFrames = 3;            // 60 ms of loud audio starts an utterance
    private const int PreRollMilliseconds = 300;
    private const int TailMilliseconds = 200;     // kept after the last voiced frame in the reported end time
    private const int MinSpeechMilliseconds = 200;

    private const int NoiseBlockFrames = 10;     // the noise floor is the quietest 200 ms block…
    private const int NoiseBlocks = 8;           // …of the last 1.6 s

    private readonly int _frameSize;
    private readonly float[] _frame;
    private readonly float[] _preRoll;
    private readonly float[] _blockMinimums = new float[NoiseBlocks];
    private int _blockCount;
    private int _blockFrames;
    private float _blockMinimum = float.MaxValue;
    private int _frameFill;
    private int _preRollStart;
    private int _preRollCount;
    private float _noiseFloor = MinSpeechLevel / SpeechOverNoise;
    private long _position;
    private int _candidateFrames;
    private int _lastId;
    private int _utterance;               // 0 while idle
    private long _utteranceLength;
    private long _lastVoiceEnd;
    private int _voicedFrames;
    private int _silentFrames;

    public SpeechSegmenter(int sampleRate = 16000)
    {
        SampleRate = sampleRate;
        _frameSize = sampleRate * FrameMilliseconds / 1000;
        _frame = new float[_frameSize];
        _preRoll = new float[sampleRate * PreRollMilliseconds / 1000];
    }

    public int SampleRate { get; }

    /// <summary>Pause that ends an utterance.</summary>
    public int EndSilenceMilliseconds { get; set; } = 650;

    /// <summary>Utterances longer than this already end at a <see cref="ShortPauseMilliseconds"/> pause.</summary>
    public int SoftMaxMilliseconds { get; set; } = 12_000;

    public int ShortPauseMilliseconds { get; set; } = 300;

    public int MaxUtteranceMilliseconds { get; set; } = 28_000;

    public bool IsSpeaking => _utterance != 0;

    /// <summary>Samples consumed so far; the time base of all events.</summary>
    public long Position => _position + _frameFill;

    public float NoiseFloor => _noiseFloor;

    public List<SegmentEvent> Process(ReadOnlySpan<float> samples)
    {
        var events = new List<SegmentEvent>();
        List<float>? audio = null;
        while (samples.Length > 0)
        {
            int take = Math.Min(samples.Length, _frameSize - _frameFill);
            samples[..take].CopyTo(_frame.AsSpan(_frameFill));
            _frameFill += take;
            samples = samples[take..];
            if (_frameFill == _frameSize)
            {
                _frameFill = 0;
                ProcessFrame(events, ref audio);
            }
        }
        FlushAudio(events, ref audio);
        return events;
    }

    /// <summary>Ends the current utterance, e.g. when capture stops or pauses.</summary>
    public List<SegmentEvent> Flush()
    {
        var events = new List<SegmentEvent>();
        if (_utterance != 0)
        {
            List<float>? audio = null;
            if (_frameFill > 0)
            {
                audio = [.. _frame.AsSpan(0, _frameFill)];
                _utteranceLength += _frameFill;
            }
            End(events, ref audio);
        }
        _position += _frameFill;
        _frameFill = 0;
        _preRollCount = 0;
        _candidateFrames = 0;
        return events;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0)
            return 0;
        double sum = 0;
        foreach (float sample in samples)
            sum += sample * sample;
        return (float)Math.Sqrt(sum / samples.Length);
    }

    private void ProcessFrame(List<SegmentEvent> events, ref List<float>? audio)
    {
        float level = Rms(_frame);
        float threshold = Math.Max(MinSpeechLevel, _noiseFloor * SpeechOverNoise);
        _position += _frameSize;
        TrackNoiseFloor(level);

        if (_utterance == 0)
        {
            PushPreRoll(_frame);
            _candidateFrames = level >= threshold ? _candidateFrames + 1 : 0;
            if (_candidateFrames < StartFrames)
                return;

            _utterance = ++_lastId;
            var preRoll = TakePreRoll();
            events.Add(new SegmentEvent(SegmentEventKind.Started, _utterance, _position - preRoll.Length));
            audio = [.. preRoll];
            _utteranceLength = preRoll.Length;
            _voicedFrames = _candidateFrames;
            _silentFrames = 0;
            _lastVoiceEnd = _position;
            _candidateFrames = 0;
            return;
        }

        (audio ??= new List<float>(_frameSize * 8)).AddRange(_frame);
        _utteranceLength += _frameSize;
        if (level >= threshold * ReleaseRatio)
        {
            _voicedFrames++;
            _silentFrames = 0;
            _lastVoiceEnd = _position;
        }
        else
        {
            _silentFrames++;
        }

        long lengthMs = _utteranceLength * 1000 / SampleRate;
        int pauseNeeded = lengthMs >= SoftMaxMilliseconds ? ShortPauseMilliseconds : EndSilenceMilliseconds;
        if (_silentFrames * FrameMilliseconds >= pauseNeeded || lengthMs >= MaxUtteranceMilliseconds)
            End(events, ref audio);
    }

    private void End(List<SegmentEvent> events, ref List<float>? audio)
    {
        FlushAudio(events, ref audio);
        bool tooShort = _voicedFrames * FrameMilliseconds < MinSpeechMilliseconds;
        long end = Math.Min(Position, _lastVoiceEnd + SampleRate * TailMilliseconds / 1000);
        events.Add(new SegmentEvent(tooShort ? SegmentEventKind.Discarded : SegmentEventKind.Ended, _utterance, end));
        _utterance = 0;
        _utteranceLength = 0;
        _voicedFrames = 0;
        _silentFrames = 0;
    }

    private void FlushAudio(List<SegmentEvent> events, ref List<float>? audio)
    {
        if (audio is { Count: > 0 } && _utterance != 0)
            events.Add(new SegmentEvent(SegmentEventKind.Audio, _utterance, Position, [.. audio]));
        audio = null;
    }

    // "Minimum statistics": even continuous speech has quiet moments between syllables, so the quietest stretch of the
    // last couple of seconds is the background. A steady fan or hum thus stops counting as speech after about 2 s.
    private void TrackNoiseFloor(float level)
    {
        _blockMinimum = Math.Min(_blockMinimum, level);
        if (++_blockFrames < NoiseBlockFrames)
            return;
        _blockMinimums[_blockCount++ % NoiseBlocks] = _blockMinimum;
        _blockFrames = 0;
        _blockMinimum = float.MaxValue;

        float quietest = float.MaxValue;
        for (int i = 0; i < Math.Min(_blockCount, NoiseBlocks); i++)
            quietest = Math.Min(quietest, _blockMinimums[i]);
        float floor = quietest < _noiseFloor ? quietest : _noiseFloor + (quietest - _noiseFloor) * 0.5f;
        _noiseFloor = Math.Max(0.0002f, floor);
    }

    private void PushPreRoll(ReadOnlySpan<float> frame)
    {
        foreach (float sample in frame)
        {
            int index = (_preRollStart + _preRollCount) % _preRoll.Length;
            _preRoll[index] = sample;
            if (_preRollCount < _preRoll.Length)
                _preRollCount++;
            else
                _preRollStart = (_preRollStart + 1) % _preRoll.Length;
        }
    }

    private float[] TakePreRoll()
    {
        var result = new float[_preRollCount];
        for (int i = 0; i < _preRollCount; i++)
            result[i] = _preRoll[(_preRollStart + i) % _preRoll.Length];
        _preRollStart = 0;
        _preRollCount = 0;
        return result;
    }
}
