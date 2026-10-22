namespace Translator.Core;

/// <summary>
/// Mixes the 16 kHz mono streams of the microphone and the system audio into one. Each device delivers on its own
/// clock and in its own chunk sizes, so samples wait until every active source has caught up. A source that stops
/// delivering (Windows sends nothing from the loopback device while nothing plays) counts as silence after
/// <see cref="StallMilliseconds"/>, and when every source is quiet the mixer emits silence itself, so a pause after
/// the last sentence still ends it.
/// </summary>
public sealed class AudioMixer
{
    public const int StallMilliseconds = 250;

    private readonly SampleQueue[] _queues;
    private readonly long[] _lastPush;
    private readonly int _sampleRate;
    private readonly int _maxBuffered;
    private long _lastOutput = long.MinValue;

    public AudioMixer(int sources, int sampleRate = 16000)
    {
        _queues = new SampleQueue[sources];
        for (int i = 0; i < sources; i++)
            _queues[i] = new SampleQueue();
        _lastPush = Enumerable.Repeat(long.MinValue, sources).ToArray();
        _sampleRate = sampleRate;
        _maxBuffered = sampleRate; // one second ahead of the slowest source is plenty
    }

    public void Push(int source, ReadOnlySpan<float> samples, long nowMilliseconds)
    {
        if (samples.Length == 0)
            return;
        _queues[source].Enqueue(samples);
        _lastPush[source] = nowMilliseconds;
        if (_queues[source].Count > _maxBuffered)
            _queues[source].Skip(_queues[source].Count - _maxBuffered);
    }

    /// <summary>Returns whatever can be mixed now; may be empty.</summary>
    public float[] Drain(long nowMilliseconds)
    {
        if (_lastOutput == long.MinValue)
            _lastOutput = nowMilliseconds;

        bool anyActive = false;
        int count = int.MaxValue;
        for (int i = 0; i < _queues.Length; i++)
        {
            if (IsActive(i, nowMilliseconds))
            {
                anyActive = true;
                count = Math.Min(count, _queues[i].Count);
            }
        }

        float[] mixed;
        if (anyActive)
        {
            if (count == 0)
                return [];
            mixed = new float[count];
            for (int i = 0; i < _queues.Length; i++)
                _queues[i].DequeueAdd(mixed, Math.Min(count, _queues[i].Count));
        }
        else
        {
            // Nothing is coming in: flush what is left and fill the time since the last output with silence.
            int buffered = _queues.Max(queue => queue.Count);
            long elapsed = (nowMilliseconds - _lastOutput) * _sampleRate / 1000;
            int length = (int)Math.Min(Math.Max(buffered, elapsed), _sampleRate * 2L);
            if (length <= 0 || (buffered == 0 && nowMilliseconds - _lastOutput < StallMilliseconds))
                return [];
            mixed = new float[length];
            foreach (var queue in _queues)
                queue.DequeueAdd(mixed, Math.Min(length, queue.Count));
        }

        for (int i = 0; i < mixed.Length; i++)
            mixed[i] = Math.Clamp(mixed[i], -1f, 1f);
        _lastOutput = nowMilliseconds;
        return mixed;
    }

    private bool IsActive(int source, long now) =>
        _lastPush[source] != long.MinValue && now - _lastPush[source] <= StallMilliseconds;

    /// <summary>A growable ring buffer of samples.</summary>
    private sealed class SampleQueue
    {
        private float[] _buffer = new float[4096];
        private int _start;

        public int Count { get; private set; }

        public void Enqueue(ReadOnlySpan<float> samples)
        {
            if (Count + samples.Length > _buffer.Length)
            {
                var larger = new float[Math.Max(_buffer.Length * 2, Count + samples.Length)];
                for (int i = 0; i < Count; i++)
                    larger[i] = _buffer[(_start + i) % _buffer.Length];
                _buffer = larger;
                _start = 0;
            }
            for (int i = 0; i < samples.Length; i++)
                _buffer[(_start + Count + i) % _buffer.Length] = samples[i];
            Count += samples.Length;
        }

        /// <summary>Removes <paramref name="count"/> samples, adding them to <paramref name="target"/>.</summary>
        public void DequeueAdd(float[] target, int count)
        {
            for (int i = 0; i < count; i++)
                target[i] += _buffer[(_start + i) % _buffer.Length];
            Skip(count);
        }

        public void Skip(int count)
        {
            _start = (_start + count) % _buffer.Length;
            Count -= count;
        }
    }
}
